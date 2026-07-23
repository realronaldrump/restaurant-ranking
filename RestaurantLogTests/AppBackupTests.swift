import XCTest
@testable import RestaurantLog

@MainActor
final class AppBackupTests: XCTestCase {
    override func setUp() async throws {
        for key in ["activeCircleID", "devicePersonID", "devicePersonIDsByCircle", "hapticsEnabled"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testFullBackupRoundTripsEveryRecordTypeAndReplacesPlaceholder() async throws {
        let source = makeStore()
        source.bootstrap(myName: "George", circleName: "Dinner Club")
        let me = try XCTUnwrap(source.currentPerson)
        let michelle = try XCTUnwrap(source.addCircleMember(name: "Michelle"))
        let friend = try XCTUnwrap(source.addNamedCompanion(name: "Sam"))

        let first = source.createLocation(
            name: "Complete Cafe", category: .coffeeTea, address: "1 Main St", city: "Salt Lake City",
            coordinate: (40.7601, -111.8910), phone: "801-555-0100",
            url: URL(string: "https://example.com"), sourceIdentifier: "maps-123",
            cuisines: ["Coffee", "Pastry"], tags: ["Patio"]
        )
        source.updateLocationDetails(
            first, name: first.name, category: .coffeeTea, cuisines: first.cuisines, tags: first.tags,
            address: first.address, city: first.city, phone: first.phone, urlString: first.urlString,
            hoursText: "Mon–Fri 7–3", latitude: first.latitude, longitude: first.longitude, isClosed: true
        )
        let second = source.createLocation(name: "Second Supper", category: .fullService)
        let visit = source.logVisit(
            at: first, reaction: .loved, personID: me.id,
            date: Date(timeIntervalSince1970: 1_720_000_000), hazy: true,
            companionIDs: [michelle.id, friend.id],
            coordinate: (40.7602, -111.8911)
        )
        source.updateVisit(
            visit, type: .coffee, priceBand: 2, occasion: .dateNight,
            memory: "A complete memory", companions: [michelle.id, friend.id]
        )
        let myRating = try XCTUnwrap(visit.rating(for: me.id))
        source.updateRating(
            myRating, reaction: .loved, service: .liked, atmosphere: .fine,
            value: .notForMe, wouldOrderAgain: false, hazy: true
        )
        _ = source.addRating(to: visit, personID: michelle.id, reaction: .liked)
        _ = source.addDish(
            name: "Cardamom Bun", role: .dessert, reaction: .loved,
            wouldOrderAgain: true, to: visit, personID: me.id
        )
        source.addPhoto(
            fullData: Data([1, 2, 3, 4]), thumbnailData: Data([5, 6]), to: visit,
            createdAt: Date(timeIntervalSince1970: 1_720_000_100),
            captureDate: Date(timeIntervalSince1970: 1_719_999_900)
        )
        source.recordComparison(a: first, b: second, outcome: .a, personID: me.id)
        source.recordAnchor(for: first, value: 92, personID: michelle.id)
        source.toggleWant(second, by: michelle.id)

        let brand = BrandEntity(context: source.context)
        brand.id = UUID(); brand.name = "Complete Group"; brand.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        first.brand = brand
        try source.persistence.save()
        UserDefaults.standard.set(false, forKey: "hapticsEnabled")

        let original = try await AppBackupService.makeArchive(from: source)
        let originalComparison = try XCTUnwrap(original.comparisons.first { !$0.isAnchor })
        XCTAssertFalse(try XCTUnwrap(originalComparison.locationAEvidenceFingerprint).isEmpty)
        XCTAssertFalse(try XCTUnwrap(originalComparison.locationBEvidenceFingerprint).isEmpty)
        let encoded = try AppBackupCodec.encode(original)
        let decoded = try AppBackupCodec.decode(encoded)

        let destination = makeStore()
        destination.bootstrap(myName: "Temporary", circleName: "Placeholder")
        let junk = destination.createLocation(name: "Should Disappear")
        _ = destination.logVisit(at: junk, reaction: .fine)

        let summary = try await AppBackupService.restore(decoded, into: destination)

        XCTAssertEqual(summary, .init(circles: 1, locations: 2, visits: 1, photos: 1))
        XCTAssertEqual(destination.circles.map(\.name), ["Dinner Club"])
        XCTAssertEqual(destination.currentPerson?.id, me.id)
        XCTAssertEqual(destination.locations.count, 2)
        XCTAssertFalse(destination.locations.contains { $0.name == "Should Disappear" })
        let restoredLocation = try XCTUnwrap(destination.locations.first { $0.id == first.id })
        XCTAssertEqual(restoredLocation.category, .coffeeTea)
        XCTAssertEqual(restoredLocation.address, "1 Main St")
        XCTAssertEqual(restoredLocation.hoursText, "Mon–Fri 7–3")
        XCTAssertEqual(restoredLocation.brand?.name, "Complete Group")
        XCTAssertEqual(restoredLocation.cuisines, ["Coffee", "Pastry"])
        XCTAssertEqual(restoredLocation.tags, ["Patio"])
        XCTAssertTrue(restoredLocation.isClosed)

        let restoredVisit = try XCTUnwrap(destination.visits.first)
        XCTAssertEqual(restoredVisit.id, visit.id)
        XCTAssertEqual(restoredVisit.visitType, .coffee)
        XCTAssertEqual(restoredVisit.occasion, .dateNight)
        XCTAssertEqual(restoredVisit.memory, "A complete memory")
        XCTAssertEqual(Set(restoredVisit.companionIDs), Set([michelle.id, friend.id]))
        XCTAssertEqual(restoredVisit.ratingArray.count, 2)
        let restoredRating = try XCTUnwrap(restoredVisit.rating(for: me.id))
        XCTAssertEqual(restoredRating.service, .liked)
        XCTAssertEqual(restoredRating.atmosphere, .fine)
        XCTAssertEqual(restoredRating.value, .notForMe)
        XCTAssertTrue(restoredRating.hasWouldOrderAgain)
        XCTAssertFalse(restoredRating.wouldOrderAgain)
        XCTAssertEqual(restoredVisit.dishEntryArray.first?.dish?.name, "Cardamom Bun")
        XCTAssertEqual(restoredVisit.photoArray.first?.fullData, Data([1, 2, 3, 4]))
        XCTAssertEqual(restoredVisit.photoArray.first?.thumbnailData, Data([5, 6]))
        XCTAssertEqual(restoredVisit.photoArray.first?.captureDate, Date(timeIntervalSince1970: 1_719_999_900))
        XCTAssertEqual(destination.comparisons.count, 2)
        let restoredComparison = try XCTUnwrap(destination.comparisons.first { !$0.isAnchor })
        XCTAssertEqual(restoredComparison.locationAEvidenceFingerprint, originalComparison.locationAEvidenceFingerprint)
        XCTAssertEqual(restoredComparison.locationBEvidenceFingerprint, originalComparison.locationBEvidenceFingerprint)
        XCTAssertTrue(destination.isWanted(try XCTUnwrap(destination.locations.first { $0.id == second.id })))
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "hapticsEnabled"), false)
    }

