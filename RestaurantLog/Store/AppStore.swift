import CoreData
import CryptoKit
import Foundation
import Observation
import UIKit

struct ComparisonQuestion: Identifiable {
    let a: RestaurantLocation
    let b: RestaurantLocation
    var id: String { "\(a.id.uuidString)-\(b.id.uuidString)" }
}

enum SettleScorePrompt {
    case comparison(ComparisonQuestion)
    case anchor(RestaurantLocation)
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
    @ObservationIgnored private var circleScoreCache: [String: [CircleLocationScore]] = [:]
    @ObservationIgnored private var locationsByIdentity: [LocationIdentityKey: RestaurantLocation] = [:]
    @ObservationIgnored private var locationsBySource: [LocationSourceKey: RestaurantLocation] = [:]
    @ObservationIgnored private var cachedScoreRevision = -1
    @ObservationIgnored private var isBatching = false
    @ObservationIgnored private var pendingSorts: Set<CachedCollection> = []
    @ObservationIgnored private var remoteReloadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var diagnosticReloadCount = 0

    var context: NSManagedObjectContext { persistence.container.viewContext }
    var activeCircle: CircleEntity? {
        _ = revision
        if let activeCircleID, let selected = circles.first(where: { $0.id == activeCircleID }) { return selected }
        return circles.first
    }
    var people: [PersonEntity] {
        allPeople
            .filter { $0.circle?.id == activeCircle?.id }
            .sorted(by: personComesBefore)
    }
    var circleMembers: [PersonEntity] { people.filter(\.isCircleMember) }
    var namedCompanions: [PersonEntity] { people.filter { !$0.isCircleMember } }
    var locations: [RestaurantLocation] { allLocations.filter { $0.circle?.id == activeCircle?.id } }
    var visits: [VisitEntity] { allVisits.filter { $0.circle?.id == activeCircle?.id } }
    var comparisons: [ComparisonEntity] { allComparisons.filter { $0.circle?.id == activeCircle?.id } }
    var wantEntries: [WantEntryEntity] { allWantEntries.filter { $0.circle?.id == activeCircle?.id } }
    var photoDateSyncCandidateCount: Int {
        _ = revision
        return photoDateSyncCandidates.count
    }
    var currentPerson: PersonEntity? {
        if let devicePersonID, let selected = people.first(where: { $0.id == devicePersonID }) { return selected }
        return nil
    }
    var needsDeviceIdentity: Bool { activeCircle != nil && currentPerson == nil }
    var otherCircleMembers: [PersonEntity] { circleMembers.filter { $0.id != currentPerson?.id } }

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
        activeCircleID = UserDefaults.standard.string(forKey: "activeCircleID").flatMap(UUID.init(uuidString:))
        devicePersonID = UserDefaults.standard.string(forKey: "devicePersonID").flatMap(UUID.init(uuidString:))
        devicePersonIDsByCircle = UserDefaults.standard.dictionary(forKey: "devicePersonIDsByCircle") as? [String: String] ?? [:]
        reload()
        if let loadError = persistence.loadError {
            reportError("iCloud sync could not start, so your log is staying on this device for now. \(loadError.localizedDescription)")
        }
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: persistence.container.persistentStoreCoordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRemoteReload() }
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
            Task { @MainActor in self?.reportError(message ?? "Big Beautiful Log could not save or sync your latest changes.") }
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
                self?.reportError("iCloud could not sync the latest changes to your log. They remain on this device and will retry automatically. \(error.localizedDescription)")
            }
        }
    }

    func bootstrap(myName: String, circleName: String = "Our Table") {
        guard circles.isEmpty else { return }
        let circle = CircleEntity(context: context)
        circle.id = UUID(); circle.name = circleName.trimmedOr("Our Table"); circle.createdAt = .now
        circles.append(circle)
        let me = makePerson(name: myName.trimmedOr("Me"), isCircleMember: true, color: "6F1D2B", circle: circle)
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

    /// Device identity is local-only state, but it belongs in a portable backup
    /// so every restored log opens as the same person on a new installation.
    func selectedPersonIDForBackup(circleID: UUID) -> UUID? {
        if circleID == activeCircleID, let devicePersonID { return devicePersonID }
        return selectedPersonID(for: circleID)
    }

    /// Rebuilds the observable caches only after a complete backup transaction
    /// has saved successfully. Until then, a failed restore can be rolled back
    /// without disturbing the running app.
    func completeBackupRestore(activeCircleID restoredCircleID: UUID?, selections: [UUID: UUID]) {
        activeCircleID = restoredCircleID
        devicePersonIDsByCircle = Dictionary(uniqueKeysWithValues: selections.map {
            ($0.key.uuidString, $0.value.uuidString)
        })
        devicePersonID = restoredCircleID.flatMap { selections[$0] }
        isWaitingForAcceptedCircle = false
        remoteReloadTask?.cancel()
        remoteReloadTask = nil
        context.reset()
        scoreCache.removeAll()
        circleScoreCache.removeAll()
        // The previous cache objects were deleted by the replacement save. Do
        // not read required attributes from those invalidated instances while
        // reload establishes the restored object graph.
        circles.removeAll()
        allPeople.removeAll()
        allLocations.removeAll()
        allVisits.removeAll()
        allComparisons.removeAll()
        allWantEntries.removeAll()
        locationsByIdentity.removeAll()
        locationsBySource.removeAll()
        cachedScoreRevision = -1
        pendingSorts.removeAll()
        lastError = nil
        context.undoManager?.removeAllActions()
        persistDeviceSelection()
        reload()
    }

    /// Permanently removes every dining circle from every configured persistent store.
    /// Object-by-object deletes are intentional so CloudKit can mirror them.
    @discardableResult
    func eraseAllData() -> Bool {
        do {
            // Circles own all saved dining data through cascade relationships.
            // Brands are the model's only other root entity.
            for entityName in ["CircleEntity", "BrandEntity"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                for object in try context.fetch(request) {
                    context.delete(object)
                }
            }
            try persistence.save()

            circles.removeAll()
            allPeople.removeAll()
            allLocations.removeAll()
            allVisits.removeAll()
            allComparisons.removeAll()
            allWantEntries.removeAll()
            activeCircleID = nil
            devicePersonID = nil
            devicePersonIDsByCircle.removeAll()
            isWaitingForAcceptedCircle = false
            remoteReloadTask?.cancel()
            remoteReloadTask = nil
            scoreCache.removeAll()
            circleScoreCache.removeAll()
            locationsByIdentity.removeAll()
            locationsBySource.removeAll()
            cachedScoreRevision = -1
            pendingSorts.removeAll()
            lastError = nil
            context.undoManager?.removeAllActions()
            persistDeviceSelection()
            revision += 1
            return true
        } catch {
            context.rollback()
            reload()
            reportError("The app could not erase all of its saved data, so it was not restarted. \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func addCircleMember(name: String) -> PersonEntity? {
        guard let circle = activeCircle else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        if let existing = person(named: cleanName) {
            guard !existing.isCircleMember else { return existing }
            guard circleMembers.count < 6 else { return nil }
            existing.isCircleMember = true
            existing.colorHex = memberColor(at: circleMembers.count)
            for visit in visits where visit.companionIDs.contains(existing.id) {
                visit.isShared = true
            }
            commit()
            return existing
        }
        guard circleMembers.count < 6 else { return nil }
        let colors = ["2F5964", "9A5B3A", "43533D", "775A7A", "9B7B34"]
        let person = makePerson(name: cleanName, isCircleMember: true, color: colors[circleMembers.count % colors.count], circle: circle)
        commit()
        return person
    }

    @discardableResult
    func addNamedCompanion(name: String) -> PersonEntity? {
        guard let circle = activeCircle else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        if let existing = person(named: cleanName) { return existing }
        let person = makePerson(name: cleanName, isCircleMember: false, color: "7A7166", circle: circle)
        commit()
        return person
    }

    @discardableResult
    func renamePerson(_ person: PersonEntity, to name: String) -> Bool {
        guard person.circle?.id == activeCircle?.id else { return false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              self.person(named: cleanName).map({ $0.id == person.id }) ?? true else { return false }
        person.name = cleanName
        commit()
        return true
    }

    func person(id: UUID) -> PersonEntity? { people.first { $0.id == id } }

    func taggedPeople(for visit: VisitEntity) -> [PersonEntity] {
        let ids = Set(visit.companionIDs)
        return people.filter { ids.contains($0.id) && $0.id != visit.createdByID }
    }

    func attendees(for visit: VisitEntity) -> [PersonEntity] {
        let ids = Set(visit.companionIDs).union([visit.createdByID])
        return people.filter { ids.contains($0.id) }
    }

    func ratings(for visit: VisitEntity) -> [RatingEntity] {
        let order = Dictionary(uniqueKeysWithValues: people.enumerated().map { ($0.element.id, $0.offset) })
        return visit.ratingArray.sorted {
            let lhs = order[$0.personID] ?? Int.max
            let rhs = order[$1.personID] ?? Int.max
            if lhs == rhs { return $0.createdAt < $1.createdAt }
            return lhs < rhs
        }
    }

    func isSharedVisit(_ visit: VisitEntity) -> Bool {
        let memberIDs = Set(circleMembers.map(\.id))
        return visit.companionIDs.contains { $0 != visit.createdByID && memberIDs.contains($0) }
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
        let circleID = activeCircle?.id
        if let sourceIdentifier, !sourceIdentifier.isEmpty,
           let existing = locationsBySource[.init(circleID: circleID, sourceIdentifier: sourceIdentifier)] {
            return existing
        }
        let identityKey = LocationIdentityKey(circleID: circleID, name: normalizedName, address: address)
        if let existing = locationsByIdentity[identityKey] { return existing }
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
        allLocations.append(location)
        indexLocation(location)
        pendingSorts.insert(.locations)
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
        coordinate: (Double, Double)? = nil
    ) -> VisitEntity {
        performBatch {
            guard let authorID = personID ?? currentPerson?.id else {
                preconditionFailure("A visit must be linked to a selected circle member.")
            }
            let visit = VisitEntity(context: context)
            assign(visit, alongside: location)
            visit.id = UUID(); visit.date = date; visit.createdAt = .now; visit.createdByID = authorID
            let resolvedCompanionIDs = canonicalCompanionIDs(companionIDs, excluding: authorID)
            visit.location = location; visit.circle = activeCircle
            visit.companionIDs = resolvedCompanionIDs
            visit.isShared = resolvedCompanionIDs.contains { id in
                circleMembers.contains { $0.id == id }
            }
            if let coordinate {
                visit.latitude = coordinate.0; visit.longitude = coordinate.1; visit.hasCoordinates = true
            } else if let coordinate = location.coordinate {
                visit.latitude = coordinate.latitude; visit.longitude = coordinate.longitude; visit.hasCoordinates = true
            }
            allVisits.append(visit)
            pendingSorts.insert(.visits)
            if let reaction { _ = addRating(to: visit, personID: authorID, reaction: reaction, hazy: hazy) }
            location.updatedAt = .now
            return visit
        }
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
        let resolvedCompanionIDs = canonicalCompanionIDs(companions, excluding: visit.createdByID)
        visit.companionIDs = resolvedCompanionIDs
        visit.isShared = resolvedCompanionIDs.contains { id in circleMembers.contains { $0.id == id } }
        commit()
    }

    /// Uses the earliest actual capture time when a set of meal photos was
    /// taken over several minutes. Fallback storage dates are intentionally
    /// ignored so screenshots and metadata-free images do not rewrite a visit.
    func updateVisitDateFromPhotoMetadata(_ visit: VisitEntity, photos: [BackfillPhoto]) {
        guard let captureDate = photos.compactMap(\.captureDate).min(), captureDate < visit.date else { return }
        visit.date = captureDate
        pendingSorts.insert(.visits)
        commit()
    }

    /// Earlier app versions retained each photo's capture time but did not copy
    /// it onto the visit. Apply those retained times across every dining circle.
    @discardableResult
    func syncVisitDatesWithStoredPhotoTimes() -> Int {
        let candidates = photoDateSyncCandidates
        guard !candidates.isEmpty else { return 0 }
        performBatch {
            for (visit, photoDate) in candidates {
                visit.date = photoDate
            }
            pendingSorts.insert(.visits)
        }
        return candidates.count
    }

    /// Reassigns a visit without leaving its dish evidence attached to the old
    /// establishment. Existing dishes at the destination are reused by name.
    func changeLocation(of visit: VisitEntity, to location: RestaurantLocation) {
        guard visit.location != location else { return }

        let previousLocation = visit.location
        let previousDishes = Set(visit.dishEntryArray.compactMap(\.dish))
        var destinationDishes: [String: DishEntity] = [:]
        for dish in location.dishArray {
            destinationDishes[dishLookupKey(dish.name)] = dish
        }

        for entry in visit.dishEntryArray {
            guard let previousDish = entry.dish else { continue }
            let key = dishLookupKey(previousDish.name)
            let destinationDish: DishEntity
            if let existing = destinationDishes[key] {
                destinationDish = existing
            } else {
                let newDish = DishEntity(context: context)
                assign(newDish, alongside: location)
                newDish.id = UUID(); newDish.name = previousDish.name; newDish.role = previousDish.role
                newDish.createdAt = previousDish.createdAt; newDish.isArchived = previousDish.isArchived
                newDish.location = location
                destinationDishes[key] = newDish
                destinationDish = newDish
            }
            entry.dish = destinationDish
        }

        let inheritedPreviousCoordinate = previousLocation.map {
            visit.hasCoordinates && $0.hasCoordinates &&
            abs(visit.latitude - $0.latitude) < 0.000_001 &&
            abs(visit.longitude - $0.longitude) < 0.000_001
        } ?? false
        visit.location = location
        if inheritedPreviousCoordinate {
            if let coordinate = location.coordinate {
                visit.latitude = coordinate.latitude; visit.longitude = coordinate.longitude; visit.hasCoordinates = true
            } else {
                visit.latitude = 0; visit.longitude = 0; visit.hasCoordinates = false
            }
        }

        context.processPendingChanges()
        for dish in previousDishes where dish.entryArray.isEmpty { context.delete(dish) }
        previousLocation?.updatedAt = .now
        location.updatedAt = .now
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

    func addPhoto(
        fullData: Data,
        thumbnailData: Data?,
        to visit: VisitEntity,
        createdAt: Date = .now,
        captureDate: Date? = nil
    ) {
        let photo = PhotoEntity(context: context)
        assign(photo, alongside: visit)
        photo.id = UUID(); photo.fullData = fullData; photo.thumbnailData = thumbnailData
        photo.createdAt = createdAt; photo.captureDate = captureDate; photo.visit = visit
        commit()
    }

    func recordComparison(a: RestaurantLocation, b: RestaurantLocation, outcome: ComparisonOutcome, personID: UUID? = nil) {
        guard a.id != b.id, let resolvedPersonID = personID ?? currentPerson?.id else { return }
        let comparison = ComparisonEntity(context: context)
        assign(comparison, alongside: activeCircle)
        comparison.id = UUID(); comparison.personID = resolvedPersonID
        comparison.locationAID = a.id; comparison.locationBID = b.id; comparison.outcome = outcome
        comparison.date = .now; comparison.isAnchor = false; comparison.anchorValue = 0; comparison.circle = activeCircle
        comparison.locationAEvidenceFingerprint = rankingEvidenceFingerprint(for: a, personID: resolvedPersonID)
        comparison.locationBEvidenceFingerprint = rankingEvidenceFingerprint(for: b, personID: resolvedPersonID)
        allComparisons.append(comparison)
        pendingSorts.insert(.comparisons)
        commit()
    }

    func recordAnchor(for location: RestaurantLocation, value: Double, personID: UUID? = nil) {
        guard let resolvedPersonID = personID ?? currentPerson?.id else { return }
        let evidenceFingerprint = rankingEvidenceFingerprint(for: location, personID: resolvedPersonID)
        let comparison = ComparisonEntity(context: context)
        assign(comparison, alongside: activeCircle)
        comparison.id = UUID(); comparison.personID = resolvedPersonID
        comparison.locationAID = location.id; comparison.locationBID = location.id; comparison.outcome = .tie
        comparison.date = .now; comparison.isAnchor = true; comparison.anchorValue = value; comparison.circle = activeCircle
        comparison.locationAEvidenceFingerprint = evidenceFingerprint
        comparison.locationBEvidenceFingerprint = evidenceFingerprint
        allComparisons.append(comparison)
        pendingSorts.insert(.comparisons)
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

    func circleRanked() -> [CircleLocationScore] {
        let personIDs = circleMembers.map(\.id)
        guard personIDs.count >= 2 else { return [] }
        invalidateScoreCacheIfStale()
        let key = personIDs.map(\.uuidString).sorted().joined(separator: "-")
        if let cached = circleScoreCache[key] { return cached }
        let result = rankingEngine.circleScores(
            locations: locations,
            comparisons: comparisons,
            personIDs: personIDs
        )
        circleScoreCache[key] = result
        return result
    }

    /// Reading `revision` here registers an observation dependency for every caller,
    /// so views recompute whenever the underlying records change.
    private func invalidateScoreCacheIfStale() {
        if cachedScoreRevision != revision {
            scoreCache.removeAll()
            circleScoreCache.removeAll()
            cachedScoreRevision = revision
        }
    }

    func score(for location: RestaurantLocation, personID: UUID? = nil) -> LocationScore? {
        ranked(for: personID).first { $0.id == location.id }
    }

    func pendingVisits(for personID: UUID? = nil) -> [VisitEntity] {
        guard let personID = personID ?? currentPerson?.id else { return [] }
        // `visits` is already maintained newest-first by the store cache.
        return visits.filter { $0.companionIDs.contains(personID) && $0.rating(for: personID) == nil }
    }

    func toggleWant(_ location: RestaurantLocation, by personID: UUID? = nil) {
        if let existing = wantEntries.first(where: { $0.location?.id == location.id }) {
            allWantEntries.removeAll { $0.id == existing.id }
            context.delete(existing)
        } else {
            guard let addedByID = personID ?? currentPerson?.id else {
                reportError("Choose who uses this device before saving a place.")
                return
            }
            let entry = WantEntryEntity(context: context)
            assign(entry, alongside: activeCircle)
            entry.id = UUID(); entry.addedByID = addedByID; entry.addedAt = .now
            entry.location = location; entry.circle = activeCircle
            allWantEntries.append(entry)
            pendingSorts.insert(.wantEntries)
        }
        commit()
    }

    func isWanted(_ location: RestaurantLocation) -> Bool { wantEntries.contains { $0.location?.id == location.id } }

    func updateLocation(_ location: RestaurantLocation, name: String, category: DiningCategory, cuisines: [String], tags: [String], isClosed: Bool) {
        location.name = name.trimmedOr(location.name); location.category = category; location.cuisines = cuisines
        location.tags = tags; location.isClosed = isClosed; location.updatedAt = .now
        rebuildLocationIndexes()
        pendingSorts.insert(.locations)
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
        rebuildLocationIndexes()
        pendingSorts.insert(.locations)
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
        var deletedComparisonIDs: Set<UUID> = []
        for comparison in comparisons {
            if comparison.locationAID == duplicate.id { comparison.locationAID = keeper.id }
            if comparison.locationBID == duplicate.id { comparison.locationBID = keeper.id }
            if comparison.locationAID == comparison.locationBID && !comparison.isAnchor {
                deletedComparisonIDs.insert(comparison.id)
                context.delete(comparison)
            }
        }
        allComparisons.removeAll { deletedComparisonIDs.contains($0.id) }
        allLocations.removeAll { $0.id == duplicate.id }
        context.delete(duplicate)
        rebuildLocationIndexes()
        commit()
    }

    func deleteVisit(_ visit: VisitEntity) {
        let visitID = visit.id
        let possibleOrphanedDishes = Set(visit.dishEntryArray.compactMap(\.dish))
        allVisits.removeAll { $0.id == visitID }
        context.delete(visit)
        context.processPendingChanges()
        for dish in possibleOrphanedDishes where dish.entryArray.isEmpty {
            context.delete(dish)
        }
        commit()
    }

    func deleteVisit(id: UUID) {
        guard let visit = allVisits.first(where: { $0.id == id }) else { return }
        deleteVisit(visit)
    }

    func deletePhoto(_ photo: PhotoEntity) { context.delete(photo); commit() }

    func deleteDishEntry(_ entry: DishEntryEntity) {
        let dish = entry.dish
        let remaining = dish?.entryArray.filter { $0.id != entry.id } ?? []
        context.delete(entry)
        if let dish, remaining.isEmpty { context.delete(dish) }
        commit()
    }

    func settleQuestions(limit: Int = 5, personID: UUID? = nil) -> [ComparisonQuestion] {
        guard let personID = personID ?? currentPerson?.id else { return [] }
        let scores = ranked(for: personID)
        var latestComparisonByPair: [PairKey: ComparisonEntity] = [:]
        for comparison in comparisons where comparison.personID == personID && !comparison.isAnchor && comparison.outcome != .skipped {
            let key = PairKey(comparison.locationAID, comparison.locationBID)
            if latestComparisonByPair[key].map({ $0.date >= comparison.date }) != true {
                latestComparisonByPair[key] = comparison
            }
        }
        let scoresByCategory = Dictionary(grouping: scores, by: { $0.location.category })
        let certaintyByLocation = Dictionary(uniqueKeysWithValues: scores.map { ($0.id, $0.certainty) })
        let evidenceByLocation = Dictionary(uniqueKeysWithValues: scores.map {
            ($0.id, rankingEvidenceFingerprint(for: $0.location, personID: personID))
        })
        var result: [ComparisonQuestion] = []
        for category in DiningCategory.allCases {
            let categoryScores = scoresByCategory[category] ?? []
            for pair in zip(categoryScores, categoryScores.dropFirst()) {
                let previous = latestComparisonByPair[PairKey(pair.0.id, pair.1.id)]
                if previous.map({ !comparisonMatchesCurrentEvidence(
                    $0, firstID: pair.0.id, secondID: pair.1.id, evidenceByLocation: evidenceByLocation
                ) }) ?? true {
                    result.append(.init(a: pair.0.location, b: pair.1.location))
                }
            }
        }
        return Array(result.sorted { lhs, rhs in
            let lhsCertainty = (certaintyByLocation[lhs.a.id] ?? 0) + (certaintyByLocation[lhs.b.id] ?? 0)
            let rhsCertainty = (certaintyByLocation[rhs.a.id] ?? 0) + (certaintyByLocation[rhs.b.id] ?? 0)
            return lhsCertainty < rhsCertainty
        }.prefix(limit))
    }

    func settleScorePrompts(limit: Int = 5, personID: UUID? = nil) -> [SettleScorePrompt] {
        guard limit > 0, let resolvedPersonID = personID ?? currentPerson?.id else { return [] }
        let scores = ranked(for: resolvedPersonID)
        let anchor = unsettledAnchorPrompt(in: scores, personID: resolvedPersonID)
        let comparisonLimit = max(0, limit - (anchor == nil ? 0 : 1))
        var prompts = settleQuestions(limit: comparisonLimit, personID: resolvedPersonID).map(SettleScorePrompt.comparison)
        if let anchor {
            prompts.insert(anchor, at: min(2, prompts.count))
        }
        return prompts
    }

    /// Runs related mutations as one transaction. Mutation methods keep the
    /// in-memory caches current; only the outermost batch saves and publishes.
    @discardableResult
    func performBatch<T>(_ work: () -> T) -> T {
        guard !isBatching else { return work() }
        isBatching = true
        let result = work()
        isBatching = false
        commit()
        return result
    }

    func seedSampleLog() {
        if circles.isEmpty { bootstrap(myName: "George") }
        guard locations.isEmpty, let me = currentPerson,
              let michelle = addCircleMember(name: "Michelle") else { return }
        performBatch { seedSampleVisits(me: me, companion: michelle) }
    }

    private func seedSampleVisits(me: PersonEntity, companion: PersonEntity) {
        let samples: [(String, DiningCategory, [String], Reaction, Reaction, Int, (Double, Double))] = [
            ("The Copper Onion", .fullService, ["New American"], .loved, .loved, 3, (40.7635, -111.8840)),
            ("Central 9th Market", .counterService, ["Sandwiches"], .loved, .liked, 2, (40.7492, -111.8974)),
            ("Publik Coffee", .coffeeTea, ["Coffee"], .liked, .loved, 2, (40.7508, -111.9005)),
            ("Eva’s Bakery", .bakeries, ["French", "Pastry"], .loved, .loved, 2, (40.7640, -111.8872)),
            ("Fisher Brewing", .barsBreweries, ["Brewery"], .liked, .fine, 2, (40.7504, -111.9000)),
            ("Normal Ice Cream", .dessert, ["Ice Cream"], .loved, .liked, 1, (40.7632, -111.8707)),
            ("Yoko Ramen", .fullService, ["Japanese", "Ramen"], .liked, .notForMe, 2, (40.7641, -111.8775)),
            ("Tacos Don Rafa", .trucksStands, ["Mexican", "Tacos"], .loved, .loved, 1, (40.7596, -111.8877)),
            ("Pretty Bird", .counterService, ["Fried Chicken"], .liked, .liked, 2, (40.7637, -111.8869))
        ]
        for (offset, sample) in samples.enumerated() {
            let location = createLocation(
                name: sample.0,
                category: sample.1,
                city: "Salt Lake City",
                coordinate: sample.6,
                cuisines: sample.2
            )
            for visitIndex in 0..<sample.5 {
                let date = Calendar.current.date(byAdding: .day, value: -(offset * 19 + visitIndex * 110), to: .now) ?? .now
                let visit = logVisit(at: location, reaction: sample.3, personID: me.id, date: date, companionIDs: [companion.id])
                _ = addRating(to: visit, personID: companion.id, reaction: sample.4)
                visit.visitType = sample.1 == .coffeeTea ? .coffee : .meal
                visit.priceBand = Int16((offset % 3) + 1)
            }
        }
        if let ramen = locations.first(where: { $0.name == "Yoko Ramen" }), let normal = locations.first(where: { $0.name == "Normal Ice Cream" }) {
            recordComparison(a: normal, b: ramen, outcome: .a, personID: me.id)
        }
    }

    func reload() {
        remoteReloadTask?.cancel()
        remoteReloadTask = nil
        diagnosticReloadCount += 1
        do {
            let previousCircleIDs = Set(circles.map(\.id))
            let previousDevicePersonID = devicePersonID
            circles = try fetch(CircleEntity.self, sort: [NSSortDescriptor(key: "createdAt", ascending: true)])
            allPeople = try fetch(PersonEntity.self, sort: [NSSortDescriptor(key: "createdAt", ascending: true)])
            allLocations = try fetch(RestaurantLocation.self, sort: [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))])
            rebuildLocationIndexes()
            allVisits = try fetch(VisitEntity.self, sort: [NSSortDescriptor(key: "date", ascending: false)])
            allComparisons = try fetch(ComparisonEntity.self, sort: [NSSortDescriptor(key: "date", ascending: false)])
            allWantEntries = try fetch(WantEntryEntity.self, sort: [NSSortDescriptor(key: "addedAt", ascending: false)])
            let reconciledPeople = reconcileDuplicatePeople()
            let backfilledComparisons = backfillComparisonEvidenceFingerprints()
            if reconciledPeople || backfilledComparisons {
                do { try persistence.save() }
                catch { reportError("Older circle data could not be upgraded yet. \(error.localizedDescription)") }
            }
            let acceptedCircle = circles.first(where: { !previousCircleIDs.contains($0.id) })
                ?? circles.filter(isStoredInSharedDatabase).max(by: { $0.createdAt < $1.createdAt })
            if isWaitingForAcceptedCircle, let acceptedCircle {
                activeCircleID = acceptedCircle.id
                devicePersonID = nil
                isWaitingForAcceptedCircle = false
            } else if activeCircleID == nil || !circles.contains(where: { $0.id == activeCircleID }) {
                activeCircleID = circles.first?.id
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
            pendingSorts.removeAll()
            persistDeviceSelection()
            revision += 1
        } catch { reportError("Big Beautiful Log could not reload your saved data. \(error.localizedDescription)") }
    }

    private func commit() {
        guard !isBatching else { return }
        do {
            try persistence.save()
            sortPendingCollections()
            revision += 1
        } catch {
            context.rollback()
            reload()
            reportError("Your latest changes could not be saved. \(error.localizedDescription)")
        }
    }

    private func scheduleRemoteReload() {
        remoteReloadTask?.cancel()
        remoteReloadTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func sortPendingCollections() {
        if pendingSorts.contains(.locations) {
            allLocations.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        if pendingSorts.contains(.visits) {
            allVisits.sort { $0.date > $1.date }
        }
        if pendingSorts.contains(.comparisons) {
            allComparisons.sort { $0.date > $1.date }
        }
        if pendingSorts.contains(.wantEntries) {
            allWantEntries.sort { $0.addedAt > $1.addedAt }
        }
        pendingSorts.removeAll()
    }

    private func makePerson(name: String, isCircleMember: Bool, color: String, circle: CircleEntity) -> PersonEntity {
        let person = PersonEntity(context: context)
        assign(person, alongside: circle)
        person.id = UUID(); person.name = name.trimmedOr("Guest"); person.isMe = false; person.isCircleMember = isCircleMember; person.colorHex = color
        person.createdAt = .now; person.circle = circle
        allPeople.append(person)
        return person
    }

    private func person(named name: String) -> PersonEntity? {
        let key = personLookupKey(name)
        return people.first { personLookupKey($0.name) == key }
    }

    private func personLookupKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private func personComesBefore(_ lhs: PersonEntity, _ rhs: PersonEntity) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func canonicalCompanionIDs(_ ids: [UUID], excluding authorID: UUID) -> [UUID] {
        let requested = Set(ids).subtracting([authorID])
        return people.filter { requested.contains($0.id) }.map(\.id)
    }

    private func memberColor(at index: Int) -> String {
        let colors = ["6F1D2B", "2F5964", "9A5B3A", "43533D", "775A7A", "9B7B34"]
        return colors[index % colors.count]
    }

    /// Person names are unique within a circle. Older builds could split one name
    /// across a member and a reusable companion, while two offline devices can
    /// independently add the same name before CloudKit syncs. Every replica picks
    /// the same canonical UUID: prefer a member, then the earliest creation date,
    /// then UUID. All linked records are rewritten before duplicate people are
    /// deleted, so concurrent additions converge without losing history.
    @discardableResult
    private func reconcileDuplicatePeople() -> Bool {
        let byCircle = Dictionary(grouping: allPeople) { $0.circle?.id }
        var replacementIDs: [UUID: UUID] = [:]
        var duplicatePeople: [PersonEntity] = []

        for circlePeople in byCircle.values {
            let byName = Dictionary(grouping: circlePeople) { personLookupKey($0.name) }
            for matchingPeople in byName.values {
                guard matchingPeople.count > 1 else { continue }
                let ordered = matchingPeople.sorted { lhs, rhs in
                    if lhs.isCircleMember != rhs.isCircleMember { return lhs.isCircleMember }
                    return personComesBefore(lhs, rhs)
                }
                guard let canonical = ordered.first else { continue }
                for duplicate in ordered.dropFirst() {
                    replacementIDs[duplicate.id] = canonical.id
                    duplicatePeople.append(duplicate)
                }
            }
        }
        guard !replacementIDs.isEmpty else { return false }

        func canonicalID(_ id: UUID) -> UUID { replacementIDs[id] ?? id }

        for visit in allVisits {
            visit.createdByID = canonicalID(visit.createdByID)
            visit.companionIDs = visit.companionIDs
                .map(canonicalID)
                .filter { $0 != visit.createdByID }

            var newestRatingByPerson: [UUID: RatingEntity] = [:]
            for rating in visit.ratingArray.sorted(by: { $0.createdAt < $1.createdAt }) {
                let personID = canonicalID(rating.personID)
                if let olderRating = newestRatingByPerson[personID] {
                    context.delete(olderRating)
                }
                rating.personID = personID
                newestRatingByPerson[personID] = rating
            }
            var newestDishEntryByPersonAndDish: [String: DishEntryEntity] = [:]
            for entry in visit.dishEntryArray.sorted(by: { $0.createdAt < $1.createdAt }) {
                let personID = canonicalID(entry.personID)
                entry.personID = personID
                guard let dishID = entry.dish?.id else { continue }
                let key = "\(personID.uuidString)-\(dishID.uuidString)"
                if let olderEntry = newestDishEntryByPersonAndDish[key] {
                    context.delete(olderEntry)
                }
                newestDishEntryByPersonAndDish[key] = entry
            }

            let memberIDs = Set(allPeople.filter {
                $0.circle?.id == visit.circle?.id && $0.isCircleMember
            }.map(\.id))
            visit.isShared = visit.companionIDs.contains { memberIDs.contains($0) }
        }
        for comparison in allComparisons {
            let personID = canonicalID(comparison.personID)
            if personID != comparison.personID {
                comparison.personID = personID
                comparison.locationAEvidenceFingerprint = ""
                comparison.locationBEvidenceFingerprint = ""
            }
        }
        for entry in allWantEntries {
            entry.addedByID = canonicalID(entry.addedByID)
        }

        if let devicePersonID { self.devicePersonID = canonicalID(devicePersonID) }
        for (circleID, personIDString) in Array(devicePersonIDsByCircle) {
            guard let personID = UUID(uuidString: personIDString) else { continue }
            devicePersonIDsByCircle[circleID] = canonicalID(personID).uuidString
        }
        let duplicateIDs = Set(duplicatePeople.map(\.id))
        for person in duplicatePeople { context.delete(person) }
        allPeople.removeAll { duplicateIDs.contains($0.id) }
        context.processPendingChanges()
        return true
    }

    private func dishLookupKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private var photoDateSyncCandidates: [(visit: VisitEntity, photoDate: Date)] {
        allVisits.compactMap { visit in
            guard let photoDate = visit.photoArray.compactMap(\.captureDate).min(), photoDate < visit.date else { return nil }
            return (visit, photoDate)
        }
    }

    private func indexLocation(_ location: RestaurantLocation) {
        let identity = LocationIdentityKey(
            circleID: location.circle?.id,
            name: location.name,
            address: location.address
        )
        if locationsByIdentity[identity] == nil { locationsByIdentity[identity] = location }
        if let sourceIdentifier = location.sourceIdentifier, !sourceIdentifier.isEmpty {
            let source = LocationSourceKey(circleID: location.circle?.id, sourceIdentifier: sourceIdentifier)
            if locationsBySource[source] == nil { locationsBySource[source] = location }
        }
    }

    private func rebuildLocationIndexes() {
        locationsByIdentity.removeAll(keepingCapacity: true)
        locationsBySource.removeAll(keepingCapacity: true)
        for location in allLocations { indexLocation(location) }
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

    private func comparisonMatchesCurrentEvidence(
        _ comparison: ComparisonEntity,
        firstID: UUID,
        secondID: UUID,
        evidenceByLocation: [UUID: String]
    ) -> Bool {
        guard let firstEvidence = evidenceByLocation[firstID], let secondEvidence = evidenceByLocation[secondID] else {
            return true
        }
        if comparison.locationAID == firstID, comparison.locationBID == secondID {
            return comparison.locationAEvidenceFingerprint == firstEvidence &&
                comparison.locationBEvidenceFingerprint == secondEvidence
        }
        if comparison.locationAID == secondID, comparison.locationBID == firstID {
            return comparison.locationAEvidenceFingerprint == secondEvidence &&
                comparison.locationBEvidenceFingerprint == firstEvidence
        }
        return false
    }

    /// A score check calibrates the person's shared 0–100 scale, so one current
    /// answer settles the calibration prompt. It becomes eligible again only when
    /// the ranking evidence for the previously checked restaurant changes.
    private func unsettledAnchorPrompt(in scores: [LocationScore], personID: UUID) -> SettleScorePrompt? {
        guard let leastCertain = scores.min(by: { $0.certainty < $1.certainty }) else { return nil }
        guard let latestAnchor = comparisons
            .filter({ $0.personID == personID && $0.isAnchor })
            .max(by: { $0.date < $1.date }) else {
            return .anchor(leastCertain.location)
        }
        guard let anchoredLocation = scores.first(where: { $0.id == latestAnchor.locationAID })?.location else {
            return .anchor(leastCertain.location)
        }

        let currentEvidence = rankingEvidenceFingerprint(for: anchoredLocation, personID: personID)
        let isCurrent = latestAnchor.locationAEvidenceFingerprint == currentEvidence &&
            latestAnchor.locationBEvidenceFingerprint == currentEvidence
        return isCurrent ? nil : .anchor(anchoredLocation)
    }

    /// Hashes exactly the person-specific visit, rating, and dish fields consumed by
    /// RankingEngine before pair comparisons. Metadata, elapsed time, anchors, and
    /// other comparisons intentionally cannot make a settled matchup reappear.
    private func rankingEvidenceFingerprint(for location: RestaurantLocation, personID: UUID) -> String {
        let ratedVisits = location.visitArray.compactMap { visit -> RatedVisitEvidence? in
            guard let rating = visit.rating(for: personID) else { return nil }
            return RatedVisitEvidence(
                visitID: visit.id,
                visitDateBits: visit.date.timeIntervalSinceReferenceDate.bitPattern,
                ratingID: rating.id,
                reaction: rating.reactionRaw,
                service: rating.serviceRaw,
                atmosphere: rating.atmosphereRaw,
                value: rating.valueRaw,
                hazyMemory: rating.hazyMemory,
                wouldOrderAgain: rating.wouldOrderAgain,
                hasWouldOrderAgain: rating.hasWouldOrderAgain
            )
        }.sorted { $0.visitID.uuidString < $1.visitID.uuidString }
        let dishEntries = location.dishArray.flatMap { dish in
            dish.entryArray.compactMap { entry -> DishEvidence? in
                guard entry.personID == personID else { return nil }
                return DishEvidence(
                    entryID: entry.id,
                    visitID: entry.visit?.id,
                    dishID: dish.id,
                    role: dish.roleRaw,
                    reaction: entry.reactionRaw,
                    wouldOrderAgain: entry.wouldOrderAgain
                )
            }
        }.sorted { $0.entryID.uuidString < $1.entryID.uuidString }
        let snapshot = RankingEvidenceSnapshot(version: 1, ratedVisits: ratedVisits, dishEntries: dishEntries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(snapshot)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func backfillComparisonEvidenceFingerprints() -> Bool {
        let locationsByID = Dictionary(uniqueKeysWithValues: allLocations.map { ($0.id, $0) })
        var fingerprintCache: [PersonLocationKey: String] = [:]
        var changed = false

        func fingerprint(locationID: UUID, personID: UUID) -> String? {
            let key = PersonLocationKey(personID: personID, locationID: locationID)
            if let cached = fingerprintCache[key] { return cached }
            guard let location = locationsByID[locationID] else { return nil }
            let value = rankingEvidenceFingerprint(for: location, personID: personID)
            fingerprintCache[key] = value
            return value
        }

        for comparison in allComparisons {
            if comparison.locationAEvidenceFingerprint.isEmpty,
               let value = fingerprint(locationID: comparison.locationAID, personID: comparison.personID) {
                comparison.locationAEvidenceFingerprint = value
                changed = true
            }
            if comparison.locationBEvidenceFingerprint.isEmpty,
               let value = fingerprint(locationID: comparison.locationBID, personID: comparison.personID) {
                comparison.locationBEvidenceFingerprint = value
                changed = true
            }
        }
        return changed
    }

    private struct RankingEvidenceSnapshot: Encodable {
        let version: Int
        let ratedVisits: [RatedVisitEvidence]
        let dishEntries: [DishEvidence]
    }

    private struct RatedVisitEvidence: Encodable {
        let visitID: UUID
        let visitDateBits: UInt64
        let ratingID: UUID
        let reaction: String
        let service: String?
        let atmosphere: String?
        let value: String?
        let hazyMemory: Bool
        let wouldOrderAgain: Bool
        let hasWouldOrderAgain: Bool
    }

    private struct DishEvidence: Encodable {
        let entryID: UUID
        let visitID: UUID?
        let dishID: UUID
        let role: String
        let reaction: String
        let wouldOrderAgain: Bool
    }

    private struct PersonLocationKey: Hashable {
        let personID: UUID
        let locationID: UUID
    }

    private struct PairKey: Hashable {
        let low: UUID
        let high: UUID
        init(_ a: UUID, _ b: UUID) {
            if a.uuidString <= b.uuidString { low = a; high = b } else { low = b; high = a }
        }
    }

    private struct LocationIdentityKey: Hashable {
        let circleID: UUID?
        let name: String
        let address: String

        init(circleID: UUID?, name: String, address: String?) {
            self.circleID = circleID
            self.name = name.precomposedStringWithCanonicalMapping.lowercased(with: .current)
            self.address = address ?? ""
        }
    }

    private struct LocationSourceKey: Hashable {
        let circleID: UUID?
        let sourceIdentifier: String
    }

    private enum CachedCollection: Hashable {
        case locations
        case visits
        case comparisons
        case wantEntries
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
        } else {
            UserDefaults.standard.removeObject(forKey: "devicePersonID")
        }
        if devicePersonIDsByCircle.isEmpty {
            UserDefaults.standard.removeObject(forKey: "devicePersonIDsByCircle")
        } else {
            UserDefaults.standard.set(devicePersonIDsByCircle, forKey: "devicePersonIDsByCircle")
        }
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
