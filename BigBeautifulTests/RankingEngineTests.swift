import CoreLocation
import CoreData
import XCTest
@testable import BigBeautiful

@MainActor
final class RankingEngineTests: XCTestCase {
    private var persistence: PersistenceController!
    private var store: AppStore!

    override func setUp() async throws {
        persistence = PersistenceController(inMemory: true, cloudEnabled: false)
        store = AppStore(persistence: persistence)
        store.bootstrap(myName: "Davis", partnerName: "Kelsey")
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
        let kelsey = try! XCTUnwrap(store.circleMembers.first { !$0.isMe })
        store.selectCurrentPerson(kelsey.id)
        XCTAssertEqual(store.currentPerson?.id, kelsey.id)
        XCTAssertEqual(store.partner?.name, "Davis")
    }
}
