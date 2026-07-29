import CoreData
import CryptoKit
import Foundation
import XCTest
@testable import RestaurantLog

// MARK: - Encryption and invitations

final class CircleCryptoTests: XCTestCase {
    func testSealedPayloadRoundTrips() throws {
        let key = CircleCrypto.makeKey()
        let plaintext = Data("Gladys and the second-best queso in Texas".utf8)

        let sealed = try CircleCrypto.seal(plaintext, with: key)
        XCTAssertNotEqual(sealed, plaintext)
        XCTAssertEqual(try CircleCrypto.open(sealed, with: key), plaintext)
    }

    func testADifferentKeyCannotOpenThePayload() throws {
        let sealed = try CircleCrypto.seal(Data("private".utf8), with: CircleCrypto.makeKey())

        XCTAssertThrowsError(try CircleCrypto.open(sealed, with: CircleCrypto.makeKey())) { error in
            XCTAssertEqual(error as? CircleCryptoError, .openFailed)
        }
    }

    /// AES-GCM uses a fresh nonce per seal, which is why the sync plan compares
    /// plaintext fingerprints rather than ciphertext.
    func testSealingTheSameValueTwiceProducesDifferentCiphertext() throws {
        let key = CircleCrypto.makeKey()
        let plaintext = Data("same value".utf8)

        let first = try CircleCrypto.seal(plaintext, with: key)
        let second = try CircleCrypto.seal(plaintext, with: key)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try CircleCrypto.open(first, with: key), try CircleCrypto.open(second, with: key))
    }

    func testKeyEncodingRoundTrips() throws {
        let key = CircleCrypto.makeKey()
        let restored = try CircleCrypto.decodeKey(CircleCrypto.encode(key))

        XCTAssertEqual(
            key.withUnsafeBytes { Data($0) },
            restored.withUnsafeBytes { Data($0) }
        )
    }

    func testMalformedKeyIsRejected() {
        XCTAssertThrowsError(try CircleCrypto.decodeKey("not-base64-at-all!!"))
        XCTAssertThrowsError(try CircleCrypto.decodeKey(Data([1, 2, 3]).base64EncodedString()))
    }

    func testInvitationSurvivesAURLRoundTrip() throws {
        let invitation = CircleInvitation(
            circleID: UUID(),
            circleName: "Our Table",
            code: CircleCrypto.makeInviteCode(),
            key: CircleCrypto.encode(CircleCrypto.makeKey())
        )

        let url = try XCTUnwrap(invitation.url)
        XCTAssertEqual(CircleInvitation(url: url), invitation)
    }

    func testUnrelatedURLsAreNotTreatedAsInvitations() {
        XCTAssertNil(CircleInvitation(url: URL(string: "https://example.com/join?code=abc&key=def")!))
        XCTAssertNil(CircleInvitation(url: URL(string: "bigbeautifullog://join")!))
    }
}

// MARK: - Payload encoding

final class SyncPayloadCodecTests: XCTestCase {
    private func location(name: String, tags: [String]) -> AppBackupArchive.LocationRecord {
        AppBackupArchive.LocationRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: name, category: .fullService, address: nil, city: "Waco", phone: nil,
            urlString: nil, hoursText: nil, latitude: 31.5, longitude: -97.1,
            hasCoordinates: true, isClosed: false, sourceIdentifier: nil,
            cuisines: ["tex-mex"], tags: tags,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            circleID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            brandID: nil
        )
    }

    /// Two devices holding equal values must produce byte-identical payloads,
    /// otherwise every pass would see changes that are not there.
    func testEncodingIsDeterministic() throws {
        let value = location(name: "Cafe Cappuccino", tags: ["brunch", "patio"])

        let first = try SyncPayloadCodec.encode(value)
        let second = try SyncPayloadCodec.encode(value)

        XCTAssertEqual(first, second)
        XCTAssertEqual(SyncPayloadCodec.fingerprint(first), SyncPayloadCodec.fingerprint(second))
    }

    func testFingerprintChangesWhenAnyFieldChanges() throws {
        let original = try SyncPayloadCodec.encode(location(name: "Cafe Cappuccino", tags: ["brunch"]))
        let renamed = try SyncPayloadCodec.encode(location(name: "Cafe Capp", tags: ["brunch"]))
        let retagged = try SyncPayloadCodec.encode(location(name: "Cafe Cappuccino", tags: ["dinner"]))

        XCTAssertNotEqual(SyncPayloadCodec.fingerprint(original), SyncPayloadCodec.fingerprint(renamed))
        XCTAssertNotEqual(SyncPayloadCodec.fingerprint(original), SyncPayloadCodec.fingerprint(retagged))
    }

    func testRecordsRoundTripThroughTheCodec() throws {
        let value = location(name: "Clay Pot", tags: ["takeout"])
        let record = try SyncPayloadCodec.record(.location, value.id, value)

        let decoded = try SyncPayloadCodec.decode(AppBackupArchive.LocationRecord.self, from: record.payload)

        XCTAssertEqual(decoded.name, "Clay Pot")
        XCTAssertEqual(decoded.city, "Waco")
        XCTAssertEqual(decoded.createdAt, value.createdAt)
        XCTAssertEqual(record.key.kind, .location)
    }
}

