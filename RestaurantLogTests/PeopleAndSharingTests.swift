import CoreData
import ImageIO
import UIKit
import XCTest
@testable import RestaurantLog

@MainActor
final class PeopleAndSharingTests: XCTestCase {
    private var store: AppStore!
    override func setUp() async throws {
        for key in ["activeCircleID", "devicePersonID", "devicePersonIDsByCircle"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        store = AppStore(persistence: PersistenceController(inMemory: true))
        store.bootstrap(myName: "Davis")
    }

    private func branches() -> (RestaurantLocation, RestaurantLocation) {
        let waco = store.createLocation(name: "Chili's", address: "1800 S Valley Mills Dr", city: "Waco, TX")
        let glenwood = store.createLocation(name: "Chili's", address: "400 W Meadows Dr", city: "Glenwood Springs, CO")
        return (waco, glenwood)
    }

    func testDifferentPlacesDecisionSurvivesReloadAndCanBeUndone() throws {
        let (first, second) = branches()
        XCTAssertEqual(store.duplicateLocationSuggestions().count, 1)
        XCTAssertTrue(store.markAsDifferentPlaces(second, first))
        store.reload()
        XCTAssertTrue(store.duplicateLocationSuggestions().isEmpty)
        XCTAssertEqual(store.locations.count, 2)
        XCTAssertEqual(store.dismissedDuplicateSuggestions.count, 1)
        store.reconsiderDuplicate(first, second)
        XCTAssertEqual(store.duplicateLocationSuggestions().count, 1)
        XCTAssertTrue(store.dismissedDuplicateSuggestions.isEmpty)
    }

    func testDifferentPlacesSurviveBackupAndSync() async throws {
        let (first, second) = branches()
        store.markAsDifferentPlaces(first, second)
        let archive = try AppBackupCodec.decode(AppBackupCodec.encode(await AppBackupService.makeArchive(from: store)))
        let restored = AppStore(persistence: PersistenceController(inMemory: true))
        _ = try await AppBackupService.restore(archive, into: restored)
        XCTAssertTrue(restored.duplicateLocationSuggestions().isEmpty)
        XCTAssertEqual(restored.dismissedDuplicateSuggestions.count, 1)

        let circleID = try XCTUnwrap(store.activeCircleID)
        let snapshot = try SyncSnapshotBuilder.build(circleID: circleID, in: store.context)
        let receiving = PersistenceController(inMemory: true)
        let remote = snapshot.records.mapValues { record in
            DecodedSyncRecord(key: record.key, payload: record.payload, fingerprint: record.fingerprint,
                              deleted: false, updatedMS: 1, deviceID: nil)
        }
        let plan = SyncPlanner.plan(local: [:], remote: remote, baseline: [:])
        try SyncApplier.apply(records: remote, applying: plan.apply, deleting: [], circleID: circleID, in: receiving.container.viewContext)
        try receiving.save()
        let synced = AppStore(persistence: receiving)
        XCTAssertTrue(synced.duplicateLocationSuggestions().isEmpty)
        XCTAssertEqual(synced.dismissedDuplicateSuggestions.count, 1)
        let rebuilt = try SyncSnapshotBuilder.build(circleID: circleID, in: synced.context)
        XCTAssertEqual(snapshot.records.mapValues(\.fingerprint), rebuilt.records.mapValues(\.fingerprint))
    }

    func testDifferentPlacesDecisionPreventsAutomaticMergeAndTransfersWithManualMerge() throws {
        let (first, second) = branches()
        store.markAsDifferentPlaces(first, second)
        first.sourceIdentifier = "same-legacy-source"
        second.sourceIdentifier = first.sourceIdentifier
        try store.persistence.save()
        store.reload()
        XCTAssertEqual(store.locations.count, 2)
        let third = store.createLocation(name: "Another saved Chili's", address: "Different label")
        store.merge(first, into: third)
        XCTAssertTrue(store.areKnownDifferentPlaces(third, second))
        XCTAssertEqual(store.dismissedDuplicateSuggestions.count, 1)
        store.reconsiderDuplicate(third, second)
        XCTAssertFalse(store.areKnownDifferentPlaces(third, second))
    }

    func testExistingSQLiteStoreMigratesDuplicateDecisionsWithoutLosingRestaurants() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Legacy.sqlite")
        let legacyModel = try XCTUnwrap(ManagedObjectModel.make().copy() as? NSManagedObjectModel)
        legacyModel.entitiesByName["RestaurantLocation"]?.properties.removeAll { $0.name == "distinctLocationIDsBlob" }
        let legacy = NSPersistentContainer(name: "Legacy", managedObjectModel: legacyModel)
        let description = NSPersistentStoreDescription(url: url)
        description.shouldAddStoreAsynchronously = false
        legacy.persistentStoreDescriptions = [description]
        var loadError: Error?
        legacy.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let location = NSEntityDescription.insertNewObject(forEntityName: "RestaurantLocation", into: legacy.viewContext)
        let id = UUID()
        location.setValue(id, forKey: "id")
        location.setValue("Chili's", forKey: "name")
        location.setValue(DiningCategory.fullService.rawValue, forKey: "categoryRaw")
        location.setValue(Date.now, forKey: "createdAt")
        location.setValue(Date.now, forKey: "updatedAt")
        try legacy.viewContext.save()
        legacy.viewContext.reset()
        try legacy.persistentStoreCoordinator.remove(XCTUnwrap(legacy.persistentStoreCoordinator.persistentStores.first))
        let current = NSPersistentContainer(name: "Current", managedObjectModel: ManagedObjectModel.make())
        let destination = NSPersistentStoreDescription(url: url)
        destination.shouldAddStoreAsynchronously = false
        destination.shouldMigrateStoreAutomatically = true
        destination.shouldInferMappingModelAutomatically = true
        current.persistentStoreDescriptions = [destination]
        current.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let restored = try XCTUnwrap(current.viewContext.fetch(NSFetchRequest<RestaurantLocation>(entityName: "RestaurantLocation")).first)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.name, "Chili's")
        XCTAssertTrue(restored.distinctLocationIDs.isEmpty)
        restored.distinctLocationIDs = [UUID()]
        try current.viewContext.save()
        current.viewContext.reset()
        XCTAssertEqual(try current.viewContext.fetch(NSFetchRequest<RestaurantLocation>(entityName: "RestaurantLocation")).first?.distinctLocationIDs.count, 1)
        current.viewContext.reset()
        try current.persistentStoreCoordinator.remove(XCTUnwrap(current.persistentStoreCoordinator.persistentStores.first))
    }

    func testLegacyLocationPayloadWithoutDecisionsStillDecodes() async throws {
        _ = branches()
        let archive = try await AppBackupService.makeArchive(from: store)
        let record = try XCTUnwrap(archive.locations.first)
        let data = try SyncPayloadCodec.encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "distinctLocationIDs")
        let decoded = try SyncPayloadCodec.decode(AppBackupArchive.LocationRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.distinctLocationIDs)
    }

    func testPeopleStepSavesAttendanceAndRemovalWithoutChangingOthersReactions() throws {
        let member = try XCTUnwrap(store.addCircleMember(name: "Kelsey"))
        let guest = try XCTUnwrap(store.addNamedCompanion(name: "Sam"))
        let wizard = OutingWizardModel(store: store, locationService: LocationService())
        wizard.start()
        wizard.query = "Dinner"
        wizard.select(wizard.manualChoice)
        wizard.beginReaction(.loved)
        XCTAssertEqual(wizard.commitPendingReaction(), .saved)
        wizard.advance()
        XCTAssertEqual(wizard.step, .people)
        wizard.toggleCompanion(member.id)
        wizard.toggleCompanion(guest.id)
        let visit = try XCTUnwrap(wizard.savedVisit)
        XCTAssertEqual(Set(visit.companionIDs), Set([member.id, guest.id]))
        XCTAssertEqual(visit.ratingArray.count, 1)
        XCTAssertTrue(store.pendingVisits(for: member.id).contains { $0.id == visit.id })
        wizard.toggleCompanion(guest.id)
        XCTAssertEqual(visit.companionIDs, [member.id])
        XCTAssertTrue(wizard.recap.contains { $0.step == .people && $0.title == "Kelsey" })

        let next = OutingWizardModel(store: store, locationService: LocationService())
        next.start()
        XCTAssertTrue(next.companionIDs.isEmpty, "A new outing must not silently assume the last outing's attendance")
    }

    func testRemovingMembersAndGuestsPreservesHistoryAndHidesThemFromFutureOutings() throws {
        let member = try XCTUnwrap(store.addCircleMember(name: "Kelsey"))
        let guest = try XCTUnwrap(store.addNamedCompanion(name: "Sam"))
        let visit = store.logVisit(at: store.createLocation(name: "Dinner"), reaction: .loved, companionIDs: [member.id, guest.id])
        _ = store.addRating(to: visit, personID: member.id, reaction: .liked)
        let ratings = visit.ratingArray.map(\.id)
        XCTAssertTrue(store.removeCircleMember(member.id))
        XCTAssertTrue(store.deleteNamedCompanion(guest.id))
        store.reload()
        XCTAssertEqual(Set(visit.ratingArray.map(\.id)), Set(ratings))
        XCTAssertEqual(Set(store.taggedPeople(for: visit).map(\.name)), Set(["Kelsey", "Sam"]))
        XCTAssertTrue(store.namedCompanions.isEmpty)
        XCTAssertEqual(store.circleMembers.count, 1)
        let wizard = OutingWizardModel(store: store, locationService: LocationService())
        XCTAssertTrue(wizard.people.isEmpty)
        XCTAssertFalse(store.removeCircleMember(try XCTUnwrap(store.currentPerson?.id)))
    }

    func testRankingPNGStylesProduceReadableOpaque1080PixelImages() throws {
        let names = ["Propaganda Pie", "White House Pizza", "Mi Mexico Family Mexican Restaurant – Glenwood", "Notchtop BREAKFAST & LUNCH", "Sugar Spice (Vietnamese food and Boba Tea)"]
        let items = names.enumerated().map { index, name in
            RankingShareItem(id: UUID(), name: name, city: index == 2 ? "Glenwood Springs, CO" : "Waco, TX", category: .fullService, score: 98 - index)
        }
        for style in RankingCardStyle.allCases {
            var options = RankingCardOptions()
            options.style = style
            let export = try RankingPNGRenderer.export(items: items, attribution: "Davis’s favorites", options: options)
            let data = try Data(contentsOf: export.url)
            XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            let image = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(image.size.width, 1080)
            XCTAssertGreaterThanOrEqual(image.size.height, 1350)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Ranking Card - \(style.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        var privateOptions = RankingCardOptions()
        privateOptions.showsScores = false
        privateOptions.showsCities = false
        privateOptions.title = "My very long customized ranking title with plenty to say"
        privateOptions.caption = String(repeating: "A long caption. ", count: 10)
        let manyItems = (0..<20).map { index in
            RankingShareItem(id: UUID(), name: names[index % names.count], city: "Glenwood Springs, CO", category: .fullService, score: 98 - index)
        }
        let image = try XCTUnwrap(RankingPNGRenderer.image(items: manyItems, attribution: "Davis", options: privateOptions))
        XCTAssertLessThan(image.size.height * image.scale, 8_000)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Ranking Card - Long list"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(RankingShareCard.rank(at: 0, in: items), 1)
        let tied = [items[0], RankingShareItem(id: UUID(), name: "Tie", city: nil, category: .fullService, score: items[0].score), items[2]]
        XCTAssertEqual(RankingShareCard.rank(at: 1, in: tied), 1)
        XCTAssertEqual(RankingShareCard.rank(at: 2, in: tied), 3)
    }
}
