import CoreLocation
import CoreData
import CloudKit
import ImageIO
import UIKit
import XCTest
@testable import BigBeautiful

@MainActor
final class RankingEngineTests: XCTestCase {
    private var persistence: PersistenceController!
    private var store: AppStore!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "activeCircleID")
        UserDefaults.standard.removeObject(forKey: "devicePersonID")
        UserDefaults.standard.removeObject(forKey: "devicePersonIDsByCircle")
        persistence = PersistenceController(inMemory: true, cloudEnabled: false)
        store = AppStore(persistence: persistence)
        store.bootstrap(myName: "George", partnerName: "Michelle")
    }

    func testManagedObjectModelMeetsCloudKitAttributeRequirements() {
        let model = ManagedObjectModel.make()
        let invalidAttributes = model.entities.flatMap { entity in
            entity.attributesByName.values.compactMap { attribute -> String? in
                guard !attribute.isOptional, attribute.defaultValue == nil else { return nil }
                return "\(entity.name ?? "Unknown").\(attribute.name)"
            }
        }

        XCTAssertEqual(invalidAttributes, [], "CloudKit requires every non-optional attribute to have a default value")
    }

    func testSingleLovedVisitLandsNearAbsoluteAnchor() {
        let place = store.createLocation(name: "Anchor House", category: .fullService)
        _ = store.logVisit(at: place, reaction: .loved)
        let score = try! XCTUnwrap(store.score(for: place))
        XCTAssertEqual(score.score, 85, accuracy: 2)
        XCTAssertTrue(score.isProvisional)
    }

    func testOptionalDetailsNeverMoveVisitMoreThanSevenPoints() {
        let place = store.createLocation(name: "Particulars", category: .fullService)
        let visit = store.logVisit(at: place, reaction: .fine)
        let rating = try! XCTUnwrap(visit.ratingArray.first)
        store.updateRating(rating, service: .loved, atmosphere: .loved, value: .loved, wouldOrderAgain: true)
        XCTAssertLessThanOrEqual(abs(store.rankingEngine.visitValue(visit: visit, rating: rating) - Reaction.fine.anchor), 7.0001)
    }

    func testThreeYearOldVisitCarriesAboutHalfWeight() {
        let recent = Date.now.addingTimeInterval(-30 * 86_400)
        let old = Date.now.addingTimeInterval(-3 * 365 * 86_400)
        XCTAssertEqual(store.rankingEngine.recencyWeight(visitDate: old, asOf: .now) / store.rankingEngine.recencyWeight(visitDate: recent, asOf: .now), 0.5, accuracy: 0.04)
    }

    func testUnratedVisitDoesNotEnterRankings() {
        let place = store.createLocation(name: "History Only", category: .bakeries)
        _ = store.logVisit(at: place, reaction: nil)
        XCTAssertNil(store.score(for: place))
        XCTAssertEqual(place.visitArray.count, 1)
    }

    func testEstablishedPlaceMovementIsGuarded() {
        let place = store.createLocation(name: "Reliable", category: .coffeeTea)
        for offset in 0..<5 { _ = store.logVisit(at: place, reaction: .loved, date: .now.addingTimeInterval(Double(-offset * 30) * 86_400)) }
        let before = try! XCTUnwrap(store.score(for: place)).score
        _ = store.logVisit(at: place, reaction: .notForMe)
        let after = try! XCTUnwrap(store.score(for: place)).score
        XCTAssertLessThanOrEqual(abs(after - before), RankingEngine.establishedVisitMovementLimit + 0.15)
    }

    func testPhotoClusteringUsesTwoHoursAndFiveHundredFeet() {
        let data = Data([0])
        let base = BackfillPhoto(id: UUID(), fullData: data, thumbnailData: nil, date: .now, coordinate: .init(latitude: 40.76, longitude: -111.89))
        let nearby = BackfillPhoto(id: UUID(), fullData: data, thumbnailData: nil, date: .now.addingTimeInterval(60 * 60), coordinate: .init(latitude: 40.7602, longitude: -111.8902))
        let far = BackfillPhoto(id: UUID(), fullData: data, thumbnailData: nil, date: .now.addingTimeInterval(90 * 60), coordinate: .init(latitude: 40.80, longitude: -111.89))
        let clusters = ImageSanitizer.clusters([base, nearby, far])
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters.first?.photos.count, 2)
    }

    func testSanitizedBackfillPhotoBoundsStoredPixelDimensions() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 2_400)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 2_400))
        }
        let data = try XCTUnwrap(source.jpegData(compressionQuality: 0.95))

        let photo = try XCTUnwrap(ImageSanitizer.process(data))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(photo.fullData as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)

        XCTAssertLessThanOrEqual(max(width, height), 2_048)
    }

    func testNamedCompanionDoesNotBecomeRankingPartner() {
        let partnerID = store.partner?.id
        let companion = store.addNamedCompanion(name: "Aunt Jo")
        XCTAssertNotNil(companion)
        XCTAssertFalse(companion?.isCircleMember ?? true)
        XCTAssertEqual(store.partner?.id, partnerID)
        XCTAssertEqual(store.namedCompanions.map(\.name), ["Aunt Jo"])
    }

    func testMergeReassignsComparisonEvidence() {
        let keeper = store.createLocation(name: "The Keeper", category: .bakeries)
        let duplicate = store.createLocation(name: "Keeper Bakery", category: .bakeries)
        let duplicateID = duplicate.id
        let other = store.createLocation(name: "The Other", category: .bakeries)
        _ = store.logVisit(at: duplicate, reaction: .loved)
        _ = store.logVisit(at: other, reaction: .liked)
        store.recordComparison(a: duplicate, b: other, outcome: .a)
        store.merge(duplicate, into: keeper)
        XCTAssertTrue(store.comparisons.contains { $0.locationAID == keeper.id && $0.locationBID == other.id })
        XCTAssertFalse(store.locations.contains { $0.id == duplicateID })
        XCTAssertEqual(keeper.visitArray.count, 1)
    }

    func testDeviceIdentityCanSelectAnotherCircleMember() {
        let michelle = try! XCTUnwrap(store.circleMembers.first { !$0.isMe })
        store.selectCurrentPerson(michelle.id)
        XCTAssertEqual(store.currentPerson?.id, michelle.id)
        XCTAssertEqual(store.partner?.name, "George")
    }

    func testUnboundCircleRequiresExplicitDeviceIdentity() throws {
        let second = try makeCircle(name: "Shared Circle", people: [
            ("Owner", true),
            ("Invited Guest", false)
        ])

        store.activateCircle(second.circle.id)

        XCTAssertNil(store.currentPerson, "A newly accepted shared circle must not silently act as its owner")
    }

    func testDeviceIdentityIsRememberedPerCircle() throws {
        let originalCircleID = try XCTUnwrap(store.activeCircle?.id)
        let second = try makeCircle(name: "Shared Circle", people: [
            ("Owner", true),
            ("Invited Guest", false)
        ])
        let invitedGuest = try XCTUnwrap(second.people.first { $0.name == "Invited Guest" })

        store.activateCircle(second.circle.id)
        store.selectCurrentPerson(invitedGuest.id)
        store.activateCircle(originalCircleID)
        store.activateCircle(second.circle.id)

        XCTAssertEqual(store.currentPerson?.id, invitedGuest.id)
    }

    func testCloudSharingReusesAnExistingShare() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "ExistingShare", ownerName: CKCurrentUserDefaultName)
        let existingShare = CKShare(recordZoneID: zoneID)
        let existingPayload = SharePayload(share: existingShare, container: CKContainer.default())
        var createCallCount = 0
        let service = CloudSharingService(
            existingPayload: { _, _ in existingPayload },
            newPayload: { _, _ in
                createCallCount += 1
                return existingPayload
            }
        )

        let payload = try await service.payload(for: try XCTUnwrap(store.activeCircle), persistence: persistence)

        XCTAssertEqual(createCallCount, 0)
        XCTAssertEqual(payload.share.recordID, existingShare.recordID)
    }

    func testPersistenceFailuresBecomeUserVisible() async {
        NotificationCenter.default.post(
            name: .persistenceDidFail,
            object: persistence,
            userInfo: [PersistenceNotificationKey.message: "The test save failed."]
        )
        await Task.yield()

        XCTAssertEqual(store.lastError, "The test save failed.")
        store.clearLastError()
        XCTAssertNil(store.lastError)
    }

    func testDiagnosticBatchImportReloadCountAndTiming() throws {
        let personID = try XCTUnwrap(store.currentPerson?.id)
        let reloadCountBeforeImport = store.diagnosticReloadCount
        let startedAt = CFAbsoluteTimeGetCurrent()

        store.performBatch {
            for index in 0..<300 {
                let location = store.createLocation(name: "Diagnostic Place \(index)", category: .fullService)
                let visit = store.logVisit(at: location, reaction: .loved, date: .now, hazy: false)
                store.updateVisit(visit, type: nil, priceBand: 0, occasion: nil, memory: "Diagnostic note", companions: [])
                _ = store.addDish(name: "Diagnostic dish", role: .entree, reaction: .loved, wouldOrderAgain: true, to: visit, personID: personID)
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        let reloads = store.diagnosticReloadCount - reloadCountBeforeImport
        print("[DEBUG-batch-perf] 300 rows: \(reloads) reloads in \(elapsed) seconds")
        XCTAssertEqual(reloads, 1)
    }

    func testDiagnosticBatchStillDeduplicatesNewLocations() {
        store.performBatch {
            _ = store.createLocation(name: "Repeated Place", category: .fullService)
            _ = store.createLocation(name: "Repeated Place", category: .fullService)
        }

        XCTAssertEqual(store.locations.filter { $0.name == "Repeated Place" }.count, 1)
    }

    func testDiagnosticRemoteChangesAreNotCoalesced() async {
        let reloadCountBeforeNotifications = store.diagnosticReloadCount

        for _ in 0..<50 {
            NotificationCenter.default.post(
                name: .NSPersistentStoreRemoteChange,
                object: persistence.container.persistentStoreCoordinator
            )
        }
        for _ in 0..<100 where store.diagnosticReloadCount < reloadCountBeforeNotifications + 50 {
            await Task.yield()
        }

        let reloads = store.diagnosticReloadCount - reloadCountBeforeNotifications
        print("[DEBUG-batch-perf] 50 remote-change notifications: \(reloads) reloads")
        XCTAssertEqual(reloads, 50)
    }

    private func makeCircle(name: String, people: [(String, Bool)]) throws -> (circle: CircleEntity, people: [PersonEntity]) {
        let circle = CircleEntity(context: store.context)
        circle.id = UUID()
        circle.name = name
        circle.createdAt = .now
        let members = people.map { name, isMe in
            let person = PersonEntity(context: store.context)
            person.id = UUID()
            person.name = name
            person.isMe = isMe
            person.isCircleMember = true
            person.colorHex = "6F1D2B"
            person.createdAt = .now
            person.circle = circle
            return person
        }
        try persistence.save()
        store.reload()
        return (circle, members)
    }
}
