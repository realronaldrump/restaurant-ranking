import CoreData
import Foundation
import Observation
import UIKit

struct ComparisonQuestion: Identifiable {
    let a: RestaurantLocation
    let b: RestaurantLocation
    var id: String { "\(a.id.uuidString)-\(b.id.uuidString)" }
}

@MainActor
@Observable
final class AppStore {
    let persistence: PersistenceController
    let rankingEngine = RankingEngine()

    private(set) var circles: [CircleEntity] = []
    private var allPeople: [PersonEntity] = []
    private var allLocations: [RestaurantLocation] = []
    private var allVisits: [VisitEntity] = []
    private var allComparisons: [ComparisonEntity] = []
    private var allWantEntries: [WantEntryEntity] = []
    private(set) var activeCircleID: UUID?
    private(set) var devicePersonID: UUID?
    private(set) var revision = 0
    var lastError: String?

    @ObservationIgnored private var devicePersonIDsByCircle: [String: String] = [:]
    @ObservationIgnored private var isWaitingForAcceptedCircle = false
    @ObservationIgnored private var scoreCache: [UUID: [LocationScore]] = [:]
    @ObservationIgnored private var coupleScoreCache: [String: [CoupleLocationScore]] = [:]
    @ObservationIgnored private var cachedScoreRevision = -1
    @ObservationIgnored private var isBatching = false