    func testBackupWithoutComparisonEvidenceFingerprintsRemainsRestorable() async throws {
        let source = makeStore()
        source.bootstrap(myName: "George")
        let first = source.createLocation(name: "Legacy First", category: .fullService)
        let second = source.createLocation(name: "Legacy Second", category: .fullService)
        _ = source.logVisit(at: first, reaction: .loved)
        _ = source.logVisit(at: second, reaction: .liked)
        source.recordComparison(a: first, b: second, outcome: .a)

        let archive = try await AppBackupService.makeArchive(from: source)
        let data = try AppBackupCodec.encode(archive)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var comparisons = try XCTUnwrap(payload["comparisons"] as? [[String: Any]])
        for index in comparisons.indices {
            comparisons[index].removeValue(forKey: "locationAEvidenceFingerprint")
            comparisons[index].removeValue(forKey: "locationBEvidenceFingerprint")
        }
        payload["comparisons"] = comparisons
        let legacyData = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try AppBackupCodec.decode(legacyData)
        XCTAssertNil(decoded.comparisons.first?.locationAEvidenceFingerprint)
        XCTAssertNil(decoded.comparisons.first?.locationBEvidenceFingerprint)

        let destination = makeStore()
        _ = try await AppBackupService.restore(decoded, into: destination)

        let restored = try XCTUnwrap(destination.comparisons.first { !$0.isAnchor })
        XCTAssertFalse(restored.locationAEvidenceFingerprint.isEmpty)
        XCTAssertFalse(restored.locationBEvidenceFingerprint.isEmpty)
        let pairIDs = Set([first.id, second.id])
        XCTAssertFalse(destination.settleQuestions().contains { Set([$0.a.id, $0.b.id]) == pairIDs })
    }

    func testInvalidBackupIsRejectedBeforeExistingDataChanges() async throws {
        let source = makeStore()
        source.bootstrap(myName: "Source")
        var archive = try await AppBackupService.makeArchive(from: source)
        archive.circles.append(try XCTUnwrap(archive.circles.first))

        let destination = makeStore()
        destination.bootstrap(myName: "Keep Me", circleName: "Current")
        let currentCircleID = try XCTUnwrap(destination.activeCircle?.id)

        do {
            _ = try await AppBackupService.restore(archive, into: destination)
            XCTFail("Expected duplicate identifiers to be rejected")
        } catch {
            XCTAssertEqual(error as? AppBackupError, .duplicateIdentifier("circle"))
        }
        XCTAssertEqual(destination.activeCircle?.id, currentCircleID)
        XCTAssertEqual(destination.currentPerson?.name, "Keep Me")
    }

