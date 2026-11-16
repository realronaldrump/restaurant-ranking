import CoreLocation
import MapKit
import Observation
import PhotosUI
import SwiftUI

/// One tappable answer to a wizard question.
struct WizardOption: Identifiable, Equatable {
    /// Where an answer sits between best and worst, which decides its color.
    enum Tone { case best, good, okay, poor, plain }

    let id: String
    let title: String
    var symbol: String?
    /// Text drawn in place of a symbol, such as "$$".
    var glyph: String?
    var tone: Tone = .plain
}

/// An answer already given, shown on the last step so it can be changed.
struct WizardRecapItem: Identifiable {
    let step: OutingWizardModel.Step
    let title: String
    let symbol: String?
    var id: OutingWizardModel.Step { step }
}

extension PlaceChoice {
    var isInLog: Bool {
        if case .existing = source { return true }
        return false
    }
}

/// Everything the logging wizard knows and does, kept apart from how it looks.
///
/// The outing is saved the moment a reaction is tapped. Every answer after
/// that is written straight to the saved outing, so the wizard can be left at
/// any point without losing anything, and any earlier answer — the restaurant
/// included — can be changed in place by stepping back to it.
///
/// Nothing about a saved outing is mirrored here. Answers, score and rank are
/// read from the store each time, so they stay right after the full editor is
/// used or a sync lands.
@MainActor
@Observable
final class OutingWizardModel {
    enum Step: Hashable {
        case place, reaction, people, clarity, goBack, value, service, vibe, kind, price, occasion, dishes, ranking
    }

    enum SaveOutcome { case saved, needsDecision, failed }
    enum Nudge { case up, down }

    struct NudgeEvent: Equatable {
        let id: Int
        let direction: Nudge
    }

    struct Suggestion: Identifiable {
        let choice: PlaceChoice
        let caption: String
        var id: String { choice.id }
    }

    struct SuggestionGroup: Identifiable {
        let id: String
        let title: String
        /// Whether the first suggestion is the nearest one, and so worth
        /// offering as the single most likely answer.
        let leadsWithClosest: Bool
        let suggestions: [Suggestion]
    }

    /// Where a restaurant stood before this outing. It belongs to that one
    /// restaurant: if the outing is moved elsewhere it no longer applies.
    private struct Baseline {
        let locationID: UUID
        let score: Double?
    }

    /// How many face-offs follow a save: enough to slot the restaurant between
    /// its neighbours without turning a quick log into a ranking session.
    static let dialInRounds = 3

    @ObservationIgnored let store: AppStore
    @ObservationIgnored let locationService: LocationService
    @ObservationIgnored private let initialLocationID: UUID?
    @ObservationIgnored private var photoRequestID = UUID()
    @ObservationIgnored private var nudgeCount = 0

    private(set) var step: Step = .place
    private(set) var isMovingForward = true
    /// Set while one answer is being changed from the recap, so answering it
    /// returns to the last step instead of walking the rest of the questions.
    private(set) var isEditingOneAnswer = false

    // Where
    private(set) var choice: PlaceChoice?
    var query = ""
    var mapResults: [PlaceCandidate] = []
    private(set) var askedForNearby = false
    private var draftPhoto: BackfillPhoto?
    private var savedPhotoID: UUID?
    private var photoMapResults: [PlaceCandidate] = []
    private(set) var isReadingPhoto = false
    private(set) var photoError: String?

    // When and with whom
    private var draftDate = Date.now
    private var draftDateKnowledge: VisitDateKnowledge = .known
    private var draftCompanionIDs: Set<UUID> = []

    // Core Data is the source of truth after saving, including edits and sync.
    var visitDate: Date {
        _ = store.revision
        return savedVisit.flatMap { $0.isAlive ? $0.date : nil } ?? draftDate
    }

    var visitDateKnowledge: VisitDateKnowledge {
        _ = store.revision
        return savedVisit.flatMap { $0.isAlive ? $0.dateKnowledge : nil } ?? draftDateKnowledge
    }

    var visitTimeZoneOffsetSeconds: Int? {
        _ = store.revision
        if let visit = savedVisit, visit.isAlive { return visit.dateTimeZoneOffsetSeconds?.intValue }
        return draftPhoto?.captureTimeZoneOffsetSeconds
    }

    var companionIDs: Set<UUID> {
        _ = store.revision
        if let visit = savedVisit, visit.isAlive { return Set(visit.companionIDs) }
        return draftCompanionIDs
    }

    var mealPhoto: BackfillPhoto? {
        _ = store.revision
        if isSaved {
            guard let visit = savedVisit, visit.isAlive,
                  visit.photoArray.contains(where: { $0.id == savedPhotoID }) else { return nil }
        }
        return draftPhoto
    }

    // Saving
    /// The reaction that was tapped and is about to be saved.
    private(set) var pendingReaction: Reaction?
    var saveError: String?
    var duplicateOuting: VisitEntity?

    // What was saved
    private(set) var savedVisit: VisitEntity?
    private(set) var savedPersonID: UUID?
    private var baseline: Baseline?
    private var createdRestaurantIDs: Set<UUID> = []
    private(set) var canUndo = false
    private var didAnswerClarity = false

    // Ranking
    private var dialInLocationID: UUID?
    private(set) var opponent: RestaurantLocation?
    private var askedIDs: Set<UUID> = []
    private var recordedAnswerIDs: [UUID] = []
    private(set) var round = 0
    private(set) var lastNudge: NudgeEvent?

