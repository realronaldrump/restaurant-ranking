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
            date: Date(timeIntervalSince1970: 1_720_000_000), dateKnowledge: .unknown,
            hazy: true,
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
        XCTAssertTrue(source.setCoonReaction(.runItBack, to: michelle.id, in: visit))
        source.updateMemory("Michelle's own memory", for: visit, personID: michelle.id)
        _ = source.addDish(
            name: "Cardamom Bun", role: .dessert, reaction: .loved,
            wouldOrderAgain: true, to: visit, personID: me.id
        )
        source.addPhoto(
            fullData: Data([1, 2, 3, 4]), thumbnailData: Data([5, 6]), to: visit,
            createdAt: Date(timeIntervalSince1970: 1_720_000_100),
            captureDate: Date(timeIntervalSince1970: 1_719_999_900), caption: "Cardamom and sunshine"
        )
        source.recordComparison(a: first, b: second, outcome: .a, personID: me.id)
        source.recordAnchor(for: first, value: 92, personID: michelle.id)
        source.toggleWant(second, by: michelle.id)

        let brand = BrandEntity(context: source.context)
        brand.id = UUID(); brand.name = "Complete Group"; brand.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        first.brand = brand
        let importLink = ExternalImportLinkEntity(context: source.context)
        let importSession = ExternalImportSessionEntity(context: source.context)
        importSession.id = UUID(); importSession.provider = "beli"; importSession.sourceNamespace = "private-hash"
        importSession.importedAt = Date(timeIntervalSince1970: 1_720_000_200); importSession.exportDate = Date(timeIntervalSince1970: 1_720_000_000)
        importSession.restaurantsCreated = 1; importSession.outingsCreated = 1; importSession.photosAdded = 1
        importSession.dishesAdded = 1; importSession.rankingsSeeded = 1
        importSession.circle = try XCTUnwrap(source.activeCircle)
        importLink.id = UUID(); importLink.provider = "beli"; importLink.recordType = "restaurant"
        importLink.externalKey = "private-hash:restaurant-1"; importLink.contentHash = "content-hash"
        importLink.createdByImport = true
        importLink.targetID = first.id; importLink.createdAt = .now; importLink.updatedAt = .now
        importLink.circle = try XCTUnwrap(source.activeCircle)
        importLink.session = importSession
        try source.persistence.save()
        UserDefaults.standard.set(false, forKey: "hapticsEnabled")

        let original = try await AppBackupService.makeArchive(from: source)
        XCTAssertEqual(try XCTUnwrap(original.participants).count, 3)
        XCTAssertEqual(try XCTUnwrap(original.dinerEntryReactions).map(\.kind), [.runItBack])
        let originalComparison = try XCTUnwrap(original.comparisons.first { !$0.isAnchor })
        XCTAssertFalse(try XCTUnwrap(originalComparison.locationAEvidenceFingerprint).isEmpty)
        XCTAssertFalse(try XCTUnwrap(originalComparison.locationBEvidenceFingerprint).isEmpty)
        let encoded = try AppBackupCodec.encode(original)
        let decoded = try AppBackupCodec.decode(encoded)

        let destination = makeStore()
        destination.bootstrap(myName: "Temporary", circleName: "Placeholder")
        let placeholderCircleID = try XCTUnwrap(destination.activeCircleID)
        let junk = destination.createLocation(name: "Should Disappear")
        _ = destination.logVisit(at: junk, reaction: .fine)
        var scheduledCircleIDs = Set<UUID>()
        destination.didCommit = { scheduledCircleIDs.insert($0) }

        let summary = try await AppBackupService.restore(decoded, into: destination)

        XCTAssertEqual(scheduledCircleIDs, Set([placeholderCircleID, try XCTUnwrap(decoded.activeCircleID)]))
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
        XCTAssertEqual(restoredVisit.dateKnowledge, .unknown)
        XCTAssertEqual(restoredVisit.visitType, .coffee)
        XCTAssertEqual(restoredVisit.occasion, .dateNight)
        XCTAssertEqual(restoredVisit.memory, "A complete memory")
        XCTAssertEqual(destination.memory(for: restoredVisit, personID: michelle.id), "Michelle's own memory")
        XCTAssertEqual(Set(restoredVisit.companionIDs), Set([michelle.id, friend.id]))
        XCTAssertEqual(restoredVisit.ratingArray.count, 2)
        let restoredRating = try XCTUnwrap(restoredVisit.rating(for: me.id))
        XCTAssertEqual(restoredRating.service, .liked)
        XCTAssertEqual(restoredRating.atmosphere, .fine)
        XCTAssertEqual(restoredRating.value, .notForMe)
        XCTAssertTrue(restoredRating.hasWouldOrderAgain)
        XCTAssertFalse(restoredRating.wouldOrderAgain)
        let restoredCoonReaction = try XCTUnwrap(restoredVisit.dinerEntryReactionArray.first)
        XCTAssertEqual(restoredCoonReaction.kind, .runItBack)
        XCTAssertEqual(restoredCoonReaction.authorPersonID, me.id)
        XCTAssertEqual(restoredCoonReaction.targetPersonID, michelle.id)
        XCTAssertEqual(restoredVisit.dishEntryArray.first?.dish?.name, "Cardamom Bun")
        XCTAssertEqual(restoredVisit.photoArray.first?.fullData, Data([1, 2, 3, 4]))
        XCTAssertEqual(restoredVisit.photoArray.first?.thumbnailData, Data([5, 6]))
        XCTAssertEqual(restoredVisit.photoArray.first?.captureDate, Date(timeIntervalSince1970: 1_719_999_900))
        XCTAssertEqual(restoredVisit.photoArray.first?.caption, "Cardamom and sunshine")
        XCTAssertEqual(restoredVisit.photoArray.first?.personID, me.id)
        let restoredLinks = try XCTUnwrap(destination.activeCircle?.externalImportLinks?.allObjects as? [ExternalImportLinkEntity])
        XCTAssertEqual(restoredLinks.count, 1)
        XCTAssertEqual(restoredLinks.first?.targetID, first.id)
        XCTAssertEqual(restoredLinks.first?.createdByImport, true)
        XCTAssertEqual(restoredLinks.first?.session?.id, importSession.id)
        XCTAssertEqual(destination.beliImportSessions.count, 1)
        XCTAssertEqual(destination.beliImportSessions.first?.photosAdded, 1)
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
        payload["formatVersion"] = AppBackupArchive.minimumSupportedFormatVersion
        payload.removeValue(forKey: "dinerEntryReactions")
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

    func testBackupRoundTripsOriginalVisitAndPhotoTimezoneOffsets() async throws {
        let source = makeStore()
        source.bootstrap(myName: "George", circleName: "Timezone Club")
        let location = source.createLocation(name: "Timezone Cafe", category: .fullService)
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-07-17T20:00:00Z"))
        let offsetSeconds = -6 * 60 * 60
        let visit = source.logVisit(
            at: location,
            reaction: .loved,
            date: instant,
            dateTimeZoneOffsetSeconds: offsetSeconds
        )
        source.addPhoto(
            fullData: Data([1, 2, 3]),
            thumbnailData: Data([4]),
            to: visit,
            createdAt: instant,
            captureDate: instant,
            captureTimeZoneOffsetSeconds: offsetSeconds
        )

        let archive = try await AppBackupService.makeArchive(from: source)
        let destination = makeStore()
        destination.bootstrap(myName: "Temporary")
        _ = try await AppBackupService.restore(archive, into: destination)

        let restoredVisit = try XCTUnwrap(destination.visits.first)
        let restoredPhoto = try XCTUnwrap(restoredVisit.photoArray.first)
        XCTAssertEqual(restoredVisit.dateTimeZoneOffsetSeconds?.intValue, offsetSeconds)
        XCTAssertEqual(restoredPhoto.captureTimeZoneOffsetSeconds?.intValue, offsetSeconds)
    }

    func testRestoreCanReconnectToLiveEnrollmentWithoutChangingMemberIdentity() async throws {
        let backupStore = makeStore()
        backupStore.bootstrap(myName: "Backup Davis", circleName: "Old Backup")
        let backupDavisID = try XCTUnwrap(backupStore.currentPerson?.id)
        let historicalKelsey = try XCTUnwrap(backupStore.addNamedCompanion(name: "Kelsey"))
        let favorite = backupStore.createLocation(name: "Kelsey's Archived Favorite")
        let visit = backupStore.logVisit(
            at: favorite,
            reaction: .liked,
            personID: backupDavisID,
            companionIDs: [historicalKelsey.id]
        )
        _ = backupStore.addRating(to: visit, personID: historicalKelsey.id, reaction: .loved)
        let archive = try await AppBackupService.makeArchive(from: backupStore)

        let liveStore = makeStore()
        liveStore.bootstrap(myName: "Davis", circleName: "Big Beautiful Group")
        let liveCircleID = try XCTUnwrap(liveStore.activeCircleID)
        let liveDavisID = try XCTUnwrap(liveStore.currentPerson?.id)
        liveStore.didCommit = nil

        _ = try await AppBackupService.restore(archive, into: liveStore)
        XCTAssertTrue(liveStore.reconnectRestoredLog(
            to: liveCircleID,
            circleName: "Big Beautiful Group",
            memberPersonID: liveDavisID,
            fallbackPersonName: "Davis"
        ))

        XCTAssertEqual(liveStore.activeCircleID, liveCircleID)
        XCTAssertEqual(liveStore.currentPerson?.id, liveDavisID)
        XCTAssertEqual(liveStore.currentPerson?.name, "Backup Davis")
        XCTAssertNil(liveStore.person(id: backupDavisID))
        XCTAssertNotNil(liveStore.namedCompanions.first { $0.name == "Kelsey" })
        let restoredVisit = try XCTUnwrap(liveStore.visits.first { $0.id == visit.id })
        XCTAssertEqual(restoredVisit.createdByID, liveDavisID)
        XCTAssertNotNil(restoredVisit.rating(for: historicalKelsey.id))
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

    func testRestoreDiscardsInvalidCoordinates() async throws {
        let source = makeStore()
        source.bootstrap(myName: "Source")
        let location = source.createLocation(name: "Coordinate Cafe")
        _ = source.logVisit(at: location, reaction: .liked)
        var archive = try await AppBackupService.makeArchive(from: source)
        archive.locations[0].latitude = .nan
        archive.locations[0].longitude = .infinity
        archive.locations[0].hasCoordinates = true
        archive.visits[0].latitude = 91
        archive.visits[0].longitude = -181
        archive.visits[0].hasCoordinates = true

        let destination = makeStore()
        _ = try await AppBackupService.restore(archive, into: destination)

        let restoredLocation = try XCTUnwrap(destination.locations.first)
        let restoredVisit = try XCTUnwrap(destination.visits.first)
        XCTAssertNil(restoredLocation.coordinate)
        XCTAssertFalse(restoredLocation.hasCoordinates)
        XCTAssertFalse(restoredVisit.hasCoordinates)
        XCTAssertEqual(restoredVisit.latitude, 0)
        XCTAssertEqual(restoredVisit.longitude, 0)
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
            XCTAssertEqual(
                error as? AppBackupError,
                .unsupportedVersion(AppBackupArchive.currentFormatVersion + 1)
            )
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
            XCTAssertEqual(error as? AppBackupError, .missingReference("outing’s restaurant is missing"))
        }

        var crossCircle = archive
        let secondCircleID = UUID()
        crossCircle.circles.append(.init(id: secondCircleID, name: "Other", createdAt: .now))
        crossCircle.locations[0].circleID = secondCircleID
        XCTAssertThrowsError(try AppBackupCodec.validate(crossCircle)) { error in
            XCTAssertEqual(error as? AppBackupError, .missingReference("outing and restaurant belong to different circles"))
        }
    }

    func testLegacyBackupWithoutParticipantOrPhotoContributorFieldsStillDecodes() async throws {
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
        photos[0].removeValue(forKey: "personID")
        payload["photos"] = photos
        payload.removeValue(forKey: "participants")

        let decoded = try AppBackupCodec.decode(JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(decoded.participants)
        XCTAssertNil(decoded.photos.first?.captureDate)
        XCTAssertNil(decoded.photos.first?.personID)
    }

    func testBackupCodecRejectsSerializedPayloadBeforeDecoding() {
        let limits = AppBackupLimits(
            maximumSerializedBytes: 8,
            maximumPhotoBytes: 8,
            maximumTotalPhotoBytes: 16,
            maximumRecordsPerCollection: 10,
            maximumTotalRecords: 20
        )

        XCTAssertThrowsError(try AppBackupCodec.decode(Data(repeating: 0, count: 9), limits: limits)) { error in
            XCTAssertEqual(error as? AppBackupError, .backupTooLarge(maximumBytes: 8))
        }
    }

    func testBackupFilePreflightRejectsOversizedFileBeforeReading() throws {
        let limits = AppBackupLimits(
            maximumSerializedBytes: 8,
            maximumPhotoBytes: 8,
            maximumTotalPhotoBytes: 16,
            maximumRecordsPerCollection: 10,
            maximumTotalRecords: 20
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-backup-\(UUID().uuidString).bbrlog")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 9)))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try AppBackupCodec.readBackupData(from: url, limits: limits)) { error in
            XCTAssertEqual(error as? AppBackupError, .backupTooLarge(maximumBytes: 8))
        }
    }

    func testBackupPolicyRejectsPerPhotoAndAggregatePhotoPayloads() async throws {
        let store = makeStore()
        store.bootstrap(myName: "Source")
        let location = store.createLocation(name: "Photo Cafe")
        let visit = store.logVisit(at: location, reaction: .liked)
        store.addPhoto(fullData: Data(repeating: 1, count: 5), thumbnailData: nil, to: visit, createdAt: .now)
        store.addPhoto(fullData: Data(repeating: 2, count: 4), thumbnailData: nil, to: visit, createdAt: .now)
        let archive = try await AppBackupService.makeArchive(from: store)

        let perPhotoLimits = AppBackupLimits(
            maximumSerializedBytes: 1_000,
            maximumPhotoBytes: 4,
            maximumTotalPhotoBytes: 20,
            maximumRecordsPerCollection: 20,
            maximumTotalRecords: 40
        )
        XCTAssertThrowsError(try AppBackupCodec.validate(archive, limits: perPhotoLimits)) { error in
            XCTAssertEqual(error as? AppBackupError, .photoTooLarge(maximumBytes: 4))
        }

        let aggregateLimits = AppBackupLimits(
            maximumSerializedBytes: 1_000,
            maximumPhotoBytes: 5,
            maximumTotalPhotoBytes: 8,
            maximumRecordsPerCollection: 20,
            maximumTotalRecords: 40
        )
        XCTAssertThrowsError(try AppBackupCodec.validate(archive, limits: aggregateLimits)) { error in
            XCTAssertEqual(error as? AppBackupError, .photoLibraryTooLarge(maximumBytes: 8))
        }
        XCTAssertThrowsError(try AppBackupCodec.encode(archive, limits: aggregateLimits)) { error in
            XCTAssertEqual(error as? AppBackupError, .photoLibraryTooLarge(maximumBytes: 8))
        }
    }

    func testBackupPolicyRejectsExcessiveRecordGraphBeforeRestoreChangesData() async throws {
        let source = makeStore()
        source.bootstrap(myName: "Source")
        let archive = try await AppBackupService.makeArchive(from: source)
        let restrictiveLimits = AppBackupLimits(
            maximumSerializedBytes: 1_000,
            maximumPhotoBytes: 100,
            maximumTotalPhotoBytes: 100,
            maximumRecordsPerCollection: 10,
            maximumTotalRecords: 1
        )

        XCTAssertThrowsError(try AppBackupCodec.validate(archive, limits: restrictiveLimits)) { error in
            XCTAssertEqual(error as? AppBackupError, .tooManyRecords(maximumCount: 1))
        }

        let destination = makeStore()
        destination.bootstrap(myName: "Keep Me", circleName: "Current")
        let currentCircleID = try XCTUnwrap(destination.activeCircleID)

        do {
            _ = try await AppBackupService.restore(archive, into: destination, limits: restrictiveLimits)
            XCTFail("Expected an excessive record graph to be rejected")
        } catch {
            XCTAssertEqual(error as? AppBackupError, .tooManyRecords(maximumCount: 1))
        }
        XCTAssertEqual(destination.activeCircleID, currentCircleID)
        XCTAssertEqual(destination.currentPerson?.name, "Keep Me")
    }

    func testReloadSelectsFirstCircleWhenStoredActiveCircleIsMissing() throws {
        let persistence = PersistenceController(inMemory: true)
        let original = AppStore(persistence: persistence)
        original.bootstrap(myName: "Source", circleName: "Recovered")
        let expectedCircleID = try XCTUnwrap(original.activeCircleID)
        UserDefaults.standard.removeObject(forKey: "activeCircleID")

        let reloaded = AppStore(persistence: persistence)

        XCTAssertEqual(reloaded.activeCircleID, expectedCircleID)
    }

    private func makeStore() -> AppStore {
        AppStore(persistence: PersistenceController(inMemory: true))
    }
}
