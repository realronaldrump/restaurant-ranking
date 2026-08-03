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

    func testCiphertextIsBoundToItsRecordIdentity() throws {
        let key = CircleCrypto.makeKey()
        let payload = Data("private".utf8)
        let firstIdentity = Data("circle|rating|first".utf8)
        let secondIdentity = Data("circle|rating|second".utf8)

        let sealed = try CircleCrypto.seal(payload, with: key, authenticating: firstIdentity)

        XCTAssertEqual(
            try CircleCrypto.open(sealed, with: key, authenticating: firstIdentity),
            payload
        )
        XCTAssertThrowsError(try CircleCrypto.open(sealed, with: key, authenticating: secondIdentity))
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

    func testJoinCodeNormalisesWhatSomebodyActuallyTypes() throws {
        let code = try XCTUnwrap(CircleJoinCode("K7M4-2QPX-9WTR"))
        XCTAssertEqual(code.normalized, "K7M42QPX9WTR")
        XCTAssertEqual(code.formatted, "K7M4-2QPX-9WTR")
        // Lower case, spaces, and the letters Crockford maps onto digits.
        XCTAssertEqual(CircleJoinCode("k7m4 2qpx 9wtr"), code)
        XCTAssertEqual(CircleJoinCode("OI")?.normalized, nil)
        XCTAssertEqual(CircleJoinCode("oiluOILU1234")?.normalized, "011V011V1234")
        XCTAssertNil(CircleJoinCode("K7M4-2QPX"), "a short code is not a code")
        XCTAssertNil(CircleJoinCode("K7M4-2QPX-9WTR-9WTR"))
        XCTAssertNil(CircleJoinCode("K7M4-2QPX-9WT!"))
    }

    func testRandomJoinCodesAreDistinctAndWellFormed() {
        let codes = (0 ..< 200).map { _ in CircleJoinCode.random() }
        XCTAssertEqual(Set(codes.map(\.normalized)).count, codes.count)
        for code in codes {
            XCTAssertEqual(code.normalized.count, CircleJoinCode.length)
            XCTAssertEqual(CircleJoinCode(code.formatted), code)
        }
    }

    /// The service stores this hash instead of the code, so it must be stable.
    func testJoinCodeHashIsSHA256OfTheNormalisedCode() throws {
        let code = try XCTUnwrap(CircleJoinCode("0000-0000-0000"))
        XCTAssertEqual(code.hash, "f7b11509f4d675c3c44f0dd37ca830bb02e8cfa58f04c46283c4bfcbdce1ff45")
        XCTAssertEqual(code.hash, try XCTUnwrap(CircleJoinCode("00000000 0000")).hash)
        XCTAssertNotEqual(code.hash, CircleJoinCode.random().hash)
    }

    func testOnlyTheRightCodeOpensTheKeyEnvelope() throws {
        let circleID = UUID()
        let key = CircleCrypto.makeKey()
        let code = CircleJoinCode.random()

        let envelope = try CircleCrypto.wrap(key, with: code, circleID: circleID)
        let opened = try CircleCrypto.unwrap(envelope, with: code, circleID: circleID)
        XCTAssertEqual(
            opened.withUnsafeBytes { Data($0) },
            key.withUnsafeBytes { Data($0) }
        )

        // A different code, or the same envelope replayed against another
        // circle, must fail rather than yield a usable key.
        XCTAssertThrowsError(try CircleCrypto.unwrap(envelope, with: .random(), circleID: circleID))
        XCTAssertThrowsError(try CircleCrypto.unwrap(envelope, with: code, circleID: UUID()))
    }

    func testInvitationSurvivesAURLRoundTrip() throws {
        let invitation = CircleInvitation(code: .random(), circleName: "Our Table")

        let url = try XCTUnwrap(invitation.url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "realronaldrump.github.io")
        XCTAssertEqual(url.path, "/restaurant-ranking/join")
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query)
        // The key never travels in the link any more, only the code.
        XCTAssertEqual(url.fragment, invitation.code.formatted)
        XCTAssertEqual(CircleInvitation(url: url)?.code, invitation.code)
    }

    func testEveryShapeAnInvitationCanArriveInIsUnderstood() throws {
        let code = CircleJoinCode.random()
        let accepted = [
            "https://realronaldrump.github.io/restaurant-ranking/join#\(code.formatted)",
            "https://realronaldrump.github.io/restaurant-ranking/join/#\(code.normalized)",
            "https://realronaldrump.github.io/restaurant-ranking/join?code=\(code.formatted)",
            "bigbeautifullog://join/\(code.normalized)",
            "bigbeautifullog://\(code.normalized)"
        ]
        for candidate in accepted {
            let url = try XCTUnwrap(URL(string: candidate))
            XCTAssertEqual(CircleInvitation(url: url)?.code, code, "failed for \(candidate)")
        }
    }

    func testUnrelatedURLsAreNotTreatedAsInvitations() {
        XCTAssertNil(CircleInvitation(url: URL(string: "https://example.com/join#K7M42QPX9WTR")!))
        XCTAssertNil(CircleInvitation(url: URL(string: "https://realronaldrump.github.io/restaurant-ranking/join")!))
        XCTAssertNil(CircleInvitation(url: URL(string: "https://realronaldrump.github.io/restaurant-ranking/join#not-a-code")!))
        XCTAssertNil(CircleInvitation(url: URL(string: "https://realronaldrump.github.io/restaurant-ranking/privacy.html#K7M42QPX9WTR")!))
    }
}