// MARK: - Merge rules

final class SyncPlannerTests: XCTestCase {
    private let key = SyncKey(kind: .rating, id: UUID())

    private func local(_ fingerprint: String) -> LocalSyncRecord {
        LocalSyncRecord(key: key, payload: Data(fingerprint.utf8), fingerprint: fingerprint)
    }

    private func remote(_ fingerprint: String?, deleted: Bool = false) -> DecodedSyncRecord {
        DecodedSyncRecord(
            key: key,
            payload: fingerprint.map { Data($0.utf8) },
            fingerprint: fingerprint,
            deleted: deleted,
            updatedMS: 1_000,
            deviceID: nil
        )
    }

    func testUnchangedRecordProducesNoWork() {
        let plan = SyncPlanner.plan(
            local: [key: local("a")],
            remote: [key: remote("a")],
            baseline: [key: "a"]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testBrandNewLocalRecordIsPushed() {
        let plan = SyncPlanner.plan(local: [key: local("a")], remote: [:], baseline: [:])

        XCTAssertEqual(plan.push, [key])
        XCTAssertTrue(plan.apply.isEmpty)
    }

    func testBrandNewRemoteRecordIsApplied() {
        let plan = SyncPlanner.plan(local: [:], remote: [key: remote("a")], baseline: [:])

        XCTAssertEqual(plan.apply, [key])
        XCTAssertTrue(plan.push.isEmpty)
    }

    func testLocalEditIsPushedWhenTheRemoteIsUnchanged() {
        let plan = SyncPlanner.plan(
            local: [key: local("b")],
            remote: [key: remote("a")],
            baseline: [key: "a"]
        )
        XCTAssertEqual(plan.push, [key])
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testRemoteEditIsAppliedWhenTheLocalIsUnchanged() {
        let plan = SyncPlanner.plan(
            local: [key: local("a")],
            remote: [key: remote("b")],
            baseline: [key: "a"]
        )
        XCTAssertEqual(plan.apply, [key])
        XCTAssertTrue(plan.push.isEmpty)
    }

    /// Documented rule: the device in front of the person wins, and the result
    /// is published so the peer converges on it.
    func testConcurrentEditsKeepTheLocalVersionAndReportAConflict() {
        let plan = SyncPlanner.plan(
            local: [key: local("mine")],
            remote: [key: remote("theirs")],
            baseline: [key: "original"]
        )
        XCTAssertEqual(plan.push, [key])
        XCTAssertEqual(plan.conflicts, [key])
        XCTAssertTrue(plan.apply.isEmpty)
    }

    func testTwoDevicesThatAlreadyAgreeDoNothingEvenWithAStaleBaseline() {
        let plan = SyncPlanner.plan(
            local: [key: local("same")],
            remote: [key: remote("same")],
            baseline: [key: "older"]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testLocalDeletionBecomesATombstone() {
        let plan = SyncPlanner.plan(local: [:], remote: [key: remote("a")], baseline: [key: "a"])

        XCTAssertEqual(plan.tombstone, [key])
    }

    func testRemoteTombstoneDeletesTheLocalRecord() {
        let plan = SyncPlanner.plan(
            local: [key: local("a")],
            remote: [key: remote(nil, deleted: true)],
            baseline: [key: "a"]
        )
        XCTAssertEqual(plan.deleteLocally, [key])
    }

    /// Losing an edit is unrecoverable; restoring a record someone deleted is not.
    func testAnEditWinsOverARemoteDeletion() {
        let plan = SyncPlanner.plan(
            local: [key: local("edited")],
            remote: [key: remote(nil, deleted: true)],
            baseline: [key: "original"]
        )
        XCTAssertEqual(plan.push, [key])
        XCTAssertEqual(plan.conflicts, [key])
        XCTAssertTrue(plan.deleteLocally.isEmpty)
    }

    func testARemoteEditWinsOverALocalDeletion() {
        let plan = SyncPlanner.plan(
            local: [:],
            remote: [key: remote("edited")],
            baseline: [key: "original"]
        )
        XCTAssertEqual(plan.apply, [key])
        XCTAssertEqual(plan.conflicts, [key])
        XCTAssertTrue(plan.tombstone.isEmpty)
    }

    func testRecordsGoneFromBothSidesAreForgotten() {
        let plan = SyncPlanner.plan(local: [:], remote: [:], baseline: [key: "a"])

        XCTAssertEqual(plan.forget, [key])
        XCTAssertTrue(plan.push.isEmpty)
        XCTAssertTrue(plan.tombstone.isEmpty)
    }

    /// A visit must never be written before the restaurant it points at.
    func testAppliesArriveParentsFirstAndDeletionsChildrenFirst() {
        let circle = SyncKey(kind: .circle, id: UUID())
        let location = SyncKey(kind: .location, id: UUID())
        let visit = SyncKey(kind: .visit, id: UUID())
        let rating = SyncKey(kind: .rating, id: UUID())

        func newRemote(_ key: SyncKey) -> DecodedSyncRecord {
            DecodedSyncRecord(
                key: key, payload: Data("x".utf8), fingerprint: "x",
                deleted: false, updatedMS: 1, deviceID: nil
            )
        }
        func tombstone(_ key: SyncKey) -> DecodedSyncRecord {
            DecodedSyncRecord(
                key: key, payload: nil, fingerprint: nil,
                deleted: true, updatedMS: 1, deviceID: nil
            )
        }
        func mine(_ key: SyncKey) -> LocalSyncRecord {
            LocalSyncRecord(key: key, payload: Data("x".utf8), fingerprint: "x")
        }

        let applyPlan = SyncPlanner.plan(
            local: [:],
            remote: [rating: newRemote(rating), circle: newRemote(circle),
                     visit: newRemote(visit), location: newRemote(location)],
            baseline: [:]
        )
        XCTAssertEqual(applyPlan.apply.map(\.kind), [.circle, .location, .visit, .rating])

        let deletePlan = SyncPlanner.plan(
            local: [circle: mine(circle), location: mine(location),
                    visit: mine(visit), rating: mine(rating)],
            remote: [rating: tombstone(rating), circle: tombstone(circle),
                     visit: tombstone(visit), location: tombstone(location)],
            baseline: [circle: "x", location: "x", visit: "x", rating: "x"]
        )
        XCTAssertEqual(deletePlan.deleteLocally.map(\.kind), [.rating, .visit, .location, .circle])
    }
}

// MARK: - Baseline

final class SyncBaselineTests: XCTestCase {
    func testKeysRoundTripThroughTheirStringForm() throws {
        let key = SyncKey(kind: .dishEntry, id: UUID())
        let encoded = SyncBaseline.encodeKey(key)

        XCTAssertEqual(SyncBaseline.decodeKey(encoded), key)
    }

    func testUnknownKeysAreIgnoredRatherThanCrashing() {
        XCTAssertNil(SyncBaseline.decodeKey("notAKind:\(UUID().uuidString)"))
        XCTAssertNil(SyncBaseline.decodeKey("visit:not-a-uuid"))
        XCTAssertNil(SyncBaseline.decodeKey("nonsense"))
    }

    func testBaselineSurvivesEncodingAndFiltersUnreadableEntries() throws {
        var baseline = SyncBaseline(circleID: UUID(), watermark: 42)
        let key = SyncKey(kind: .visit, id: UUID())
        baseline.fingerprints[SyncBaseline.encodeKey(key)] = "abc"
        baseline.fingerprints["garbage"] = "def"

        let data = try JSONEncoder().encode(baseline)
        let restored = try JSONDecoder().decode(SyncBaseline.self, from: data)

        XCTAssertEqual(restored.watermark, 42)
        XCTAssertEqual(restored.keyedFingerprints, [key: "abc"])
    }
}

// MARK: - Configuration

final class SyncConfigurationTests: XCTestCase {
    private final class StubBundle: Bundle {
        var values: [String: String] = [:]
        override func object(forInfoDictionaryKey key: String) -> Any? { values[key] }
    }

    private func configuration(url: String, key: String) -> SyncConfiguration? {
        let bundle = StubBundle()
        bundle.values = [SyncConfiguration.infoURLKey: url, SyncConfiguration.infoAnonKey: key]
        return SyncConfiguration.fromBundle(bundle)
    }

    func testAConfiguredProjectIsAccepted() throws {
        let result = try XCTUnwrap(configuration(url: "https://abc.supabase.co", key: "anon-key"))

        XCTAssertEqual(result.restURL.absoluteString, "https://abc.supabase.co/rest/v1")
        XCTAssertEqual(result.authURL.absoluteString, "https://abc.supabase.co/auth/v1")
        XCTAssertEqual(result.storageURL.absoluteString, "https://abc.supabase.co/storage/v1")
    }

    /// An unconfigured build must run entirely on device rather than trying to
    /// reach a placeholder host.
    func testPlaceholderAndUnexpandedValuesLeaveSyncOff() {
        XCTAssertNil(configuration(url: "https://YOUR_PROJECT.supabase.co", key: "anon"))
        XCTAssertNil(configuration(url: "https://abc.supabase.co", key: "YOUR_ANON_KEY"))
        XCTAssertNil(configuration(url: "https://$(SUPABASE_HOST)", key: "anon"))
        XCTAssertNil(configuration(url: "https://", key: "anon"))
        XCTAssertNil(configuration(url: "https://abc.supabase.co", key: ""))
        XCTAssertNil(configuration(url: "http://abc.supabase.co", key: "anon"))
    }
}

// MARK: - Snapshot and apply

@MainActor
final class SyncSnapshotTests: XCTestCase {
    private var persistence: PersistenceController!
    private var store: AppStore!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "activeCircleID")
        UserDefaults.standard.removeObject(forKey: "devicePersonID")
        UserDefaults.standard.removeObject(forKey: "devicePersonIDsByCircle")
        persistence = PersistenceController(inMemory: true)
        store = AppStore(persistence: persistence)
        store.bootstrap(myName: "George")
        XCTAssertNotNil(store.addCircleMember(name: "Michelle"))
    }

    private func seedLog() throws -> UUID {
        let circleID = try XCTUnwrap(store.activeCircleID)
        let location = store.createLocation(name: "Cafe Cappuccino", category: .fullService)
        let visit = store.logVisit(at: location, reaction: .loved)
        store.addPhoto(fullData: Data([0x01, 0x02]), thumbnailData: Data([0x03]), to: visit)
        store.toggleWant(store.createLocation(name: "Someday Diner", category: .fullService))
        store.recordAnchor(for: location, value: 88)
        return circleID
    }

    func testSnapshotCoversTheCircleAndOmitsPhotoBytes() throws {
        let circleID = try seedLog()

        let snapshot = try SyncSnapshotBuilder.build(circleID: circleID, in: store.context)

        XCTAssertTrue(snapshot.records.keys.contains { $0.kind == .circle })
        XCTAssertTrue(snapshot.records.keys.contains { $0.kind == .location })
        XCTAssertTrue(snapshot.records.keys.contains { $0.kind == .visit })
        XCTAssertTrue(snapshot.records.keys.contains { $0.kind == .photo })
        XCTAssertEqual(snapshot.photoIDs.count, 1)

        // The photo record carries its metadata but never its bytes; blobs go
        // to Storage on their own path.
        let photoKey = try XCTUnwrap(snapshot.records.keys.first { $0.kind == .photo })
        let payload = try XCTUnwrap(snapshot.records[photoKey]).payload
        let decoded = try SyncPayloadCodec.decode(AppBackupArchive.PhotoRecord.self, from: payload)
        XCTAssertNil(decoded.fullData)
        XCTAssertNil(decoded.thumbnailData)
    }

    func testAMissingCircleYieldsAnEmptySnapshotRatherThanAnError() throws {
        let snapshot = try SyncSnapshotBuilder.build(circleID: UUID(), in: store.context)

        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertTrue(snapshot.photoIDs.isEmpty)
    }

    /// The real convergence test: what one device encodes, another can rebuild
    /// into a graph that fingerprints identically.
    func testSnapshotAppliedToAFreshStoreReproducesTheSameFingerprints() throws {
        let circleID = try seedLog()
        let source = try SyncSnapshotBuilder.build(circleID: circleID, in: store.context)

        let receivingPersistence = PersistenceController(inMemory: true)
        let context = receivingPersistence.container.viewContext

        var remote: [SyncKey: DecodedSyncRecord] = [:]
        for (key, record) in source.records {
            remote[key] = DecodedSyncRecord(
                key: key, payload: record.payload, fingerprint: record.fingerprint,
                deleted: false, updatedMS: 1, deviceID: nil
            )
        }
        let plan = SyncPlanner.plan(local: [:], remote: remote, baseline: [:])
        XCTAssertEqual(plan.apply.count, source.records.count)

        try SyncApplier.apply(
            records: remote,
            applying: plan.apply,
            deleting: [],
            circleID: circleID,
            in: context
        )
        try context.save()

        let rebuilt = try SyncSnapshotBuilder.build(circleID: circleID, in: context)

        XCTAssertEqual(Set(rebuilt.records.keys), Set(source.records.keys))
        for (key, record) in source.records {
            XCTAssertEqual(
                rebuilt.records[key]?.fingerprint, record.fingerprint,
                "\(key.kind.rawValue) did not survive the round trip unchanged"
            )
        }

        // A second pass over an already-converged store must find nothing to do.
        let settled = SyncPlanner.plan(
            local: rebuilt.records,
            remote: remote,
            baseline: rebuilt.records.mapValues(\.fingerprint)
        )
        XCTAssertTrue(settled.isEmpty)
    }

    func testAppliedTombstonesRemoveTheRecordLocally() throws {
        let circleID = try seedLog()
        let source = try SyncSnapshotBuilder.build(circleID: circleID, in: store.context)
        let wantKey = try XCTUnwrap(source.records.keys.first { $0.kind == .want })

        try SyncApplier.apply(
            records: [wantKey: DecodedSyncRecord(
                key: wantKey, payload: nil, fingerprint: nil,
                deleted: true, updatedMS: 2, deviceID: nil
            )],
            applying: [],
            deleting: [wantKey],
            circleID: circleID,
            in: store.context
        )
        try store.context.save()

        let rebuilt = try SyncSnapshotBuilder.build(circleID: circleID, in: store.context)
        XCTAssertFalse(rebuilt.records.keys.contains(wantKey))
    }

    func testApplyingTheSameRecordsTwiceIsIdempotent() throws {
        let circleID = try seedLog()
        let source = try SyncSnapshotBuilder.build(circleID: circleID, in: store.context)

        let receivingPersistence = PersistenceController(inMemory: true)
        let context = receivingPersistence.container.viewContext

        var remote: [SyncKey: DecodedSyncRecord] = [:]
        for (key, record) in source.records {
            remote[key] = DecodedSyncRecord(
                key: key, payload: record.payload, fingerprint: record.fingerprint,
                deleted: false, updatedMS: 1, deviceID: nil
            )
        }
        let ordered = SyncPlanner.plan(local: [:], remote: remote, baseline: [:]).apply

        for _ in 0 ..< 2 {
            try SyncApplier.apply(
                records: remote, applying: ordered, deleting: [],
                circleID: circleID, in: context
            )
            try context.save()
        }

        let rebuilt = try SyncSnapshotBuilder.build(circleID: circleID, in: context)
        XCTAssertEqual(rebuilt.records.count, source.records.count)

        let visits = try context.fetch(NSFetchRequest<VisitEntity>(entityName: "VisitEntity"))
        XCTAssertEqual(visits.count, 1, "Replaying a pull must not duplicate rows")
    }
}