    init(store: AppStore, locationService: LocationService, initialLocationID: UUID? = nil) {
        self.store = store
        self.locationService = locationService
        self.initialLocationID = initialLocationID
    }

    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-resetForUITests")
    }

    func start() {
        if let initialLocationID, let location = store.locations.first(where: { $0.id == initialLocationID }) {
            choice = location.placeChoice
            step = .reaction
        }
        guard !Self.isUITesting else { return }
        switch locationService.authorization {
        case .authorizedAlways, .authorizedWhenInUse: requestNearby()
        default: break
        }
    }

    // MARK: - Steps

    var isSaved: Bool { savedVisit != nil }

    /// The questions, most valuable to the ranking first, so leaving early
    /// still captures what matters most.
    var steps: [Step] {
        var result: [Step] = [.place, .reaction]
        if canEditOutingDetails { result.append(.people) }
        if needsClarity { result.append(.clarity) }
        result += [.goBack, .value, .service, .vibe]
        if canEditOutingDetails { result += [.kind, .price, .occasion] }
        result += [.dishes, .ranking]
        return result
    }

    /// Only an outing from a while back is asked how well it is remembered.
    private var needsClarity: Bool {
        visitDateKnowledge == .unknown || visitDate < Date.now.addingTimeInterval(-21 * 86_400)
    }

    /// The outing's shared facts belong to whoever logged it. Someone adding
    /// their entry to another person's outing is only asked about their own.
    var canEditOutingDetails: Bool {
        guard let visit = savedVisit, visit.isAlive, let savedPersonID else { return true }
        return store.canEditOuting(visit, personID: savedPersonID)
    }

    var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }

    var previousStep: Step? {
        if isEditingOneAnswer { return .ranking }
        let all = steps
        guard let index = all.firstIndex(of: step), index > 0 else { return nil }
        let previous = all[index - 1]
        if previous == .place, isSaved, !canEditOutingDetails { return nil }
        return previous
    }

    func go(to next: Step) {
        let all = steps
        isMovingForward = (all.firstIndex(of: next) ?? 0) >= (all.firstIndex(of: step) ?? 0)
        if next == .ranking { prepareRanking() }
        step = next
    }

    func advance() {
        if isEditingOneAnswer {
            isEditingOneAnswer = false
            go(to: .ranking)
            return
        }
        let all = steps
        guard let index = all.firstIndex(of: step), index + 1 < all.count else { return }
        go(to: all[index + 1])
    }

    func back() {
        guard let previous = previousStep else { return }
        isEditingOneAnswer = false
        go(to: previous)
    }

    /// Jumps to one question from the recap and comes straight back.
    func edit(_ target: Step) {
        isEditingOneAnswer = true
        go(to: target)
    }

    func skipToRanking() {
        isEditingOneAnswer = false
        go(to: .ranking)
    }

    // MARK: - Where

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var placeSearchKey: PlaceSearchKey {
        .init(
            query: query,
            latitude: mealPhoto?.coordinate?.latitude,
            longitude: mealPhoto?.coordinate?.longitude
        )
    }

    func runMapSearch() async {
        guard !trimmedQuery.isEmpty, !Self.isUITesting else {
            mapResults = []
            return
        }
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        mapResults = await locationService.search(trimmedQuery, around: mealPhoto?.coordinate)
    }

    func requestNearby() {
        askedForNearby = true
        locationService.requestNearby()
    }

    var suggestionGroups: [SuggestionGroup] {
        var seen = Set<String>()
        func fresh(_ suggestions: [Suggestion], limit: Int) -> [Suggestion] {
            var result: [Suggestion] = []
            for suggestion in suggestions where result.count < limit && seen.insert(suggestion.id).inserted {
                result.append(suggestion)
            }
            return result
        }
        var groups: [SuggestionGroup] = []
        if mealPhoto?.coordinate != nil {
            let nearPhoto = fresh(photoSuggestions, limit: 5)
            if !nearPhoto.isEmpty {
                groups.append(.init(id: "photo", title: "Near your photo", leadsWithClosest: true, suggestions: nearPhoto))
            }
        }
        let nearby = fresh(nearbySuggestions, limit: 5)
        if !nearby.isEmpty {
            groups.append(.init(id: "nearby", title: "Nearby", leadsWithClosest: true, suggestions: nearby))
        }
        let recent = fresh(recentSuggestions, limit: 6)
        if !recent.isEmpty {
            groups.append(.init(id: "recent", title: "Recent", leadsWithClosest: false, suggestions: recent))
        }
        return groups
    }

    private var nearbySuggestions: [Suggestion] {
        let origin = locationService.usableCurrentLocation
        return locationService.nearby.map { candidate in
            Suggestion(
                choice: placeChoice(for: candidate),
                caption: origin.map { Self.distanceCaption($0.distance(from: candidate.clLocation)) }
                    ?? candidate.shortAddress
            )
        }
    }

    /// Whatever was eaten at most recently, by anyone in the log: the places
    /// most likely to be logged again.
    private var recentSuggestions: [Suggestion] {
        var seen = Set<UUID>()
        var result: [Suggestion] = []
        for visit in store.visits where visit.isAlive {
            guard let location = visit.location, location.isAlive, !location.isClosed,
                  seen.insert(location.id).inserted else { continue }
            result.append(.init(choice: location.placeChoice, caption: location.category.shortTitle))
            if result.count == 8 { break }
        }
        if result.isEmpty {
            result = store.locations.filter { !$0.isClosed }.prefix(8).map {
                .init(choice: $0.placeChoice, caption: $0.category.shortTitle)
            }
        }
        return result
    }

    private var photoSuggestions: [Suggestion] {
        guard let coordinate = mealPhoto?.coordinate else { return [] }
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let known = store.locations.compactMap { location -> (PlaceChoice, CLLocationDistance)? in
            guard !location.isClosed, let value = location.coordinate else { return nil }
            let distance = origin.distance(from: CLLocation(latitude: value.latitude, longitude: value.longitude))
            guard distance <= MealPhotoDraftPolicy.restaurantLookupRadius else { return nil }
            return (location.placeChoice, distance)
        }
        let mapped = photoMapResults.map { (placeChoice(for: $0), origin.distance(from: $0.clLocation)) }
        var seenNames = Set<String>()
        return (known + mapped)
            .sorted { $0.1 < $1.1 }
            .compactMap { choice, distance in
                let key = choice.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard seenNames.insert(key).inserted else { return nil }
                return Suggestion(choice: choice, caption: Self.distanceCaption(distance))
            }
    }

    /// Matches for what has been typed: the log first, then the map, with
    /// anything the map returns that is already in the log shown as that.
    var searchMatches: (known: [PlaceChoice], mapped: [PlaceChoice]) {
        let known = Array(
            store.locations
                .filter { !$0.isClosed && $0.matchesPlaceQuery(trimmedQuery) }
                .map(\.placeChoice)
                .prefix(6)
        )
        var seen = Set(known.map(\.id))
        let mapped = mapResults.map(placeChoice(for:)).filter { seen.insert($0.id).inserted }
        return (known, Array(mapped.prefix(8)))
    }

    var manualChoice: PlaceChoice {
        .init(
            source: .manual(trimmedQuery),
            id: "manual-\(trimmedQuery)",
            name: trimmedQuery,
            subtitle: "New restaurant",
            category: DiningCategory.suggested(for: trimmedQuery)
        )
    }

    /// A map result that is already in the log is offered as that restaurant,
    /// so the same place never appears twice or looks new when it is not.
    private func placeChoice(for candidate: PlaceCandidate) -> PlaceChoice {
        if let known = store.existingLocation(
            sourceIdentifier: candidate.id,
            name: candidate.name,
            address: candidate.address
        ), known.isAlive, !known.isClosed {
            return known.placeChoice
        }
        return .init(
            source: .map(candidate),
            id: "map-\(candidate.id)",
            name: candidate.name,
            subtitle: candidate.address ?? candidate.suggestedCategory.shortTitle,
            category: candidate.suggestedCategory
        )
    }

    private static let distanceFormatter: MKDistanceFormatter = {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        return formatter
    }()

    private static func distanceCaption(_ distance: CLLocationDistance) -> String {
        distanceFormatter.string(fromDistance: distance)
    }

    /// Picks the restaurant. Before the save this only records the choice;
    /// afterwards it moves the saved outing, which is how a mistapped
    /// restaurant is corrected without starting again.
    func select(_ newChoice: PlaceChoice) {
        saveError = nil
        pendingReaction = nil
        if isSaved { relocate(to: newChoice) } else { choice = newChoice }
        go(to: .reaction)
    }

    private func existingLocation(for choice: PlaceChoice) -> RestaurantLocation? {
        switch choice.source {
        case .existing(let location):
            return location
        case .map(let candidate):
            return store.existingLocation(
                sourceIdentifier: candidate.id,
                name: candidate.name,
                address: candidate.address
            )
        case .manual(let name):
            return store.existingLocation(name: name)
        }
    }

    private func resolveLocation(for choice: PlaceChoice) -> RestaurantLocation {
        switch choice.source {
        case .existing(let value):
            return value
        case .map(let candidate):
            return store.createLocation(
                name: candidate.name, category: candidate.suggestedCategory, address: candidate.address, city: candidate.city,
                coordinate: (candidate.latitude, candidate.longitude), phone: candidate.phone, url: candidate.url,
                sourceIdentifier: candidate.id, cuisines: candidate.cuisines
            )
        case .manual(let name):
            return store.createLocation(name: name, category: DiningCategory.suggested(for: name))
        }
    }

    private func relocate(to newChoice: PlaceChoice) {
        reconcileRanking()
        guard let visit = savedVisit, visit.isAlive, let personID = savedPersonID,
              store.canEditOuting(visit, personID: personID) else { return }
        let previous = visit.location
        let existing = existingLocation(for: newChoice)
        choice = newChoice
        guard existing == nil || existing?.id != previous?.id else { return }
        let scoreBefore = existing.flatMap { store.score(for: $0, personID: personID) }?.score
        store.performBatch {
            let destination = resolveLocation(for: newChoice)
            store.changeLocation(of: visit, to: destination, editorID: personID)
            if existing == nil { createdRestaurantIDs.insert(destination.id) }
        }
        if let location = loggedLocation {
            guard location.id != previous?.id else { return }
            reconcileRanking()
            baseline = Baseline(locationID: location.id, score: scoreBefore)
        }
    }

    // MARK: - Photo

    func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        let requestID = UUID()
        photoRequestID = requestID
        isReadingPhoto = true
        photoError = nil
        photoMapResults = []

        guard let photo = await ImageSanitizer.processSelected(
            [item],
            fallbackDate: .now,
            maxConcurrent: 1
        ).first else {
            guard photoRequestID == requestID else { return }
            isReadingPhoto = false
            photoError = "That photo could not be read. Try another one."
            return
        }
        guard photoRequestID == requestID, !Task.isCancelled else { return }
        guard applyPhoto(photo) else {
            isReadingPhoto = false
            return
        }

        if let coordinate = photo.coordinate {
            let results = await locationService.searchNearby(
                around: coordinate,
                radius: MealPhotoDraftPolicy.restaurantLookupRadius
            )
            guard photoRequestID == requestID, !Task.isCancelled else { return }
            photoMapResults = results
        }
        isReadingPhoto = false
    }

    /// Applies a sanitized picker result to either the draft or the saved entry.
    /// Only the attachment owned by this wizard is replaced; other diners' and
    /// the full editor's photos are left intact.
    @discardableResult
    func applyPhoto(_ photo: BackfillPhoto) -> Bool {
        if isSaved {
            guard let visit = savedVisit, visit.isAlive, let personID = savedPersonID,
                  store.canEditDinerEntry(visit, personID: personID) else { return false }
            let newID = store.performBatch {
                if let previous = visit.photoArray.first(where: { $0.id == savedPhotoID }) {
                    store.deletePhoto(previous, personID: personID)
                }
                let id = attachPhoto(photo, to: visit, personID: personID)
                if let date = photo.captureDate {
                    store.updateVisitDate(visit, date: date,
                                          dateTimeZoneOffsetSeconds: photo.captureTimeZoneOffsetSeconds,
                                          editorID: personID)
                }
                return id
            }
            guard let newID, visit.isAlive, visit.photoArray.contains(where: { $0.id == newID }) else {
                photoError = store.lastError ?? "That photo could not be saved. Please try again."
                return false
            }
            savedPhotoID = newID
        } else {
            draftDate = MealPhotoDraftPolicy.visitDate(for: photo, fallback: .now)
            if photo.captureDate != nil { draftDateKnowledge = .known }
        }
        draftPhoto = photo
        photoError = nil
        return true
    }

    private func attachPhoto(_ photo: BackfillPhoto, to visit: VisitEntity, personID: UUID) -> UUID? {
        let existingIDs = Set(visit.photoArray.map(\.id))
        guard store.addPhoto(
            fullData: photo.fullData, thumbnailData: photo.thumbnailData, to: visit, personID: personID,
            createdAt: photo.date, captureDate: photo.captureDate,
            captureTimeZoneOffsetSeconds: photo.captureTimeZoneOffsetSeconds
        ) else { return nil }
        return visit.photoArray.first { !existingIDs.contains($0.id) }?.id
    }

    func clearPhoto() {
        photoRequestID = UUID()
        if let visit = savedVisit, visit.isAlive,
           let photo = visit.photoArray.first(where: { $0.id == savedPhotoID }) {
            store.deletePhoto(photo, personID: savedPersonID)
            guard !visit.photoArray.contains(where: { $0.id == savedPhotoID }) else {
                photoError = store.lastError ?? "That photo could not be removed. Please try again."
                isReadingPhoto = false
                return
            }
        }
        draftPhoto = nil
        savedPhotoID = nil
        photoMapResults = []
        isReadingPhoto = false
        photoError = nil
        if !isSaved {
            draftDate = .now
            draftDateKnowledge = .known
        }
    }

    // MARK: - When and with whom

    var dateLabel: String {
        guard visitDateKnowledge == .known else { return "Date unknown" }
        let offset = visitTimeZoneOffsetSeconds
        let calendar = DiningDateContext.calendar(offsetSeconds: offset)
        if calendar.isDateInToday(visitDate) { return "Today" }
        if calendar.isDateInYesterday(visitDate) { return "Yesterday" }
        return DiningDateContext.format(visitDate, dateStyle: .medium, timeStyle: .none, offsetSeconds: offset)
    }

    func setDate(_ date: Date?) {
        if let date {
            draftDate = date
            draftDateKnowledge = .known
        } else {
            draftDateKnowledge = .unknown
        }
        guard let visit = savedVisit, visit.isAlive, let savedPersonID else { return }
        store.updateVisitDate(visit, date: date, editorID: savedPersonID)
    }

    func setDay(daysAgo: Int) {
        setDate(Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now)
    }

    /// Everyone who could have been at the table: the circle first, then
    /// anyone saved by name.
    var people: [PersonEntity] { store.otherCircleMembers + store.namedCompanions }

    func toggleCompanion(_ id: UUID) {
        guard people.contains(where: { $0.id == id }), canEditOutingDetails else { return }
        var updated = companionIDs
        if updated.contains(id) { updated.remove(id) } else { updated.insert(id) }
        if !isSaved { draftCompanionIDs = updated }
        guard let visit = savedVisit, visit.isAlive, let savedPersonID,
              store.canEditOuting(visit, personID: savedPersonID) else { return }
        store.updateVisit(
            visit, type: visit.visitType, priceBand: Int(visit.priceBand), occasion: visit.occasion,
            memory: visit.memory, companions: Array(updated), editorID: savedPersonID
        )
    }

    // MARK: - Saving

    func beginReaction(_ reaction: Reaction) {
        saveError = nil
        pendingReaction = reaction
    }

    /// Saves the outing with the tapped reaction, or changes the reaction of
    /// the outing that is already saved.
    func commitPendingReaction() -> SaveOutcome {
        guard let reaction = pendingReaction else { return .failed }
        if let visit = savedVisit, visit.isAlive, let personID = savedPersonID {
            _ = store.addRating(to: visit, personID: personID, reaction: reaction, hazy: rating?.hazyMemory ?? false)
            pendingReaction = nil
            return .saved
        }
        guard let choice else {
            pendingReaction = nil
            return .failed
        }
        if let location = existingLocation(for: choice),
           let personID = store.currentPerson?.id,
           let existing = store.existingOuting(at: location, near: visitDate, for: personID),
           existing.rating(for: personID) == nil {
            duplicateOuting = existing
            return .needsDecision
        }
        return saveNewVisit(reaction)
    }

    func resolveDuplicate(joining outing: VisitEntity?) -> SaveOutcome {
        guard let reaction = pendingReaction else { return .failed }
        duplicateOuting = nil
        guard let outing else { return saveNewVisit(reaction) }
        guard outing.isAlive, let personID = store.currentPerson?.id, let location = outing.location else {
            pendingReaction = nil
            return .failed
        }
        let scoreBefore = store.score(for: location, personID: personID)?.score
        store.performBatch {
            _ = store.addRating(to: outing, personID: personID, reaction: reaction)
            if let mealPhoto {
                savedPhotoID = attachPhoto(mealPhoto, to: outing, personID: personID)
            }
        }
        guard outing.isAlive, outing.rating(for: personID) != nil else {
            saveError = store.lastError ?? "Your diner entry could not be saved. Please try again."
            pendingReaction = nil
            return .failed
        }
        // Somebody else's outing cannot be taken back from here, only this
        // person's entry in it, which the outing's own screen handles.
        finishSave(visit: outing, at: location, by: personID, scoreBefore: scoreBefore, undoable: false, createdRestaurant: false)
        return .saved
    }

    func cancelDuplicate() {
        duplicateOuting = nil
        pendingReaction = nil
    }

    private func saveNewVisit(_ reaction: Reaction) -> SaveOutcome {
        guard let choice else {
            pendingReaction = nil
            return .failed
        }
        guard let personID = store.resolveLoggingPersonID() else {
            saveError = AppStore.missingLoggingIdentityMessage
            store.reportError(AppStore.missingLoggingIdentityMessage)
            pendingReaction = nil
            return .failed
        }
        let existing = existingLocation(for: choice)
        let scoreBefore = existing.flatMap { store.score(for: $0, personID: personID) }?.score
        let (location, visit) = store.performBatch { () -> (RestaurantLocation, VisitEntity) in
            let location = resolveLocation(for: choice)
            let visitCoordinate = mealPhoto?.coordinate.map { ($0.latitude, $0.longitude) }
                ?? locationService.currentVisitCoordinate(near: location.coordinate)
            let visit = store.logVisit(
                at: location,
                reaction: reaction,
                personID: personID,
                date: visitDate,
                dateKnowledge: visitDateKnowledge,
                dateTimeZoneOffsetSeconds: mealPhoto?.captureTimeZoneOffsetSeconds,
                companionIDs: Array(companionIDs),
                coordinate: visitCoordinate
            )
            if let mealPhoto {
                savedPhotoID = attachPhoto(mealPhoto, to: visit, personID: personID)
            }
            return (location, visit)
        }
        guard visit.isAlive, location.isAlive else {
            saveError = store.lastError ?? "The outing could not be saved. Please try again."
            pendingReaction = nil
            return .failed
        }
        finishSave(
            visit: visit, at: location, by: personID, scoreBefore: scoreBefore,
            undoable: true, createdRestaurant: existing == nil
        )
        return .saved
    }

    private func finishSave(
        visit: VisitEntity,
        at location: RestaurantLocation,
        by personID: UUID,
        scoreBefore: Double?,
        undoable: Bool,
        createdRestaurant: Bool
    ) {
        savedVisit = visit
        savedPersonID = personID
        baseline = Baseline(locationID: location.id, score: scoreBefore)
        canUndo = undoable
        if createdRestaurant { createdRestaurantIDs.insert(location.id) }
        recordedAnswerIDs = []
        didAnswerClarity = false
        pendingReaction = nil
        startDialIn(for: location)
    }

    /// Takes the save back, along with anything the face-offs recorded, and
    /// returns to the reaction step with the restaurant still chosen.
    func undoSave() {
        guard canUndo else { return }
        draftDate = visitDate
        draftDateKnowledge = visitDateKnowledge
        draftCompanionIDs = companionIDs
        store.performBatch {
            for id in recordedAnswerIDs { store.removeComparison(id: id) }
            if let visit = savedVisit, visit.isAlive {
                let wasCreatedHere = visit.location.map { createdRestaurantIDs.contains($0.id) } ?? false
                store.deleteVisit(visit, personID: savedPersonID, removingRestaurantIfEmpty: wasCreatedHere)
            }
        }
        savedVisit = nil
        savedPersonID = nil
        baseline = nil
        dialInLocationID = nil
        opponent = nil
        recordedAnswerIDs = []
        savedPhotoID = nil
        canUndo = false
        pendingReaction = nil
        isEditingOneAnswer = false
        if case .existing(let location)? = choice?.source, !location.isAlive {
            choice = nil
            go(to: .place)
        } else {
            go(to: .reaction)
        }
    }

    // MARK: - Questions

    private var rating: RatingEntity? {
        guard let visit = savedVisit, visit.isAlive, let savedPersonID else { return nil }
        return visit.rating(for: savedPersonID)
    }

    func title(for step: Step) -> String {
        switch step {
        case .place: "Where?"
        case .reaction: "How was it?"
        case .people: "Who was there?"
        case .clarity: "Remember it well?"
        case .goBack: "Go back?"
        case .value: "Worth it?"
        case .service: "The service?"
        case .vibe: "The vibe?"
        case .kind: "What kind of outing?"
        case .price: "How pricey?"
        case .occasion: "The occasion?"
        case .dishes: "What’d you have?"
        case .ranking: "Ranking"
        }
    }

    func options(for step: Step) -> [WizardOption] {
        switch step {
        case .reaction:
            return Self.scale(Reaction.allCases.map(\.title), Reaction.allCases.map(\.symbol))
        case .clarity:
            return [
                .init(id: "clear", title: "Clearly", symbol: "eye.fill", tone: .good),
                .init(id: "hazy", title: "It’s hazy", symbol: "cloud.fog.fill", tone: .okay)
            ]
        case .goBack:
            return [
                .init(id: "yes", title: "Yes", symbol: "arrow.uturn.backward.circle.fill", tone: .best),
                .init(id: "no", title: "No", symbol: "xmark.circle.fill", tone: .poor)
            ]
        case .value:
            return Self.scale(
                ["A steal", "Fair", "Pricey", "Rip-off"],
                ["gift.fill", "checkmark.seal.fill", "banknote.fill", "xmark.seal.fill"]
            )
        case .service:
            return Self.scale(
                ["Amazing", "Good", "Meh", "Rough"],
                ["sparkles", "hand.thumbsup.fill", "hourglass", "hand.thumbsdown.fill"]
            )
        case .vibe:
            return Self.scale(
                ["Loved it", "Nice", "Fine", "Not my scene"],
                ["party.popper.fill", "sun.max.fill", "cloud.fill", "cloud.rain.fill"]
            )
        case .kind:
            return VisitType.allCases.map { .init(id: $0.rawValue, title: $0.rawValue, symbol: $0.symbol) }
        case .price:
            return (1...4).map { .init(id: String($0), title: Self.priceTitle($0), glyph: String(repeating: "$", count: $0)) }
        case .occasion:
            return Occasion.allCases.map { .init(id: $0.rawValue, title: $0.rawValue, symbol: $0.wizardSymbol) }
        case .place, .people, .dishes, .ranking:
            return []
        }
    }

    /// Four answers on the app's reaction scale, best first. The words change
    /// with the question; what is stored is the same scale the ranking reads.
    private static func scale(_ titles: [String], _ symbols: [String]) -> [WizardOption] {
        let tones: [WizardOption.Tone] = [.best, .good, .okay, .poor]
        return Reaction.allCases.enumerated().map { index, reaction in
            .init(id: reaction.rawValue, title: titles[index], symbol: symbols[index], tone: tones[index])
        }
    }

    private static func priceTitle(_ band: Int) -> String {
        ["Cheap", "Moderate", "Pricey", "Splurge"][band - 1]
    }

    func selection(for step: Step) -> String? {
        _ = store.revision
        if step == .reaction, let pendingReaction { return pendingReaction.rawValue }
        guard let visit = savedVisit, visit.isAlive, let rating else { return nil }
        switch step {
        case .reaction: return rating.reaction.rawValue
        case .clarity: return didAnswerClarity || rating.hazyMemory ? (rating.hazyMemory ? "hazy" : "clear") : nil
        case .goBack: return rating.hasWouldOrderAgain ? (rating.wouldOrderAgain ? "yes" : "no") : nil
        case .value: return rating.value?.rawValue
        case .service: return rating.service?.rawValue
        case .vibe: return rating.atmosphere?.rawValue
        case .kind: return visit.visitType?.rawValue
        case .price: return visit.priceBand > 0 ? String(visit.priceBand) : nil
        case .occasion: return visit.occasion?.rawValue
        case .place, .people, .dishes, .ranking: return nil
        }
    }

    /// Writes one answer to the saved outing. `nil` clears it.
    func answer(_ optionID: String?, for step: Step) {
        guard let visit = savedVisit, visit.isAlive, let personID = savedPersonID, let rating else { return }
        switch step {
        case .kind, .price, .occasion:
            guard store.canEditOuting(visit, personID: personID) else { return }
            store.updateVisit(
                visit,
                type: step == .kind ? optionID.flatMap(VisitType.init(rawValue:)) : visit.visitType,
                priceBand: step == .price ? optionID.flatMap(Int.init) ?? 0 : Int(visit.priceBand),
                occasion: step == .occasion ? optionID.flatMap(Occasion.init(rawValue:)) : visit.occasion,
                memory: visit.memory,
                companions: visit.companionIDs,
                editorID: personID
            )
        case .clarity, .goBack, .value, .service, .vibe:
            let before = store.rankingEngine.visitValue(visit: visit, rating: rating)
            let picked = optionID.flatMap(Reaction.init(rawValue:))
            var wouldGoBack: Bool? = rating.hasWouldOrderAgain ? rating.wouldOrderAgain : nil
            if step == .goBack { wouldGoBack = optionID.map { $0 == "yes" } }
            if step == .clarity { didAnswerClarity = optionID != nil }
            store.updateRating(
                rating,
                service: step == .service ? picked : rating.service,
                atmosphere: step == .vibe ? picked : rating.atmosphere,
                value: step == .value ? picked : rating.value,
                wouldOrderAgain: wouldGoBack,
                hazy: step == .clarity ? optionID == "hazy" : rating.hazyMemory,
                personID: personID
            )
            noteNudge(from: before)
        case .place, .reaction, .people, .dishes, .ranking:
            break
        }
    }

    /// Records which way an answer pushed this outing's value, so the wizard
    /// can show that the answer counted without quoting a number.
    private func noteNudge(from before: Double) {
        guard let visit = savedVisit, visit.isAlive, let rating else { return }
        let change = store.rankingEngine.visitValue(visit: visit, rating: rating) - before
        guard abs(change) > 0.05 else { return }
        nudgeCount += 1
        lastNudge = NudgeEvent(id: nudgeCount, direction: change > 0 ? .up : .down)
    }

    // MARK: - Dishes

    var dishEntries: [DishEntryEntity] {
        _ = store.revision
        guard let visit = savedVisit, visit.isAlive, let savedPersonID else { return [] }
        return visit.dishEntryArray
            .filter { $0.personID == savedPersonID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Dishes already known at this restaurant that are not on this entry yet.
    var dishSuggestions: [DishEntity] {
        guard let location = loggedLocation else { return [] }
        let taken = Set(dishEntries.compactMap { $0.dish?.id })
        return Array(location.dishArray.filter { !$0.isArchived && !taken.contains($0.id) }.prefix(10))
    }

    /// A new dish starts with the outing's own reaction, the likeliest answer,
    /// and is one tap away from a different one.
    func addDish(named name: String) {
        guard let visit = savedVisit, visit.isAlive, let personID = savedPersonID, let rating,
              let location = loggedLocation else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let known = location.dishArray.first { $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }
        let before = store.rankingEngine.visitValue(visit: visit, rating: rating)
        _ = store.addDish(
            name: cleanName,
            role: known?.role ?? defaultDishRole(for: location),
            reaction: rating.reaction,
            wouldOrderAgain: rating.reaction == .loved || rating.reaction == .liked,
            to: visit,
            personID: personID
        )
        noteNudge(from: before)
    }

    func setReaction(_ reaction: Reaction, for entry: DishEntryEntity) {
        guard entry.isAlive, let dish = entry.dish, let visit = savedVisit, visit.isAlive,
              let personID = savedPersonID, let rating else { return }
        let before = store.rankingEngine.visitValue(visit: visit, rating: rating)
        _ = store.addDish(
            name: dish.name,
            role: dish.role,
            reaction: reaction,
            wouldOrderAgain: reaction == .loved || reaction == .liked,
            to: visit,
            personID: personID
        )
        noteNudge(from: before)
    }

    func removeDish(_ entry: DishEntryEntity) {
        guard entry.isAlive else { return }
        store.deleteDishEntry(entry, personID: savedPersonID)
    }

    private func defaultDishRole(for location: RestaurantLocation) -> DishRole {
        switch location.category {
        case .coffeeTea, .barsBreweries: .drink
        case .dessert, .bakeries: .dessert
        case .fullService, .counterService, .trucksStands: .entree
        }
    }

    // MARK: - Recap

    /// The answers given so far, in the order they were asked.
    var recap: [WizardRecapItem] {
        steps.compactMap { step -> WizardRecapItem? in
            switch step {
            case .place, .ranking:
                return nil
            case .people:
                let names = people.filter { companionIDs.contains($0.id) }.map(\.name)
                return .init(step: step, title: names.isEmpty ? "Just me" : names.joined(separator: ", "), symbol: "person.2.fill")
            case .dishes:
                let count = dishEntries.count
                guard count > 0 else { return nil }
                return .init(step: step, title: count == 1 ? "1 dish" : "\(count) dishes", symbol: "fork.knife")
            case .goBack:
                guard let id = selection(for: step) else { return nil }
                return .init(
                    step: step,
                    title: id == "yes" ? "Would go back" : "Wouldn’t go back",
                    symbol: id == "yes" ? "arrow.uturn.backward" : "xmark"
                )
            default:
                guard let id = selection(for: step),
                      let option = options(for: step).first(where: { $0.id == id }) else { return nil }
                let prefix: String? = switch step {
                case .value: "Value"
                case .service: "Service"
                case .vibe: "Vibe"
                default: nil
                }
                let title = option.glyph ?? option.title
                return .init(step: step, title: prefix.map { "\($0) · \(title)" } ?? title, symbol: option.symbol)
            }
        }
    }

    /// The first question nobody has answered yet, if any.
    var firstUnansweredStep: Step? {
        steps.first { step in
            switch step {
            case .place, .reaction, .people, .ranking: false
            case .dishes: dishEntries.isEmpty
            default: selection(for: step) == nil
            }
        }
    }

    // MARK: - Ranking

    /// The restaurant the saved outing belongs to now, which is not
    /// necessarily the one it was logged at: an outing can be moved.
    var loggedLocation: RestaurantLocation? {
        _ = store.revision
        guard let visit = savedVisit, visit.isAlive,
              let location = visit.location, location.isAlive else { return nil }
        return location
    }

    var score: LocationScore? {
        guard let location = loggedLocation, let savedPersonID else { return nil }
        return store.score(for: location, personID: savedPersonID)
    }

    var reaction: Reaction? { rating?.reaction }

    /// The score from before this outing, when the restaurant had one and the
    /// outing is still at that restaurant.
    var scoreBefore: Double? {
        guard let baseline, baseline.locationID == loggedLocation?.id else { return nil }
        return baseline.score
    }

    /// Face-offs still needed before this restaurant's score means something.
    var faceOffsToEarnScore: Int {
        guard let score, !score.hasEarnedScore else { return 0 }
        return max(0, LocationScore.comparisonsToEarnScore - score.comparisonCount)
    }

    var ladder: [LadderRow] {
        guard let score else { return [] }
        let peers = store.ranked(for: savedPersonID).filter { $0.location.category == score.location.category }
        guard let index = peers.firstIndex(where: { $0.id == score.id }) else { return [] }
        let lower = max(0, min(index - 1, peers.count - 3))
        let upper = min(peers.count, lower + 3)
        return peers[lower..<upper].map {
            LadderRow(id: $0.id, rank: $0.categoryRank, name: $0.location.name, isFocus: $0.id == score.id)
        }
    }

    /// The challenger to show, or `nil` once the face-offs are over.
    var activeOpponent: RestaurantLocation? {
        guard let opponent, let location = loggedLocation, isValidOpponent(opponent, for: location) else { return nil }
        return opponent
    }

    var hasMoreToSettle: Bool { !store.settleScorePrompts(limit: 1).isEmpty }

    private func startDialIn(for location: RestaurantLocation) {
        dialInLocationID = location.id
        askedIDs = []
        round = 0
        opponent = store.dialInOpponent(for: location, personID: savedPersonID)
    }

    /// Answers given on the way here move the restaurant, so the first
    /// challenger is chosen on arrival rather than at the moment of saving.
    private func prepareRanking() {
        reconcileRanking()
        guard let location = loggedLocation else { return }
        if round == 0 {
            opponent = store.dialInOpponent(for: location, personID: savedPersonID)
        }
    }

    /// A challenger is only worth asking about while it is still a ranked
    /// restaurant in the same list as the one being placed.
    private func isValidOpponent(_ candidate: RestaurantLocation, for location: RestaurantLocation) -> Bool {
        candidate.isAlive && candidate.id != location.id && candidate.category == location.category
            && store.score(for: candidate, personID: savedPersonID) != nil
    }

    /// Keeps the face-offs honest when the ground moves under them: an outing
    /// moved to another restaurant starts over against that restaurant's
    /// neighbours, and a challenger that was removed, closed or recategorised
    /// is swapped for one that can still be compared.
    func reconcileRanking() {
        guard let location = loggedLocation else { return }
        if dialInLocationID != location.id {
            let previousID = dialInLocationID
            let invalidAnswers = recordedAnswerIDs
            recordedAnswerIDs = []
            // Both the full editor and the wizard can correct the restaurant.
            // Only this wizard's answers and restaurants are eligible for cleanup.
            dialInLocationID = location.id
            store.performBatch {
                for id in invalidAnswers { store.removeComparison(id: id) }
                if let previousID, createdRestaurantIDs.contains(previousID),
                   store.deleteRestaurant(id: previousID) {
                    createdRestaurantIDs.remove(previousID)
                }
            }
            baseline = nil
            choice = location.placeChoice
            startDialIn(for: location)
        } else if step == .ranking, let opponent, !isValidOpponent(opponent, for: location) {
            self.opponent = store.dialInOpponent(for: location, excluding: askedIDs, personID: savedPersonID)
        }
    }

    func settle(_ outcome: ComparisonOutcome) {
        guard let location = loggedLocation, let savedPersonID, let current = activeOpponent else {
            reconcileRanking()
            return
        }
        if let id = store.recordComparison(a: location, b: current, outcome: outcome, personID: savedPersonID) {
            recordedAnswerIDs.append(id)
        }
        let verdict: DialInVerdict = switch outcome {
        case .a: .preferred
        case .b: .passedOver
        case .tie, .skipped: .tooClose
        }
        moveOn(from: current, after: verdict)
    }

    func skipOpponent() {
        guard let current = opponent else { return }
        moveOn(from: current, after: nil)
    }

    private func moveOn(from current: RestaurantLocation, after verdict: DialInVerdict?) {
        askedIDs.insert(current.id)
        round += 1
        if round < Self.dialInRounds, let location = loggedLocation {
            opponent = store.dialInOpponent(for: location, excluding: askedIDs, after: verdict, personID: savedPersonID)
        } else {
            opponent = nil
        }
    }

    /// Opening the full editor ends the one-tap undo: it can hold typing and
    /// photos that an undo would silently throw away.
    func willOpenEditor() {
        canUndo = false
    }
}

private extension Occasion {
    var wizardSymbol: String {
        switch self {
        case .everyday: "sun.max.fill"
        case .dateNight: "heart.fill"
        case .birthday: "birthday.cake.fill"
        case .celebration: "party.popper.fill"
        case .work: "briefcase.fill"
        case .travel: "airplane"
        }
    }
}

private extension PlaceCandidate {
    var clLocation: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    /// The street part of the address, which is all a tile has room for.
    var shortAddress: String {
        address?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
            ?? suggestedCategory.shortTitle
    }
}