@MainActor
final class InvitationRoutingTests: XCTestCase {
    /// An invitation must win over whatever else was on screen, and must still
    /// be pending afterwards so the interface can present it whenever it is
    /// ready. Losing this is what made a tapped link open the app and then
    /// appear to do nothing at all.
    func testIncomingInvitationTakesOverFromAnyOtherSheet() throws {
        let persistence = MemoryInvitationPersistence()
        let router = AppRouter(invitationPersistence: persistence)
        router.sheet = .circle
        let invitation = CircleInvitation(code: .random(), circleName: "Shared Table")

        XCTAssertTrue(router.receiveInvitation(try XCTUnwrap(invitation.url)))

        XCTAssertNil(router.sheet)
        XCTAssertEqual(router.pendingInvitation?.code, invitation.code)
        XCTAssertEqual(persistence.pendingInvitation?.code, invitation.code)
    }

    func testPendingInvitationSurvivesLaunchBootstrapUntilExplicitlyCleared() throws {
        let persistence = MemoryInvitationPersistence()
        let invitation = CircleInvitation(code: .random(), circleName: "Kelsey's Circle")
        let receivingRouter = AppRouter(invitationPersistence: persistence)
        XCTAssertTrue(receivingRouter.receiveInvitation(try XCTUnwrap(invitation.url)))

        let relaunchedRouter = AppRouter(invitationPersistence: persistence)
        relaunchedRouter.restorePendingInvitation()
        XCTAssertEqual(relaunchedRouter.pendingInvitation?.code, invitation.code)

        relaunchedRouter.completeInvitation(try XCTUnwrap(relaunchedRouter.pendingInvitation))
        XCTAssertNil(relaunchedRouter.pendingInvitation)
        XCTAssertNil(persistence.pendingInvitation)
    }
}

private final class MemoryInvitationPersistence: InvitationPersistence {
    var pendingInvitation: CircleInvitation?
    func store(_ invitation: CircleInvitation) throws { pendingInvitation = invitation }
    func remove() { pendingInvitation = nil }
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

