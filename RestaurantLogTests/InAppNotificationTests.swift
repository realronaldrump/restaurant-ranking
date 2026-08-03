import CoreData
import Foundation
import XCTest
@testable import RestaurantLog

final class NotificationActivityExtractorTests: XCTestCase {
    private let circleID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let creatorID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let viewerID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let locationID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    private let visitID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!

    func testNewRestaurantAndSharedOutingTargetTheRightPerson() throws {
        let location = makeLocation()
        let visit = makeVisit(companions: [viewerID])
        let locationKey = SyncKey(kind: .location, id: locationID)
        let visitKey = SyncKey(kind: .visit, id: visitID)
        let remote = remoteRecords([
            locationKey: try SyncPayloadCodec.encode(location),
            visitKey: try SyncPayloadCodec.encode(visit)
        ])

        let candidates = NotificationActivityExtractor.extract(
            circleID: circleID,
            appliedKeys: [locationKey, visitKey],
            remote: remote,
            local: [:],
            baseline: [:]
        )

        XCTAssertEqual(candidates.map(\.kind), [.restaurantAdded, .outingAdded])
        let outing = try XCTUnwrap(candidates.first { $0.kind == .outingAdded })
        XCTAssertEqual(outing.actorPersonID, creatorID)
        XCTAssertEqual(outing.targetPersonID, viewerID)
        XCTAssertEqual(outing.audiencePersonIDs, [viewerID])
    }

    func testChangedOutingOnlyNotifiesNewCompanions() throws {
        let oldVisit = makeVisit(companions: [])
        let newVisit = makeVisit(companions: [viewerID])
        let key = SyncKey(kind: .visit, id: visitID)
        let local = [key: try SyncPayloadCodec.record(.visit, visitID, oldVisit)]
        let remote = remoteRecords([key: try SyncPayloadCodec.encode(newVisit)])
        let baseline = [key: local[key]!.fingerprint]

        let candidates = NotificationActivityExtractor.extract(
            circleID: circleID,
            appliedKeys: [key],
            remote: remote,
            local: local,
            baseline: baseline
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.kind, .outingAdded)
        XCTAssertEqual(candidates.first?.targetPersonID, viewerID)
    }