    var context: NSManagedObjectContext { persistence.container.viewContext }
    var activeCircle: CircleEntity? {
        if let activeCircleID, let selected = circles.first(where: { $0.id == activeCircleID }) { return selected }
        return circles.first
    }
    var people: [PersonEntity] { allPeople.filter { $0.circle?.id == activeCircle?.id } }
    var circleMembers: [PersonEntity] { people.filter(\.isCircleMember) }
    var namedCompanions: [PersonEntity] { people.filter { !$0.isCircleMember } }
    var locations: [RestaurantLocation] { allLocations.filter { $0.circle?.id == activeCircle?.id } }
    var visits: [VisitEntity] { allVisits.filter { $0.circle?.id == activeCircle?.id } }
    var comparisons: [ComparisonEntity] { allComparisons.filter { $0.circle?.id == activeCircle?.id } }
    var wantEntries: [WantEntryEntity] { allWantEntries.filter { $0.circle?.id == activeCircle?.id } }
    var currentPerson: PersonEntity? {
        if let devicePersonID, let selected = people.first(where: { $0.id == devicePersonID }) { return selected }
        return nil
    }
    var needsDeviceIdentity: Bool { activeCircle != nil && currentPerson == nil }
    var partner: PersonEntity? {
        guard let currentPerson else { return nil }
        return circleMembers.first { $0.id != currentPerson.id }
    }

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
        activeCircleID = UserDefaults.standard.string(forKey: "activeCircleID").flatMap(UUID.init(uuidString:))
        devicePersonID = UserDefaults.standard.string(forKey: "devicePersonID").flatMap(UUID.init(uuidString:))
        devicePersonIDsByCircle = UserDefaults.standard.dictionary(forKey: "devicePersonIDsByCircle") as? [String: String] ?? [:]
        reload()
        if let loadError = persistence.loadError {
            reportError("iCloud sync could not start, so the ledger is working locally for now. \(loadError.localizedDescription)")
        }
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        NotificationCenter.default.addObserver(
            forName: .cloudShareWasAccepted,
            object: persistence,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isWaitingForAcceptedCircle = true
                self?.reload()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .persistenceDidFail,
            object: persistence,
            queue: .main
        ) { [weak self] notification in
            let message = notification.userInfo?[PersistenceNotificationKey.message] as? String
            Task { @MainActor in self?.reportError(message ?? "The ledger could not save or sync its latest changes.") }
        }
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: persistence.container,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil,
                  !event.succeeded,
                  let error = event.error else { return }
            Task { @MainActor in
                self?.reportError("iCloud could not sync the latest ledger changes. They remain on this device and will retry automatically. \(error.localizedDescription)")
            }
        }
    }

    func bootstrap(myName: String, partnerName: String?, circleName: String = "Big Beautiful Testers") {
        guard circles.isEmpty else { return }
        let circle = CircleEntity(context: context)
        circle.id = UUID(); circle.name = circleName; circle.createdAt = .now
        let me = makePerson(name: myName.trimmedOr("George"), isMe: true, isCircleMember: true, color: "6F1D2B", circle: circle)
        if let partnerName, !partnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = makePerson(name: partnerName, isMe: false, isCircleMember: true, color: "2F5964", circle: circle)
        }
        activeCircleID = circle.id
        devicePersonID = me.id
        persistDeviceSelection()
        commit()
    }

    func activateCircle(_ circleID: UUID) {
        guard circles.contains(where: { $0.id == circleID }) else { return }
        activeCircleID = circleID
        devicePersonID = selectedPersonID(for: circleID).flatMap { selectedID in
            circleMembers.contains(where: { $0.id == selectedID }) ? selectedID : nil
        }
        persistDeviceSelection()
        revision += 1
    }

    func selectCurrentPerson(_ personID: UUID) {
        guard circleMembers.contains(where: { $0.id == personID }) else { return }
        devicePersonID = personID
        persistDeviceSelection()
        revision += 1
    }

    func reportError(_ message: String) {
        lastError = message
    }

    func clearLastError() {
        lastError = nil
    }

    @discardableResult
    func addPerson(name: String) -> PersonEntity? {
        guard let circle = activeCircle, circleMembers.count < 6 else { return nil }
        let colors = ["2F5964", "9A5B3A", "43533D", "775A7A", "9B7B34"]
        let person = makePerson(name: name.trimmedOr("Guest"), isMe: false, isCircleMember: true, color: colors[circleMembers.count % colors.count], circle: circle)
        commit()
        return person
    }

    @discardableResult
    func addNamedCompanion(name: String) -> PersonEntity? {
        guard let circle = activeCircle else { return nil }
        let cleanName = name.trimmedOr("Guest")
        if let existing = namedCompanions.first(where: { $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }) { return existing }
        let person = makePerson(name: cleanName, isMe: false, isCircleMember: false, color: "7A7166", circle: circle)
        commit()
        return person
    }

    @discardableResult
    func createLocation(
        name: String,
        category: DiningCategory? = nil,
        address: String? = nil,
        city: String? = nil,
        coordinate: (Double, Double)? = nil,
        phone: String? = nil,
        url: URL? = nil,
        sourceIdentifier: String? = nil,
        cuisines: [String] = [],
        tags: [String] = []
    ) -> RestaurantLocation {
        let normalizedName = name.trimmedOr("Unnamed Establishment")
        if let sourceIdentifier, !sourceIdentifier.isEmpty,
           let existing = locations.first(where: { $0.sourceIdentifier == sourceIdentifier }) { return existing }
        if let existing = locations.first(where: {
            $0.name.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame &&
            ($0.address ?? "") == (address ?? "")
        }) { return existing }
        let location = RestaurantLocation(context: context)
        assign(location, alongside: activeCircle)
        location.id = UUID(); location.name = normalizedName
        location.category = category ?? DiningCategory.suggested(for: normalizedName, cuisine: cuisines.first)
        location.address = address; location.city = city; location.phone = phone; location.urlString = url?.absoluteString
        location.sourceIdentifier = sourceIdentifier; location.cuisines = cuisines; location.tags = tags
        location.createdAt = .now; location.updatedAt = .now; location.circle = activeCircle
        if let coordinate {
            location.latitude = coordinate.0; location.longitude = coordinate.1; location.hasCoordinates = true
        }
        commit()
        return location
    }

    @discardableResult
    func logVisit(
        at location: RestaurantLocation,
        reaction: Reaction?,
        personID: UUID? = nil,
        date: Date = .now,
        hazy: Bool = false,
        companionIDs: [UUID] = [],
        isShared: Bool = false,
        coordinate: (Double, Double)? = nil
    ) -> VisitEntity {
        let authorID = personID ?? currentPerson?.id ?? UUID()
        let visit = VisitEntity(context: context)
        assign(visit, alongside: location)
        visit.id = UUID(); visit.date = date; visit.createdAt = .now; visit.createdByID = authorID
        visit.location = location; visit.circle = activeCircle; visit.isShared = isShared || !companionIDs.isEmpty
        visit.companionIDs = companionIDs
        if let coordinate {
            visit.latitude = coordinate.0; visit.longitude = coordinate.1; visit.hasCoordinates = true
        } else if let coordinate = location.coordinate {
            visit.latitude = coordinate.latitude; visit.longitude = coordinate.longitude; visit.hasCoordinates = true
        }
        if let reaction { _ = addRating(to: visit, personID: authorID, reaction: reaction, hazy: hazy) }
        location.updatedAt = .now
        commit()
        return visit
    }

    @discardableResult
    func addRating(to visit: VisitEntity, personID: UUID, reaction: Reaction, hazy: Bool = false) -> RatingEntity {
        let rating: RatingEntity
        if let existing = visit.rating(for: personID) {
            rating = existing
        } else {
            rating = RatingEntity(context: context)
            assign(rating, alongside: visit)
            rating.id = UUID(); rating.visit = visit; rating.personID = personID; rating.createdAt = .now
        }
        rating.reaction = reaction; rating.hazyMemory = hazy
        commit()
        return rating
    }

    func updateRating(
        _ rating: RatingEntity,
        reaction: Reaction? = nil,
        service: Reaction? = nil,
        atmosphere: Reaction? = nil,
        value: Reaction? = nil,
        wouldOrderAgain: Bool? = nil,
        hazy: Bool? = nil
    ) {
        if let reaction { rating.reaction = reaction }
        rating.service = service; rating.atmosphere = atmosphere; rating.value = value
        if let wouldOrderAgain { rating.hasWouldOrderAgain = true; rating.wouldOrderAgain = wouldOrderAgain }
        else { rating.hasWouldOrderAgain = false; rating.wouldOrderAgain = false }
        if let hazy { rating.hazyMemory = hazy }
        commit()
    }

    func updateVisit(_ visit: VisitEntity, type: VisitType?, priceBand: Int, occasion: Occasion?, memory: String?, companions: [UUID]) {
        visit.visitType = type; visit.priceBand = Int16(priceBand); visit.occasion = occasion
        let cleanMemory = memory?.trimmingCharacters(in: .whitespacesAndNewlines)
        visit.memory = cleanMemory?.isEmpty == true ? nil : cleanMemory
        visit.companionIDs = companions; visit.isShared = !companions.isEmpty
        commit()
    }

    @discardableResult
    func addDish(name: String, role: DishRole, reaction: Reaction, wouldOrderAgain: Bool, to visit: VisitEntity, personID: UUID) -> DishEntryEntity? {
        guard let location = visit.location else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        let dish = location.dishArray.first(where: { $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }) ?? {
            let newDish = DishEntity(context: context)
            assign(newDish, alongside: location)
            newDish.id = UUID(); newDish.name = cleanName; newDish.role = role; newDish.createdAt = .now; newDish.location = location
            return newDish
        }()
        dish.role = role
        let entry = DishEntryEntity(context: context)
        assign(entry, alongside: visit)
        entry.id = UUID(); entry.personID = personID; entry.reaction = reaction; entry.wouldOrderAgain = wouldOrderAgain
        entry.createdAt = .now; entry.dish = dish; entry.visit = visit
        commit()
        return entry
    }

    func addPhoto(fullData: Data, thumbnailData: Data?, to visit: VisitEntity, createdAt: Date = .now) {
        let photo = PhotoEntity(context: context)
        assign(photo, alongside: visit)
        photo.id = UUID(); photo.fullData = fullData; photo.thumbnailData = thumbnailData; photo.createdAt = createdAt; photo.visit = visit
        commit()
    }

    func recordComparison(a: RestaurantLocation, b: RestaurantLocation, outcome: ComparisonOutcome, personID: UUID? = nil) {
        guard a.id != b.id else { return }
        let comparison = ComparisonEntity(context: context)
        assign(comparison, alongside: activeCircle)
        comparison.id = UUID(); comparison.personID = personID ?? currentPerson?.id ?? UUID()
        comparison.locationAID = a.id; comparison.locationBID = b.id; comparison.outcome = outcome
        comparison.date = .now; comparison.isAnchor = false; comparison.anchorValue = 0; comparison.circle = activeCircle
        commit()
    }

    func recordAnchor(for location: RestaurantLocation, value: Double, personID: UUID? = nil) {
        let comparison = ComparisonEntity(context: context)
        assign(comparison, alongside: activeCircle)
        comparison.id = UUID(); comparison.personID = personID ?? currentPerson?.id ?? UUID()
        comparison.locationAID = location.id; comparison.locationBID = location.id; comparison.outcome = .tie
        comparison.date = .now; comparison.isAnchor = true; comparison.anchorValue = value; comparison.circle = activeCircle
        commit()
    }

    func ranked(for personID: UUID? = nil) -> [LocationScore] {
        guard let personID = personID ?? currentPerson?.id else { return [] }
        invalidateScoreCacheIfStale()
        if let cached = scoreCache[personID] { return cached }
        let result = rankingEngine.scores(locations: locations, comparisons: comparisons, personID: personID)
        scoreCache[personID] = result
        return result
    }

    func coupleRanked() -> [CoupleLocationScore] {
        guard let mine = currentPerson?.id, let partner = partner?.id else { return [] }
        invalidateScoreCacheIfStale()
        let key = "\(mine.uuidString)-\(partner.uuidString)"
        if let cached = coupleScoreCache[key] { return cached }
        let result = rankingEngine.coupleScores(locations: locations, comparisons: comparisons, myID: mine, partnerID: partner)
        coupleScoreCache[key] = result
        return result
    }

    /// Reading `revision` here registers an observation dependency for every caller,
    /// so views recompute whenever the underlying records change.
    private func invalidateScoreCacheIfStale() {
        if cachedScoreRevision != revision {
            scoreCache.removeAll()
            coupleScoreCache.removeAll()
            cachedScoreRevision = revision
        }
    }

    func score(for location: RestaurantLocation, personID: UUID? = nil) -> LocationScore? {
        ranked(for: personID).first { $0.id == location.id }
    }

    func pendingVisits(for personID: UUID? = nil) -> [VisitEntity] {
        guard let personID = personID ?? currentPerson?.id else { return [] }
        return visits.filter { $0.companionIDs.contains(personID) && $0.rating(for: personID) == nil }.sorted { $0.date > $1.date }
    }

    func toggleWant(_ location: RestaurantLocation, by personID: UUID? = nil) {
        if let existing = wantEntries.first(where: { $0.location?.id == location.id }) {
            context.delete(existing)
        } else {
            let entry = WantEntryEntity(context: context)
            assign(entry, alongside: activeCircle)
            entry.id = UUID(); entry.addedByID = personID ?? currentPerson?.id ?? UUID(); entry.addedAt = .now
            entry.location = location; entry.circle = activeCircle
        }
        commit()
    }

    func isWanted(_ location: RestaurantLocation) -> Bool { wantEntries.contains { $0.location?.id == location.id } }

    func updateLocation(_ location: RestaurantLocation, name: String, category: DiningCategory, cuisines: [String], tags: [String], isClosed: Bool) {
        location.name = name.trimmedOr(location.name); location.category = category; location.cuisines = cuisines
        location.tags = tags; location.isClosed = isClosed; location.updatedAt = .now
        commit()
    }

    func updateLocationDetails(
        _ location: RestaurantLocation,
        name: String,
        category: DiningCategory,
        cuisines: [String],
        tags: [String],
        address: String?,
        city: String?,
        phone: String?,
        urlString: String?,
        hoursText: String?,
        latitude: Double?,
        longitude: Double?,
        isClosed: Bool
    ) {
        location.name = name.trimmedOr(location.name); location.category = category
        location.cuisines = cuisines; location.tags = tags
        location.address = address?.nilIfBlank; location.city = city?.nilIfBlank; location.phone = phone?.nilIfBlank
        location.urlString = urlString?.nilIfBlank; location.hoursText = hoursText?.nilIfBlank
        if let latitude, let longitude {
            location.latitude = latitude; location.longitude = longitude; location.hasCoordinates = true
        } else {
            location.hasCoordinates = false; location.latitude = 0; location.longitude = 0
        }
        location.isClosed = isClosed; location.updatedAt = .now
        commit()
    }

    func merge(_ duplicate: RestaurantLocation, into keeper: RestaurantLocation) {
        guard duplicate != keeper else { return }
        for visit in duplicate.visitArray { visit.location = keeper }
        for dish in duplicate.dishArray {
            if let existing = keeper.dishArray.first(where: { $0.name.localizedCaseInsensitiveCompare(dish.name) == .orderedSame }) {
                for entry in dish.entryArray { entry.dish = existing }
                context.delete(dish)
            } else { dish.location = keeper }
        }
        for entry in wantEntries where entry.location == duplicate { entry.location = keeper }
        for comparison in comparisons {
            if comparison.locationAID == duplicate.id { comparison.locationAID = keeper.id }
            if comparison.locationBID == duplicate.id { comparison.locationBID = keeper.id }
            if comparison.locationAID == comparison.locationBID && !comparison.isAnchor { context.delete(comparison) }
        }
        context.delete(duplicate)
        commit()
    }

    func deleteVisit(_ visit: VisitEntity) { context.delete(visit); commit() }

    func deletePhoto(_ photo: PhotoEntity) { context.delete(photo); commit() }

    func deleteDishEntry(_ entry: DishEntryEntity) {
        let dish = entry.dish
        let remaining = dish?.entryArray.filter { $0.id != entry.id } ?? []
        context.delete(entry)
        if let dish, remaining.isEmpty { context.delete(dish) }
        commit()
    }

    func settleQuestions(limit: Int = 5, personID: UUID? = nil) -> [ComparisonQuestion] {
        let scores = ranked(for: personID)
        let comparedPairs = Set(comparisons.filter { !$0.isAnchor }.map { PairKey($0.locationAID, $0.locationBID) })
        var result: [ComparisonQuestion] = []
        for category in DiningCategory.allCases {
            let categoryScores = scores.filter { $0.location.category == category }
            for pair in zip(categoryScores, categoryScores.dropFirst()) {
                let already = comparedPairs.contains(PairKey(pair.0.id, pair.1.id))
                if !already || pair.0.isProvisional || pair.1.isProvisional {
                    result.append(.init(a: pair.0.location, b: pair.1.location))
                }
            }
        }
        return Array(result.sorted { questionCertainty($0, scores: scores) < questionCertainty($1, scores: scores) }.prefix(limit))
    }

    /// Runs a block of mutations as one unit: intermediate commits refresh the
    /// in-memory arrays without writing to disk, and a single save happens at the end.
    func performBatch(_ work: () -> Void) {
        guard !isBatching else { work(); return }
        isBatching = true
        work()
        isBatching = false
        commit()
    }

    func seedSampleLedger() {
        if circles.isEmpty { bootstrap(myName: "George", partnerName: "Michelle") }
        guard locations.isEmpty, let me = currentPerson, let partner else { return }
        performBatch { seedSampleVisits(me: me, partner: partner) }
    }

    private func seedSampleVisits(me: PersonEntity, partner: PersonEntity) {
        let samples: [(String, DiningCategory, [String], Reaction, Reaction, Int)] = [
            ("The Copper Onion", .fullService, ["New American"], .loved, .loved, 3),
            ("Central 9th Market", .counterService, ["Sandwiches"], .loved, .liked, 2),
            ("Publik Coffee", .coffeeTea, ["Coffee"], .liked, .loved, 2),
            ("Eva’s Bakery", .bakeries, ["French", "Pastry"], .loved, .loved, 2),
            ("Fisher Brewing", .barsBreweries, ["Brewery"], .liked, .fine, 2),
            ("Normal Ice Cream", .dessert, ["Ice Cream"], .loved, .liked, 1),
            ("Yoko Ramen", .fullService, ["Japanese", "Ramen"], .liked, .notForMe, 2),
            ("Tacos Don Rafa", .trucksStands, ["Mexican", "Tacos"], .loved, .loved, 1),
            ("Pretty Bird", .counterService, ["Fried Chicken"], .liked, .liked, 2)
        ]
        for (offset, sample) in samples.enumerated() {
            let location = createLocation(name: sample.0, category: sample.1, city: "Salt Lake City", cuisines: sample.2)
            for visitIndex in 0..<sample.5 {
                let date = Calendar.current.date(byAdding: .day, value: -(offset * 19 + visitIndex * 110), to: .now) ?? .now
                let visit = logVisit(at: location, reaction: sample.3, personID: me.id, date: date, companionIDs: [partner.id], isShared: true)
                _ = addRating(to: visit, personID: partner.id, reaction: sample.4)
                visit.visitType = sample.1 == .coffeeTea ? .coffee : .meal
                visit.priceBand = Int16((offset % 3) + 1)
            }
        }
        if let ramen = locations.first(where: { $0.name == "Yoko Ramen" }), let normal = locations.first(where: { $0.name == "Normal Ice Cream" }) {
            recordComparison(a: normal, b: ramen, outcome: .a, personID: me.id)
        }
    }

    func reload() {
        do {
            let previousCircleIDs = Set(circles.map(\.id))
            let previousDevicePersonID = devicePersonID
            circles = try fetch(CircleEntity.self, sort: [NSSortDescriptor(key: "createdAt", ascending: true)])
            allPeople = try fetch(PersonEntity.self, sort: [NSSortDescriptor(key: "createdAt", ascending: true)])
            allLocations = try fetch(RestaurantLocation.self, sort: [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))])
            allVisits = try fetch(VisitEntity.self, sort: [NSSortDescriptor(key: "date", ascending: false)])
            allComparisons = try fetch(ComparisonEntity.self, sort: [NSSortDescriptor(key: "date", ascending: false)])
            allWantEntries = try fetch(WantEntryEntity.self, sort: [NSSortDescriptor(key: "addedAt", ascending: false)])
            let acceptedCircle = circles.first(where: { !previousCircleIDs.contains($0.id) })
                ?? circles.filter(isStoredInSharedDatabase).max(by: { $0.createdAt < $1.createdAt })
            if isWaitingForAcceptedCircle, let acceptedCircle {
                activeCircleID = acceptedCircle.id
                devicePersonID = nil
                isWaitingForAcceptedCircle = false
            } else if activeCircle == nil, let first = circles.first {
                activeCircleID = first.id
            }
            if let activeCircleID {
                let memberIDs = Set(circleMembers.map(\.id))
                if let selected = selectedPersonID(for: activeCircleID), memberIDs.contains(selected) {
                    devicePersonID = selected
                } else if let previousDevicePersonID, memberIDs.contains(previousDevicePersonID) {
                    // One-time migration from the original global device-person key.
                    devicePersonID = previousDevicePersonID
                } else {
                    devicePersonID = nil
                }
            } else {
                devicePersonID = nil
            }
            persistDeviceSelection()
            revision += 1
        } catch { reportError("The ledger could not reload its saved data. \(error.localizedDescription)") }
    }

    private func commit() {
        // Fetches include pending changes, so a reload keeps dedupe and lookups
        // correct mid-batch while deferring the expensive store save to the end.
        if isBatching { reload(); return }
        do { try persistence.save(); reload() }
        catch { reportError("Your latest changes could not be saved. \(error.localizedDescription)") }
    }

    private func makePerson(name: String, isMe: Bool, isCircleMember: Bool, color: String, circle: CircleEntity) -> PersonEntity {
        let person = PersonEntity(context: context)
        assign(person, alongside: circle)
        person.id = UUID(); person.name = name.trimmedOr("Guest"); person.isMe = isMe; person.isCircleMember = isCircleMember; person.colorHex = color
        person.createdAt = .now; person.circle = circle
        return person
    }

    private func fetch<T: NSManagedObject>(_ type: T.Type, sort: [NSSortDescriptor]) throws -> [T] {
        let request = NSFetchRequest<T>(entityName: String(describing: type))
        request.sortDescriptors = sort
        return try context.fetch(request)
    }

    private func assign(_ object: NSManagedObject, alongside anchor: NSManagedObject?) {
        guard let anchor, !anchor.objectID.isTemporaryID,
              let store = anchor.objectID.persistentStore else { return }
        context.assign(object, to: store)
    }

    private func questionCertainty(_ question: ComparisonQuestion, scores: [LocationScore]) -> Double {
        let a = scores.first { $0.id == question.a.id }?.certainty ?? 0
        let b = scores.first { $0.id == question.b.id }?.certainty ?? 0
        return a + b
    }

    private struct PairKey: Hashable {
        let low: UUID
        let high: UUID
        init(_ a: UUID, _ b: UUID) {
            if a.uuidString <= b.uuidString { low = a; high = b } else { low = b; high = a }
        }
    }

    private func persistDeviceSelection() {
        if let activeCircleID { UserDefaults.standard.set(activeCircleID.uuidString, forKey: "activeCircleID") }
        else { UserDefaults.standard.removeObject(forKey: "activeCircleID") }
        if let activeCircleID {
            if let devicePersonID {
                devicePersonIDsByCircle[activeCircleID.uuidString] = devicePersonID.uuidString
                UserDefaults.standard.set(devicePersonID.uuidString, forKey: "devicePersonID")
            } else {
                devicePersonIDsByCircle.removeValue(forKey: activeCircleID.uuidString)
                UserDefaults.standard.removeObject(forKey: "devicePersonID")
            }
        }
        UserDefaults.standard.set(devicePersonIDsByCircle, forKey: "devicePersonIDsByCircle")
    }

    private func selectedPersonID(for circleID: UUID) -> UUID? {
        devicePersonIDsByCircle[circleID.uuidString].flatMap(UUID.init(uuidString:))
    }

    private func isStoredInSharedDatabase(_ circle: CircleEntity) -> Bool {
        circle.objectID.persistentStore?.url?.lastPathComponent.contains("-shared") == true
    }
}

private extension String {
    func trimmedOr(_ fallback: String) -> String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