    func testLocalDeletionOutsideThePullWindowBecomesATombstone() {
        let plan = SyncPlanner.plan(local: [:], remote: [:], baseline: [key: "a"])

        XCTAssertEqual(plan.tombstone, [key])
        XCTAssertTrue(plan.push.isEmpty)
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

    func testOlderBaselineDecodesWithNoCompletedPhotoCleanup() throws {
        let circleID = UUID()
        let legacy = Data(#"{"circleID":"\#(circleID.uuidString)","watermark":42,"fingerprints":{},"uploadedPhotoIDs":[],"downloadedPhotoIDs":[]}"#.utf8)

        let restored = try JSONDecoder().decode(SyncBaseline.self, from: legacy)

        XCTAssertTrue(restored.cleanedPhotoIDs.isEmpty)
    }

    func testCompletedPhotoCleanupIsNotPlannedAgainUntilThePhotoIsLive() {
        let deleted = UUID()
        let newDeletion = UUID()

        XCTAssertEqual(
            SyncPhotoCleanup.pending(
                candidates: [deleted, newDeletion],
                completed: [deleted],
                livePhotoIDs: []
            ),
            [newDeletion]
        )
        XCTAssertEqual(
            SyncPhotoCleanup.completedAfterReconcilingLivePhotos(
                completed: [deleted],
                livePhotoIDs: [deleted]
            ),
            []
        )
    }

    func testRemotePhotoTombstoneRemainsCleanupCandidateAfterLocalMetadataIsGone() {
        let photoID = UUID()
        let key = SyncKey(kind: .photo, id: photoID)
        let remote = [key: DecodedSyncRecord(
            key: key,
            payload: nil,
            fingerprint: nil,
            deleted: true,
            updatedMS: 42,
            deviceID: nil
        )]
        let retryPlan = SyncPlanner.plan(local: [:], remote: remote, baseline: [:])

        XCTAssertTrue(retryPlan.isEmpty)
        XCTAssertEqual(
            SyncPhotoCleanup.deletionCandidates(
                plannedKeys: retryPlan.tombstone + retryPlan.deleteLocally,
                remote: remote
            ),
            [photoID]
        )
    }
}

final class CircleEnrollmentDecisionTests: XCTestCase {
    private let localPersonID = UUID()
    private let serverPersonID = UUID()

    func testExistingMembershipUsesItsImmutableServerIdentityWhenLocalIdentityIsMissing() {
        XCTAssertEqual(
            CircleEnrollmentDecision.decide(
                hasKey: true,
                membershipPersonID: serverPersonID,
                localPersonID: nil
            ),
            .useMembership(serverPersonID)
        )
    }

    func testExistingMembershipRejectsADifferentLocalIdentity() {
        XCTAssertEqual(
            CircleEnrollmentDecision.decide(
                hasKey: true,
                membershipPersonID: serverPersonID,
                localPersonID: localPersonID
            ),
            .identityConflict
        )
    }

    func testExistingMembershipWithoutAKeyNeedsAJoinCode() {
        XCTAssertEqual(
            CircleEnrollmentDecision.decide(
                hasKey: false,
                membershipPersonID: serverPersonID,
                localPersonID: localPersonID
            ),
            .missingKey
        )
    }

    func testAKeyWithoutMembershipMustRotateInsteadOfResurrectingACircle() {
        XCTAssertEqual(
            CircleEnrollmentDecision.decide(
                hasKey: true,
                membershipPersonID: nil,
                localPersonID: localPersonID
            ),
            .needsFreshCircleIdentity
        )
    }

    func testBrandNewCircleCanBeCreatedForTheCurrentPerson() {
        XCTAssertEqual(
            CircleEnrollmentDecision.decide(
                hasKey: false,
                membershipPersonID: nil,
                localPersonID: localPersonID
            ),
            .create(localPersonID)
        )
    }
}

final class CircleRecoveryCandidateTests: XCTestCase {
    func testFreshInstallPrefersASharedCircleOverLegacyPrivateOrphans() throws {
        let shared = CircleRecoveryCandidate(
            circleID: UUID(), memberCount: 2, lastActivity: Date(timeIntervalSince1970: 100)
        )
        let newerOrphan = CircleRecoveryCandidate(
            circleID: UUID(), memberCount: 1, lastActivity: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(CircleRecoveryCandidate.preferred(from: [newerOrphan, shared]), shared)
    }

    func testFreshInstallUsesMostRecentlyActiveCircleWhenNoneAreShared() throws {
        let older = CircleRecoveryCandidate(
            circleID: UUID(), memberCount: 1, lastActivity: Date(timeIntervalSince1970: 100)
        )
        let newer = CircleRecoveryCandidate(
            circleID: UUID(), memberCount: 1, lastActivity: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(CircleRecoveryCandidate.preferred(from: [newer, older]), newer)
    }
}

// MARK: - Configuration

final class SyncConfigurationTests: XCTestCase {
    private final class StubBundle: Bundle, @unchecked Sendable {
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

// MARK: - Pull pagination

final class SyncPaginationTests: XCTestCase {
    func testCursorBuildsAStableThreeColumnKeysetFilter() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let cursor = SupabaseClient.PullCursor(updatedMS: 1_234, kind: "rating", id: id)

        XCTAssertEqual(
            cursor.postgrestFilter,
            "(updated_ms.gt.1234,and(updated_ms.eq.1234,kind.gt.rating),and(updated_ms.eq.1234,kind.eq.rating,id.gt.11111111-2222-3333-4444-555555555555))"
        )
    }

    func testSkippedRowsPreventTheWatermarkFromAdvancingPastThem() {
        var tracker = SyncWatermarkTracker(startingAt: 10_000)
        tracker.processed(12_000)
        tracker.skipped(11_000)
        tracker.processed(13_000)

        XCTAssertEqual(tracker.value, 11_000)
    }
}

final class CircleSyncQueueTests: XCTestCase {
    func testQueueCoalescesDuplicatesWithoutDroppingDifferentCircles() {
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var queue = CircleSyncQueue()

        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(first)

        XCTAssertEqual(queue.takeNext(), first)
        XCTAssertEqual(queue.takeNext(), second)
        XCTAssertNil(queue.takeNext())
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
        let instant = Date(timeIntervalSince1970: 1_721_000_000)
        let visit = store.logVisit(
            at: location,
            reaction: .loved,
            date: instant,
            dateTimeZoneOffsetSeconds: -6 * 60 * 60,
            companionIDs: [try XCTUnwrap(store.otherCircleMembers.first).id]
        )
        let michelle = try XCTUnwrap(store.otherCircleMembers.first)
        _ = store.addRating(to: visit, personID: michelle.id, reaction: .liked)
        XCTAssertTrue(store.setCoonReaction(.unexpectedlyWonderful, to: michelle.id, in: visit))
        store.addPhoto(
            fullData: Data([0x01, 0x02]),
            thumbnailData: Data([0x03]),
            to: visit,
            createdAt: instant,
            captureDate: instant,
            captureTimeZoneOffsetSeconds: -6 * 60 * 60
        )
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
        XCTAssertTrue(snapshot.records.keys.contains { $0.kind == .dinerEntryReaction })
        XCTAssertTrue(snapshot.records.keys.contains { $0.kind == .photo })
        XCTAssertEqual(snapshot.photoIDs.count, 1)

        // The photo record carries its metadata but never its bytes; blobs go
        // to Storage on their own path.
        let photoKey = try XCTUnwrap(snapshot.records.keys.first { $0.kind == .photo })
        let payload = try XCTUnwrap(snapshot.records[photoKey]).payload
        let decoded = try SyncPayloadCodec.decode(AppBackupArchive.PhotoRecord.self, from: payload)
        XCTAssertNil(decoded.fullData)
        XCTAssertNil(decoded.thumbnailData)
        XCTAssertEqual(decoded.captureTimeZoneOffsetSeconds, -6 * 60 * 60)

        let visitKey = try XCTUnwrap(snapshot.records.keys.first { $0.kind == .visit })
        let visitPayload = try XCTUnwrap(snapshot.records[visitKey]).payload
        let decodedVisit = try SyncPayloadCodec.decode(AppBackupArchive.VisitRecord.self, from: visitPayload)
        XCTAssertEqual(decodedVisit.dateTimeZoneOffsetSeconds, -6 * 60 * 60)
    }

    func testSnapshotPreservesMrBubblesStickerFamily() throws {
        let circleID = try XCTUnwrap(store.activeCircleID)
        let michelle = try XCTUnwrap(store.otherCircleMembers.first)
        let location = store.createLocation(name: "Bubbles Sync Cafe", category: .fullService)
        let visit = store.logVisit(at: location, reaction: .loved, companionIDs: [michelle.id])
        _ = store.addRating(to: visit, personID: michelle.id, reaction: .liked)
        XCTAssertTrue(store.setStickerReaction(.runItBack, mascot: .mrBubbles, to: michelle.id, in: visit))

        let snapshot = try SyncSnapshotBuilder.build(circleID: circleID, in: store.context)
        let reactionKey = try XCTUnwrap(snapshot.records.keys.first { $0.kind == .dinerEntryReaction })
        let payload = try XCTUnwrap(snapshot.records[reactionKey]).payload
        let decoded = try SyncPayloadCodec.decode(
            AppBackupArchive.DinerEntryReactionRecord.self,
            from: payload
        )
        XCTAssertEqual(decoded.mascot, .mrBubbles)
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

    func testLegacyPayloadsPreserveNewerCreatorAndTimezoneFields() throws {
        let circleID = try seedLog()
        let snapshot = try SyncSnapshotBuilder.build(circleID: circleID, in: store.context)
        let location = try XCTUnwrap(store.locations.first { $0.name == "Cafe Cappuccino" })
        let visit = try XCTUnwrap(location.visitArray.first)
        let photo = try XCTUnwrap(visit.photoArray.first)
        let creatorID = try XCTUnwrap(location.createdByID)
        let visitOffset = try XCTUnwrap(visit.dateTimeZoneOffsetSeconds?.intValue)
        let photoOffset = try XCTUnwrap(photo.captureTimeZoneOffsetSeconds?.intValue)

        func payloadRemoving(_ field: String, from payload: Data) throws -> Data {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            object.removeValue(forKey: field)
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        let fieldsByKind: [SyncKind: String] = [
            .location: "createdByID",
            .visit: "dateTimeZoneOffsetSeconds",
            .photo: "captureTimeZoneOffsetSeconds"
        ]
        var remote: [SyncKey: DecodedSyncRecord] = [:]
        for (kind, field) in fieldsByKind {
            let key = try XCTUnwrap(snapshot.records.keys.first { $0.kind == kind })
            let current = try XCTUnwrap(snapshot.records[key])
            let payload = try payloadRemoving(field, from: current.payload)
            remote[key] = DecodedSyncRecord(
                key: key,
                payload: payload,
                fingerprint: SyncPayloadCodec.fingerprint(payload),
                deleted: false,
                updatedMS: 2,
                deviceID: nil
            )
        }

        _ = try SyncApplier.apply(
            records: remote,
            applying: Array(remote.keys),
            deleting: [],
            circleID: circleID,
            in: store.context
        )

        XCTAssertEqual(location.createdByID, creatorID)
        XCTAssertEqual(visit.dateTimeZoneOffsetSeconds?.intValue, visitOffset)
        XCTAssertEqual(photo.captureTimeZoneOffsetSeconds?.intValue, photoOffset)
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

    func testTombstoneCannotDeleteAnObjectBelongingToAnotherCircle() throws {
        let activeCircleID = try XCTUnwrap(store.activeCircleID)
        let otherCircle = CircleEntity(context: store.context)
        otherCircle.id = UUID()
        otherCircle.name = "Other Circle"
        otherCircle.createdAt = .now

        let otherLocation = RestaurantLocation(context: store.context)
        otherLocation.id = UUID()
        otherLocation.name = "Other Circle Cafe"
        otherLocation.category = .fullService
        otherLocation.createdAt = .now
        otherLocation.updatedAt = .now
        otherLocation.circle = otherCircle
        try store.context.save()

        let key = SyncKey(kind: .location, id: otherLocation.id)
        _ = try SyncApplier.apply(
            records: [key: DecodedSyncRecord(
                key: key, payload: nil, fingerprint: nil,
                deleted: true, updatedMS: 2, deviceID: nil
            )],
            applying: [],
            deleting: [key],
            circleID: activeCircleID,
            in: store.context
        )

        XCTAssertFalse(otherLocation.isDeleted)
    }

    func testBrandTombstonePreservesABrandStillUsedByAnotherCircle() throws {
        let activeCircleID = try XCTUnwrap(store.activeCircleID)
        let otherCircle = CircleEntity(context: store.context)
        otherCircle.id = UUID()
        otherCircle.name = "Other Circle"
        otherCircle.createdAt = .now

        let brand = BrandEntity(context: store.context)
        brand.id = UUID()
        brand.name = "Shared Brand"
        brand.createdAt = .now

        let otherLocation = RestaurantLocation(context: store.context)
        otherLocation.id = UUID()
        otherLocation.name = "Other Branch"
        otherLocation.category = .fullService
        otherLocation.createdAt = .now
        otherLocation.updatedAt = .now
        otherLocation.circle = otherCircle
        otherLocation.brand = brand
        try store.context.save()

        let key = SyncKey(kind: .brand, id: brand.id)
        _ = try SyncApplier.apply(
            records: [key: DecodedSyncRecord(
                key: key, payload: nil, fingerprint: nil,
                deleted: true, updatedMS: 2, deviceID: nil
            )],
            applying: [],
            deleting: [key],
            circleID: activeCircleID,
            in: store.context
        )

        XCTAssertFalse(brand.isDeleted)
        XCTAssertEqual(otherLocation.brand, brand)
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

    func testPayloadUUIDMustMatchTheAuthenticatedServerRow() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let payloadID = UUID()
        let rowKey = SyncKey(kind: .circle, id: UUID())
        let payload = try SyncPayloadCodec.encode(AppBackupArchive.CircleRecord(
            id: payloadID,
            name: "Swapped payload",
            createdAt: .now
        ))
        let record = DecodedSyncRecord(
            key: rowKey,
            payload: payload,
            fingerprint: SyncPayloadCodec.fingerprint(payload),
            deleted: false,
            updatedMS: 1,
            deviceID: nil
        )

        XCTAssertThrowsError(try SyncApplier.apply(
            records: [rowKey: record],
            applying: [rowKey],
            deleting: [],
            circleID: rowKey.id,
            in: context
        )) { error in
            XCTAssertEqual(error as? SyncError, .entityMismatch("circle identity"))
        }

        XCTAssertEqual(try context.count(for: NSFetchRequest<CircleEntity>(entityName: "CircleEntity")), 0)
    }

    func testRecordWithMissingParentsIsDeferredWithoutCreatingAPartialObject() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let circleID = UUID()
        let visitID = UUID()
        let key = SyncKey(kind: .visit, id: visitID)
        let payload = try SyncPayloadCodec.encode(AppBackupArchive.VisitRecord(
            id: visitID,
            date: .now,
            dateKnowledge: .known,
            visitType: .meal,
            priceBand: 2,
            occasion: nil,
            memory: "Must not be saved without its parents",
            latitude: 0,
            longitude: 0,
            hasCoordinates: false,
            createdAt: .now,
            isShared: true,
            createdByID: UUID(),
            companionIDs: [],
            circleID: circleID,
            locationID: UUID()
        ))
        let record = DecodedSyncRecord(
            key: key,
            payload: payload,
            fingerprint: SyncPayloadCodec.fingerprint(payload),
            deleted: false,
            updatedMS: 1,
            deviceID: nil
        )

        let result = try SyncApplier.apply(
            records: [key: record],
            applying: [key],
            deleting: [],
            circleID: circleID,
            in: context
        )

        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.unresolvedReferences, 1)
        XCTAssertEqual(result.deferredKeys, [key])
        XCTAssertEqual(try context.count(for: NSFetchRequest<VisitEntity>(entityName: "VisitEntity")), 0)
    }

    func testRecordWithANilRequiredRelationshipIsDeferred() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let circleID = UUID()
        let circle = CircleEntity(context: context)
        circle.id = circleID
        circle.name = "Receiving Circle"
        circle.createdAt = .now
        try context.save()

        let visitID = UUID()
        let key = SyncKey(kind: .visit, id: visitID)
        let payload = try SyncPayloadCodec.encode(AppBackupArchive.VisitRecord(
            id: visitID,
            date: .now,
            dateKnowledge: .known,
            visitType: .meal,
            priceBand: 2,
            occasion: nil,
            memory: "A visit cannot exist without a restaurant",
            latitude: 0,
            longitude: 0,
            hasCoordinates: false,
            createdAt: .now,
            isShared: true,
            createdByID: UUID(),
            companionIDs: [],
            circleID: circleID,
            locationID: nil
        ))
        let record = DecodedSyncRecord(
            key: key,
            payload: payload,
            fingerprint: SyncPayloadCodec.fingerprint(payload),
            deleted: false,
            updatedMS: 1,
            deviceID: nil
        )

        let result = try SyncApplier.apply(
            records: [key: record],
            applying: [key],
            deleting: [],
            circleID: circleID,
            in: context
        )

        XCTAssertEqual(result.deferredKeys, [key])
        XCTAssertEqual(try context.count(for: NSFetchRequest<VisitEntity>(entityName: "VisitEntity")), 0)
    }

    func testRecordCannotLinkToAParentFromAnotherCircle() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let receivingCircleID = UUID()
        let otherCircle = CircleEntity(context: context)
        otherCircle.id = UUID()
        otherCircle.name = "Other Circle"
        otherCircle.createdAt = .now

        let otherLocation = RestaurantLocation(context: context)
        otherLocation.id = UUID()
        otherLocation.name = "Private to Other Circle"
        otherLocation.category = .fullService
        otherLocation.createdAt = .now
        otherLocation.updatedAt = .now
        otherLocation.circle = otherCircle

        let receivingCircle = CircleEntity(context: context)
        receivingCircle.id = receivingCircleID
        receivingCircle.name = "Receiving Circle"
        receivingCircle.createdAt = .now
        try context.save()

        let visitID = UUID()
        let key = SyncKey(kind: .visit, id: visitID)
        let payload = try SyncPayloadCodec.encode(AppBackupArchive.VisitRecord(
            id: visitID,
            date: .now,
            dateKnowledge: .known,
            visitType: .meal,
            priceBand: 2,
            occasion: nil,
            memory: "Must not cross circle boundaries",
            latitude: 0,
            longitude: 0,
            hasCoordinates: false,
            createdAt: .now,
            isShared: true,
            createdByID: UUID(),
            companionIDs: [],
            circleID: receivingCircleID,
            locationID: otherLocation.id
        ))
        let record = DecodedSyncRecord(
            key: key,
            payload: payload,
            fingerprint: SyncPayloadCodec.fingerprint(payload),
            deleted: false,
            updatedMS: 1,
            deviceID: nil
        )

        XCTAssertThrowsError(try SyncApplier.apply(
            records: [key: record],
            applying: [key],
            deleting: [],
            circleID: receivingCircleID,
            in: context
        )) { error in
            XCTAssertEqual(error as? SyncError, .entityMismatch("visit relationship"))
        }
        XCTAssertEqual(try context.count(for: NSFetchRequest<VisitEntity>(entityName: "VisitEntity")), 0)
    }
}