    func testNewDinerEntryCollapsesRatingDishAndPhotoIntoOneActivity() throws {
        let visit = makeVisit(companions: [])
        let visitKey = SyncKey(kind: .visit, id: visitID)
        let rating = AppBackupArchive.RatingRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            personID: viewerID,
            reaction: .loved,
            service: nil,
            atmosphere: nil,
            value: nil,
            hazyMemory: false,
            wouldOrderAgain: true,
            hasWouldOrderAgain: true,
            createdAt: .now,
            visitID: visitID
        )
        let dishEntry = AppBackupArchive.DishEntryRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            personID: viewerID,
            reaction: .loved,
            wouldOrderAgain: true,
            createdAt: .now,
            dishID: nil,
            visitID: visitID
        )
        let photo = AppBackupArchive.PhotoRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            personID: viewerID,
            thumbnailData: nil,
            fullData: nil,
            createdAt: .now,
            captureDate: nil,
            captureTimeZoneOffsetSeconds: nil,
            caption: nil,
            visitID: visitID
        )
        let ratingKey = SyncKey(kind: .rating, id: rating.id)
        let dishKey = SyncKey(kind: .dishEntry, id: dishEntry.id)
        let photoKey = SyncKey(kind: .photo, id: photo.id)
        let remote = remoteRecords([
            visitKey: try SyncPayloadCodec.encode(visit),
            ratingKey: try SyncPayloadCodec.encode(rating),
            dishKey: try SyncPayloadCodec.encode(dishEntry),
            photoKey: try SyncPayloadCodec.encode(photo)
        ])

        let candidates = NotificationActivityExtractor.extract(
            circleID: circleID,
            appliedKeys: [visitKey, ratingKey, dishKey, photoKey],
            remote: remote,
            local: [:],
            baseline: [:]
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.kind, .dinerEntryReactionAdded)
        XCTAssertEqual(candidates.first?.actorPersonID, viewerID)
        XCTAssertEqual(candidates.first?.detailRaw, Reaction.loved.rawValue)
    }

    func testPhotoOrDishAddedToAnExistingDinerEntryDoesNotAnnounceANewEntry() throws {
        let visit = makeVisit(companions: [])
        let visitKey = SyncKey(kind: .visit, id: visitID)
        let rating = AppBackupArchive.RatingRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            personID: viewerID,
            reaction: .liked,
            service: nil,
            atmosphere: nil,
            value: nil,
            hazyMemory: false,
            wouldOrderAgain: true,
            hasWouldOrderAgain: true,
            createdAt: .now,
            visitID: visitID
        )
        let photo = AppBackupArchive.PhotoRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            personID: viewerID,
            thumbnailData: nil,
            fullData: nil,
            createdAt: .now,
            captureDate: nil,
            captureTimeZoneOffsetSeconds: nil,
            caption: nil,
            visitID: visitID
        )
        let dishEntry = AppBackupArchive.DishEntryRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            personID: viewerID,
            reaction: .liked,
            wouldOrderAgain: true,
            createdAt: .now,
            dishID: nil,
            visitID: visitID
        )
        let ratingKey = SyncKey(kind: .rating, id: rating.id)
        let photoKey = SyncKey(kind: .photo, id: photo.id)
        let dishKey = SyncKey(kind: .dishEntry, id: dishEntry.id)
        let local = [
            visitKey: try SyncPayloadCodec.record(.visit, visitID, visit),
            ratingKey: try SyncPayloadCodec.record(.rating, rating.id, rating)
        ]
        let additions = [
            (photoKey, try SyncPayloadCodec.encode(photo)),
            (dishKey, try SyncPayloadCodec.encode(dishEntry))
        ]

        for (key, payload) in additions {
            let candidates = NotificationActivityExtractor.extract(
                circleID: circleID,
                appliedKeys: [key],
                remote: remoteRecords([key: payload]),
                local: local,
                baseline: [:]
            )

            XCTAssertTrue(candidates.isEmpty, "\(key.kind.rawValue) created a duplicate diner-entry activity")
        }
    }

    func testReaddingACompanionProducesANewPersistentEventKey() throws {
        let oldVisit = makeVisit(companions: [])
        let newVisit = makeVisit(companions: [viewerID])
        let key = SyncKey(kind: .visit, id: visitID)
        let local = [key: try SyncPayloadCodec.record(.visit, visitID, oldVisit)]
        let baseline = [key: local[key]!.fingerprint]

        let first = NotificationActivityExtractor.extract(
            circleID: circleID,
            appliedKeys: [key],
            remote: remoteRecords(
                [key: try SyncPayloadCodec.encode(newVisit)],
                updatedMS: 1_720_000_200
            ),
            local: local,
            baseline: baseline
        )
        let readded = NotificationActivityExtractor.extract(
            circleID: circleID,
            appliedKeys: [key],
            remote: remoteRecords(
                [key: try SyncPayloadCodec.encode(newVisit)],
                updatedMS: 1_720_000_400
            ),
            local: local,
            baseline: baseline
        )

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(readded.count, 1)
        XCTAssertNotEqual(first.first?.eventKey, readded.first?.eventKey)
    }

    func testStickerReactionIsOnlyForItsTarget() throws {
        let visit = makeVisit(companions: [])
        let reaction = AppBackupArchive.DinerEntryReactionRecord(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            authorPersonID: creatorID,
            targetPersonID: viewerID,
            kind: .unexpectedlyWonderful,
            createdAt: .now,
            updatedAt: .now,
            visitID: visitID
        )
        let visitKey = SyncKey(kind: .visit, id: visitID)
        let reactionKey = SyncKey(kind: .dinerEntryReaction, id: reaction.id)
        let remote = remoteRecords([
            visitKey: try SyncPayloadCodec.encode(visit),
            reactionKey: try SyncPayloadCodec.encode(reaction)
        ])

        let candidates = NotificationActivityExtractor.extract(
            circleID: circleID,
            appliedKeys: [visitKey, reactionKey],
            remote: remote,
            local: [:],
            baseline: [:]
        )

        let candidate = try XCTUnwrap(candidates.first { $0.kind == .stickerReactionAdded })
        XCTAssertEqual(candidate.targetPersonID, viewerID)
        XCTAssertEqual(candidate.audiencePersonIDs, [viewerID])
        XCTAssertEqual(candidate.detailRaw, CoonReaction.unexpectedlyWonderful.rawValue)
    }

    func testSameDeviceAndImportedRecordsAreSuppressed() throws {
        let location = makeLocation()
        let locationKey = SyncKey(kind: .location, id: locationID)
        let importLink = AppBackupArchive.ExternalImportLinkRecord(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            provider: "beli",
            recordType: "restaurant",
            externalKey: "restaurant-1",
            contentHash: nil,
            targetID: locationID,
            createdByImport: true,
            createdAt: .now,
            updatedAt: .now,
            circleID: circleID,
            sessionID: nil
        )
        let importKey = SyncKey(kind: .importLink, id: importLink.id)
        let importedRemote = remoteRecords([
            importKey: try SyncPayloadCodec.encode(importLink),
            locationKey: try SyncPayloadCodec.encode(location)
        ])
        let importedCandidates = NotificationActivityExtractor.extract(
            circleID: circleID,
            appliedKeys: [importKey, locationKey],
            remote: importedRemote,
            local: [:],
            baseline: [:]
        )
        XCTAssertTrue(importedCandidates.isEmpty)

        let localRemote = remoteRecords(
            [locationKey: try SyncPayloadCodec.encode(location)],
            deviceID: SyncDevice.identifier
        )
        let localCandidates = NotificationActivityExtractor.extract(
            circleID: circleID,
            appliedKeys: [locationKey],
            remote: localRemote,
            local: [:],
            baseline: [:]
        )
        XCTAssertTrue(localCandidates.isEmpty)
    }

    func testLegacyBaselineDecodesWithActivityBootstrapOff() throws {
        let legacy = Data(#"{"circleID":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","watermark":42,"fingerprints":{},"uploadedPhotoIDs":[],"downloadedPhotoIDs":[]}"#.utf8)
        let baseline = try JSONDecoder().decode(SyncBaseline.self, from: legacy)
        XCTAssertFalse(baseline.activitySeeded)
    }

    private func makeLocation() -> AppBackupArchive.LocationRecord {
        let date = Date(timeIntervalSince1970: 1_720_000_000)
        return AppBackupArchive.LocationRecord(
            id: locationID,
            name: "The Test Kitchen",
            category: .fullService,
            address: nil,
            city: "Denver",
            phone: nil,
            urlString: nil,
            hoursText: nil,
            latitude: 0,
            longitude: 0,
            hasCoordinates: false,
            isClosed: false,
            sourceIdentifier: nil,
            cuisines: [],
            tags: [],
            createdAt: date,
            createdByID: creatorID,
            updatedAt: date,
            circleID: circleID,
            brandID: nil
        )
    }

    private func makeVisit(companions: [UUID]) -> AppBackupArchive.VisitRecord {
        let date = Date(timeIntervalSince1970: 1_720_000_100)
        return AppBackupArchive.VisitRecord(
            id: visitID,
            date: date,
            dateKnowledge: .known,
            dateTimeZoneOffsetSeconds: nil,
            visitType: nil,
            priceBand: 0,
            occasion: nil,
            memory: nil,
            latitude: 0,
            longitude: 0,
            hasCoordinates: false,
            createdAt: date,
            isShared: !companions.isEmpty,
            createdByID: creatorID,
            companionIDs: companions,
            circleID: circleID,
            locationID: locationID
        )
    }

    private func remoteRecords(
        _ values: [SyncKey: Data],
        deviceID: UUID? = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
        updatedMS: Int64 = 1_720_000_200
    ) -> [SyncKey: DecodedSyncRecord] {
        var result: [SyncKey: DecodedSyncRecord] = [:]
        for (key, payload) in values {
            result[key] = DecodedSyncRecord(
                key: key,
                payload: payload,
                fingerprint: SyncPayloadCodec.fingerprint(payload),
                deleted: false,
                updatedMS: updatedMS,
                deviceID: deviceID
            )
        }
        return result
    }
}