    func testNewerBackupVersionGivesActionableError() async throws {
        let store = makeStore()
        store.bootstrap(myName: "Source")
        let location = store.createLocation(name: "Future Cafe")
        _ = store.logVisit(at: location, reaction: .liked)
        var archive = try await AppBackupService.makeArchive(from: store)
        archive.formatVersion = AppBackupArchive.currentFormatVersion + 1
        let data = try AppBackupCodec.encode(archive)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var visits = try XCTUnwrap(payload["visits"] as? [[String: Any]])
        visits[0]["visitType"] = "A Future Visit Type"
        payload["visits"] = visits
        let futureData = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try AppBackupCodec.decode(futureData)) { error in
            XCTAssertEqual(error as? AppBackupError, .unsupportedVersion(2))
        }
    }

    func testPhotoDatesOnlyMoveVisitsEarlierUsingVerifiedCaptureMetadata() throws {
        let store = makeStore()
        store.bootstrap(myName: "Source")
        let location = store.createLocation(name: "Clock Cafe")
        let originalDate = Date(timeIntervalSince1970: 2_000)
        let visit = store.logVisit(at: location, reaction: .liked, date: originalDate)

        store.addPhoto(
            fullData: Data([1]), thumbnailData: nil, to: visit,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(store.photoDateSyncCandidateCount, 0)
        XCTAssertEqual(store.syncVisitDatesWithStoredPhotoTimes(), 0)
        XCTAssertEqual(visit.date, originalDate)

        let verifiedCaptureDate = Date(timeIntervalSince1970: 1_500)
        store.addPhoto(
            fullData: Data([2]), thumbnailData: nil, to: visit,
            createdAt: Date(timeIntervalSince1970: 2_100), captureDate: verifiedCaptureDate
        )
        XCTAssertEqual(store.photoDateSyncCandidateCount, 1)
        XCTAssertEqual(store.syncVisitDatesWithStoredPhotoTimes(), 1)
        XCTAssertEqual(visit.date, verifiedCaptureDate)

        let laterPhoto = BackfillPhoto(
            id: UUID(), fullData: Data([3]), thumbnailData: nil,
            date: Date(timeIntervalSince1970: 1_800), coordinate: nil,
            captureDate: Date(timeIntervalSince1970: 1_800)
        )
        store.updateVisitDateFromPhotoMetadata(visit, photos: [laterPhoto])
        XCTAssertEqual(visit.date, verifiedCaptureDate)
    }

    func testValidationRejectsMissingAndCrossCircleReferences() async throws {
        let store = makeStore()
        store.bootstrap(myName: "Source")
        let location = store.createLocation(name: "Reference Cafe")
        _ = store.logVisit(at: location, reaction: .liked)
        let archive = try await AppBackupService.makeArchive(from: store)

        var missingLocation = archive
        missingLocation.visits[0].locationID = nil
        XCTAssertThrowsError(try AppBackupCodec.validate(missingLocation)) { error in
            XCTAssertEqual(error as? AppBackupError, .missingReference("visit’s restaurant is missing"))
        }

        var crossCircle = archive
        let secondCircleID = UUID()
        crossCircle.circles.append(.init(id: secondCircleID, name: "Other", createdAt: .now))
        crossCircle.locations[0].circleID = secondCircleID
        XCTAssertThrowsError(try AppBackupCodec.validate(crossCircle)) { error in
            XCTAssertEqual(error as? AppBackupError, .missingReference("visit and restaurant belong to different circles"))
        }
    }

    func testLegacyBackupWithoutPhotoCaptureDateStillDecodes() async throws {
        let store = makeStore()
        store.bootstrap(myName: "Source")
        let location = store.createLocation(name: "Legacy Cafe")
        let visit = store.logVisit(at: location, reaction: .liked)
        store.addPhoto(fullData: Data([1]), thumbnailData: nil, to: visit, createdAt: .now)
        let archive = try await AppBackupService.makeArchive(from: store)
        let data = try AppBackupCodec.encode(archive)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var photos = try XCTUnwrap(payload["photos"] as? [[String: Any]])
        photos[0].removeValue(forKey: "captureDate")
        payload["photos"] = photos

        let decoded = try AppBackupCodec.decode(JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(decoded.photos.first?.captureDate)
    }

    func testReloadSelectsFirstCircleWhenStoredActiveCircleIsMissing() throws {
        let persistence = PersistenceController(inMemory: true, cloudEnabled: false)
        let original = AppStore(persistence: persistence)
        original.bootstrap(myName: "Source", circleName: "Recovered")
        let expectedCircleID = try XCTUnwrap(original.activeCircleID)
        UserDefaults.standard.removeObject(forKey: "activeCircleID")

        let reloaded = AppStore(persistence: persistence)

        XCTAssertEqual(reloaded.activeCircleID, expectedCircleID)
    }

    private func makeStore() -> AppStore {
        AppStore(persistence: PersistenceController(inMemory: true, cloudEnabled: false))
    }
}