@MainActor
final class InAppNotificationPersistenceTests: XCTestCase {
    private let circleID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let viewerID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let actorID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    func testDeduplicatesAndKeepsOnlyTheNewestHundredRows() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let candidates = (0 ..< 101).map { index in
            NotificationActivityCandidate(
                eventKey: "\(circleID.uuidString)|event|\(index)",
                circleID: circleID,
                kind: .restaurantAdded,
                actorPersonID: actorID,
                targetPersonID: nil,
                locationID: nil,
                visitID: nil,
                detailRaw: nil,
                audiencePersonIDs: [],
                occurredAt: Date(timeIntervalSince1970: Double(index))
            )
        }

        XCTAssertEqual(try InAppNotificationPersistence.insert(candidates, receivedAt: .now, into: context), 101)
        try context.save()

        let request = NSFetchRequest<InAppNotificationEntity>(entityName: "InAppNotificationEntity")
        let rows = try context.fetch(request)
        XCTAssertEqual(rows.count, InAppNotificationPersistence.maximumPerCircle)
        XCTAssertFalse(rows.contains { $0.eventKey.hasSuffix("|event|0") })

        XCTAssertEqual(try InAppNotificationPersistence.insert([candidates[100]], into: context), 0)
    }

    func testInboxFiltersAudienceAndPersistsReadStateLocally() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let visible = NotificationActivityCandidate(
            eventKey: "visible",
            circleID: circleID,
            kind: .stickerReactionAdded,
            actorPersonID: actorID,
            targetPersonID: viewerID,
            locationID: nil,
            visitID: nil,
            detailRaw: CoonReaction.runItBack.rawValue,
            audiencePersonIDs: [viewerID],
            occurredAt: .now
        )
        let hidden = NotificationActivityCandidate(
            eventKey: "hidden",
            circleID: circleID,
            kind: .stickerReactionAdded,
            actorPersonID: actorID,
            targetPersonID: UUID(),
            locationID: nil,
            visitID: nil,
            detailRaw: CoonReaction.noNotes.rawValue,
            audiencePersonIDs: [],
            occurredAt: .now
        )
        _ = try InAppNotificationPersistence.insert([visible, hidden], into: context)
        try context.save()

        let inbox = NotificationInbox(persistence: persistence)
        XCTAssertEqual(inbox.visibleItems(circleID: circleID, viewerID: viewerID).count, 1)
        XCTAssertEqual(inbox.unreadCount(circleID: circleID, viewerID: viewerID), 1)
        let id = try XCTUnwrap(inbox.visibleItems(circleID: circleID, viewerID: viewerID).first?.id)

        inbox.markRead(id)
        XCTAssertEqual(inbox.unreadCount(circleID: circleID, viewerID: viewerID), 0)
        inbox.markAllRead(circleID: circleID, viewerID: viewerID)
        XCTAssertEqual(inbox.visibleItems(circleID: circleID, viewerID: viewerID).first?.readAt != nil, true)
    }

    func testInboxOrdersSameBatchByOccurrenceTime() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let older = NotificationActivityCandidate(
            eventKey: "a-older",
            circleID: circleID,
            kind: .restaurantAdded,
            actorPersonID: actorID,
            targetPersonID: nil,
            locationID: nil,
            visitID: nil,
            detailRaw: nil,
            audiencePersonIDs: [],
            occurredAt: receivedAt.addingTimeInterval(-100)
        )
        let newer = NotificationActivityCandidate(
            eventKey: "z-newer",
            circleID: circleID,
            kind: .restaurantAdded,
            actorPersonID: actorID,
            targetPersonID: nil,
            locationID: nil,
            visitID: nil,
            detailRaw: nil,
            audiencePersonIDs: [],
            occurredAt: receivedAt.addingTimeInterval(-10)
        )
        _ = try InAppNotificationPersistence.insert(
            [older, newer],
            receivedAt: receivedAt,
            into: context
        )
        try context.save()

        let inbox = NotificationInbox(persistence: persistence)

        XCTAssertEqual(
            inbox.visibleItems(circleID: circleID, viewerID: viewerID).map(\.eventKey),
            ["z-newer", "a-older"]
        )
    }
}
