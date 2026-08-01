import CoreData
import CryptoKit
import Foundation
import Observation
import OSLog

/// Coalesces repeat requests while retaining every distinct circle. A single
/// optional UUID can silently lose work when edits arrive while a pass is
/// running or while the debounce timer is being restarted.
struct CircleSyncQueue {
    private var circleIDs: Set<UUID> = []

    mutating func enqueue(_ circleID: UUID) {
        circleIDs.insert(circleID)
    }

    mutating func takeNext() -> UUID? {
        guard let next = circleIDs.min(by: { $0.uuidString < $1.uuidString }) else { return nil }
        circleIDs.remove(next)
        return next
    }

    mutating func remove(_ circleID: UUID) {
        circleIDs.remove(circleID)
    }

    mutating func removeAll() {
        circleIDs.removeAll()
    }
}

/// What happened when somebody redeemed a join code.
enum CircleJoinResult: Equatable {
    /// The circle's own name travels back with the redemption so the joined log
    /// keeps the name its members already use, rather than being renamed to
    /// whatever this iPhone happened to call its own log.
    case joined(circleID: UUID, circleName: String?)
    case failed(String)
}

enum CircleEnrollmentDecision: Equatable {
    case useMembership(UUID)
    case create(UUID)
    case missingKey
    case needsFreshCircleIdentity
    case missingLocalIdentity
    case identityConflict

    static func decide(
        hasKey: Bool,
        membershipPersonID: UUID?,
        localPersonID: UUID?
    ) -> CircleEnrollmentDecision {
        if let membershipPersonID {
            guard hasKey else { return .missingKey }
            if let localPersonID, localPersonID != membershipPersonID {
                return .identityConflict
            }
            return .useMembership(membershipPersonID)
        }
        if hasKey { return .needsFreshCircleIdentity }
        if let localPersonID { return .create(localPersonID) }
        return .missingLocalIdentity
    }
}

struct CircleRecoveryCandidate: Equatable {
    let circleID: UUID
    let memberCount: Int
    let lastActivity: Date

    static func preferred(from candidates: [CircleRecoveryCandidate]) -> CircleRecoveryCandidate? {
        candidates.max { lhs, rhs in
            let lhsShared = lhs.memberCount > 1
            let rhsShared = rhs.memberCount > 1
            if lhsShared != rhsShared { return !lhsShared && rhsShared }
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity < rhs.lastActivity }
            if lhs.memberCount != rhs.memberCount { return lhs.memberCount < rhs.memberCount }
            return lhs.circleID.uuidString > rhs.circleID.uuidString
        }
    }
}

enum CircleActivationResult: Equatable {
    case ready(personID: UUID)
    case needsFreshCircleIdentity
    case failed
}

/// The app-facing face of sync.
///
/// There is one dining log and it is always synced once the person is signed
/// in. Nothing here asks whether a circle is "enabled": the app calls
/// ``activate(circleID:name:personID:)`` and this type does whatever that
/// requires — creating the service circle, generating the key, or simply
/// running a pass.
@MainActor
@Observable
final class SyncCoordinator {
    private(set) var status: SyncStatus = .disabled
    private(set) var isSignedIn = false
    private(set) var accountUserID: UUID?
    private(set) var lastOutcome: SyncOutcome?
    private(set) var members: [SupabaseClient.MembershipRow] = []
    /// True while a first upload or download is still filling the circle in.
    private(set) var isPreparing = false
    /// Set only after an authenticated membership query proves this account no
    /// longer belongs to the local circle. The app then rotates the on-device
    /// log into a private circle instead of retrying a revoked identity forever.
    private(set) var circleNeedingFreshIdentity: UUID?
    var lastError: String?

    @ObservationIgnored private let configuration: SyncConfiguration?
    @ObservationIgnored private let engine: SyncEngine?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var scheduledCircles = CircleSyncQueue()
    @ObservationIgnored private var pendingCircles = CircleSyncQueue()
    @ObservationIgnored private var retiringCircleIDs: Set<UUID> = []
    @ObservationIgnored private let signIn = AppleSignIn()
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.davis.bigbeautifulranking",
        category: "Sync"
    )

    /// How long a burst of edits is allowed to settle before a pass starts.
    /// Logging a meal writes a visit, a rating, participants, and dish entries
    /// in quick succession; one pass should carry all of them.
    private static let debounceInterval: Duration = .seconds(2)

    var isConfigured: Bool { configuration != nil }
    var clientVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    init(
        container: NSPersistentContainer,
        configuration: SyncConfiguration? = SyncConfiguration.fromBundle(),
        client: SupabaseClient? = nil
    ) {
        self.configuration = configuration
        if let configuration {
            engine = SyncEngine(configuration: configuration, container: container, client: client)
            status = .idle
        } else {
            engine = nil
            status = .disabled
        }
    }

    // MARK: - Account

    func restoreSession() async {
        guard let engine else { return }
        do {
            let session = try await engine.supabase.restore()
            isSignedIn = session != nil
            accountUserID = session?.userID
        } catch {
            isSignedIn = false
            accountUserID = nil
        }
    }

    @discardableResult
    func signInWithApple() async -> Bool {
        guard let engine else {
            lastError = SyncError.notConfigured.localizedDescription
            return false
        }
        do {
            let credential = try await signIn.requestCredential()
            let session = try await engine.supabase.signInWithApple(
                idToken: credential.identityToken,
                nonce: credential.rawNonce
            )
            isSignedIn = true
            accountUserID = session.userID
            lastError = nil
            return true
        } catch AppleSignInError.cancelled {
            return false
        } catch {
            isSignedIn = false
            accountUserID = nil
            lastError = error.localizedDescription
            return false
        }
    }

    func signOut() async {
        guard let engine else { return }
        debounce?.cancel()
        debounce = nil
        scheduledCircles.removeAll()
        pendingCircles.removeAll()
        await engine.cancelSynchronization()
        await engine.supabase.signOut()
        isSignedIn = false
        accountUserID = nil
        members = []
        status = .idle
    }

    // MARK: - The one circle

    func hasKey(circleID: UUID) -> Bool { CircleKeychain.key(for: circleID) != nil }

    func membership(for userID: UUID?) -> SupabaseClient.MembershipRow? {
        guard let userID else { return nil }
        return members.first { $0.userID == userID }
    }

    var myMembership: SupabaseClient.MembershipRow? { membership(for: accountUserID) }
    var isOwner: Bool { myMembership?.role == "owner" }
    /// Somebody else has joined, so this log is genuinely shared.
    var isShared: Bool { members.count > 1 }

    /// Authoritative enrollment lookup for destructive local transitions such
    /// as backup restore. Callers must distinguish "not a member" from a
    /// network failure instead of guessing from the last cached roster.
    func authenticatedMembership(circleID: UUID) async throws -> SupabaseClient.MembershipRow? {
        guard let engine, isSignedIn else { throw SyncError.notSignedIn }
        return try await engine.supabase.memberships()
            .first { $0.circleID == circleID }
    }

    /// Prevents an in-flight or debounced pass from interpreting a backup's
    /// replacement graph as thousands of intentional deletions. Clearing the
    /// baseline makes the next pass reconcile the restored local log and the
    /// existing remote circle as two complete inputs.
    func prepareForBackupRestore(circleID: UUID) async {
        guard let engine else { return }
        debounce?.cancel()
        debounce = nil
        scheduledCircles.removeAll()
        pendingCircles.removeAll()
        await engine.cancelSynchronization()
        SyncBaselineStore.reset(circleID: circleID)
        status = .idle
        lastError = nil
    }

    /// Brings the circle up to date with the service, doing whatever that
    /// currently requires. Safe to call on every launch and after every join.
    ///
    /// Registration and key creation happen here rather than behind a switch in
    /// Settings: a log that is only sometimes uploaded is the thing that made
    /// members disagree about what the circle contained.
    @discardableResult
    func activate(circleID: UUID, name: String, personID: UUID?) async -> CircleActivationResult {
        guard let engine, isSignedIn else { return .failed }
        isPreparing = true
        defer { isPreparing = false }

        do {
            let membership = try await engine.supabase.memberships()
                .first { $0.circleID == circleID }
            switch CircleEnrollmentDecision.decide(
                hasKey: hasKey(circleID: circleID),
                membershipPersonID: membership?.personID,
                localPersonID: personID
            ) {
            case let .useMembership(serverPersonID):
                circleNeedingFreshIdentity = nil
                _ = await sync(circleID: circleID)
                await refreshMembers(circleID: circleID)
                return status.isFailure ? .failed : .ready(personID: serverPersonID)

            case let .create(localPersonID):
                let key = CircleCrypto.makeKey()
                let sealedName = try CircleCrypto.seal(
                    Data(name.utf8),
                    with: key,
                    authenticating: CircleCrypto.circleNameIdentity(circleID: circleID)
                ).base64EncodedString()
                // The key is persisted only after the service accepted the
                // circle, so a failed request never leaves the app believing it
                // is enrolled. Retrying is idempotent either way.
                try await engine.supabase.createCircle(
                    id: circleID,
                    nameCipher: sealedName,
                    personID: localPersonID
                )
                try CircleKeychain.storeKey(key, for: circleID)
                circleNeedingFreshIdentity = nil
                lastError = nil
                _ = await sync(circleID: circleID)
                await refreshMembers(circleID: circleID)
                return status.isFailure ? .failed : .ready(personID: localPersonID)

            case .missingKey:
                lastError = SyncError.circleKeyMissing.localizedDescription
                status = .failed(SyncError.circleKeyMissing.localizedDescription)
                return .failed

            case .needsFreshCircleIdentity:
                circleNeedingFreshIdentity = circleID
                return .needsFreshCircleIdentity

            case .missingLocalIdentity:
                lastError = SyncError.deviceIdentityMissing.localizedDescription
                status = .failed(SyncError.deviceIdentityMissing.localizedDescription)
                return .failed

            case .identityConflict:
                lastError = SyncError.deviceIdentityConflict.localizedDescription
                status = .failed(SyncError.deviceIdentityConflict.localizedDescription)
                return .failed
            }
        } catch {
            lastError = error.localizedDescription
            status = .failed(error.localizedDescription)
            return .failed
        }
    }

    /// Drops this device's access to a circle without touching the dining log.
    func forget(circleID: UUID) {
        scheduledCircles.remove(circleID)
        pendingCircles.remove(circleID)
        CircleKeychain.removeKey(for: circleID)
        SyncBaselineStore.reset(circleID: circleID)
        if circleNeedingFreshIdentity == circleID { circleNeedingFreshIdentity = nil }
    }

    /// Cleans up the private circle this device published before it joined
    /// somebody else's. Leaving it behind would keep an orphaned encrypted copy
    /// on the service forever and would block account deletion later.
    func discardAbandonedCircle(_ circleID: UUID) async {
        guard let engine, isSignedIn, hasKey(circleID: circleID) else { return }
        retiringCircleIDs.insert(circleID)
        scheduledCircles.remove(circleID)
        pendingCircles.remove(circleID)
        await engine.cancelSynchronization()
        defer { retiringCircleIDs.remove(circleID) }
        do {
            let rows = try await engine.supabase.members(circleID: circleID)
            let mine = rows.first { $0.userID == accountUserID }
            if rows.count <= 1, mine?.role == "owner" {
                try await engine.supabase.deleteCircleData(circleID: circleID)
            } else if mine?.role == "member" {
                try await engine.supabase.leaveCircle(circleID: circleID)
            }
        } catch {
            logger.notice("Could not retire the previous circle: \(error.localizedDescription, privacy: .public)")
        }
        forget(circleID: circleID)
    }

    // MARK: - Members

    /// Refreshes operational roster metadata. A membership's person identity is
    /// immutable after create/join; a roster refresh must never claim a profile
    /// on behalf of the local cache.
    func refreshMembers(circleID: UUID) async {
        guard let engine, isSignedIn, hasKey(circleID: circleID) else {
            members = []
            return
        }
        // This deliberately stores only operational metadata. The service still
        // cannot read a circle name, dining record, note, or photo. A presence
        // failure must not hide an otherwise readable roster.
        do {
            try await engine.supabase.touchMembership(circleID: circleID, appVersion: clientVersion)
        } catch {
            logger.debug("Could not update membership presence: \(error.localizedDescription, privacy: .public)")
        }
        do {
            members = try await roster(circleID: circleID)
        } catch {
            members = []
            lastError = error.localizedDescription
        }
    }

    private func roster(circleID: UUID) async throws -> [SupabaseClient.MembershipRow] {
        guard let engine else { return [] }
        return try await engine.supabase.members(circleID: circleID)
            .sorted { lhs, rhs in
                if lhs.role != rhs.role { return lhs.role == "owner" }
                return lhs.joinedAtText < rhs.joinedAtText
            }
    }

    func removeMember(circleID: UUID, userID: UUID) async -> Bool {
        guard let engine else { return false }
        do {
            try await engine.supabase.removeMember(circleID: circleID, userID: userID)
            await refreshMembers(circleID: circleID)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Invitations

    /// Creates a join code and seals the circle key so only that code can open
    /// it. The code is the whole invitation; the link is a way to type it.
    func makeInvitation(circleID: UUID, circleName: String) async -> CircleInvitation? {
        guard let engine else {
            lastError = SyncError.notConfigured.localizedDescription
            return nil
        }
        guard let key = CircleKeychain.key(for: circleID) else {
            lastError = SyncError.circleKeyMissing.localizedDescription
            return nil
        }
        do {
            let code = CircleJoinCode.random()
            let envelope = try CircleCrypto.wrap(key, with: code, circleID: circleID)
            try await engine.supabase.createJoinCode(
                circleID: circleID,
                codeHash: code.hash,
                envelope: envelope
            )
            lastError = nil
            return CircleInvitation(code: code, circleName: circleName)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Reads the circle's name from the service and opens it with the circle
    /// key. Best effort: a log without a readable name is still perfectly
    /// usable, and the first sync pass brings the name across anyway.
    private func circleName(circleID: UUID, key: SymmetricKey) async -> String? {
        guard let engine else { return nil }
        guard let cipher = try? await engine.supabase.circleNameCipher(circleID: circleID),
              let sealed = Data(base64Encoded: cipher),
              let plaintext = try? CircleCrypto.open(
                  sealed,
                  with: key,
                  authenticating: CircleCrypto.circleNameIdentity(circleID: circleID)
              ) else { return nil }
        return String(data: plaintext, encoding: .utf8)
    }

    @discardableResult
    func cancelInvitations(circleID: UUID) async -> Bool {
        guard let engine else { return false }
        do {
            try await engine.supabase.revokeJoinCodes(circleID: circleID)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Redeems a join code: claims membership, unwraps the circle key, and
    /// stores it. The caller merges the local log into the returned circle and
    /// then calls ``activate(circleID:name:personID:)``.
    func join(_ code: CircleJoinCode, personID: UUID) async -> CircleJoinResult {
        guard let engine else { return .failed(SyncError.notConfigured.localizedDescription) }
        guard isSignedIn else { return .failed(SyncError.notSignedIn.localizedDescription) }
        do {
            let redeemed = try await engine.supabase.redeemJoinCode(
                codeHash: code.hash,
                personID: personID
            )
            let key = try CircleCrypto.unwrap(
                redeemed.envelope,
                with: code,
                circleID: redeemed.circleID
            )
            try CircleKeychain.storeKey(key, for: redeemed.circleID)
            lastError = nil
            return .joined(
                circleID: redeemed.circleID,
                circleName: await circleName(circleID: redeemed.circleID, key: key)
            )
        } catch {
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Leaving

    /// Gives up membership of a shared circle. The dining log on this iPhone is
    /// deliberately untouched; the caller gives it a fresh identity and starts
    /// syncing it as a private circle again.
    func leave(circleID: UUID) async -> Bool {
        guard let engine else { return false }
        retiringCircleIDs.insert(circleID)
        scheduledCircles.remove(circleID)
        pendingCircles.remove(circleID)
        await engine.cancelSynchronization()
        do {
            try await engine.supabase.leaveCircle(circleID: circleID)
            forget(circleID: circleID)
            members = []
            status = .idle
            lastError = nil
            retiringCircleIDs.remove(circleID)
            return true
        } catch {
            retiringCircleIDs.remove(circleID)
            lastError = error.localizedDescription
            return false
        }
    }

    /// Deletes the service copy an owner is responsible for, including every
    /// stored photo object. Failure is recoverable: pressing the same button
    /// again resumes the protocol where it stopped.
    func deleteServerCopy(circleID: UUID) async -> Bool {
        guard let engine else { return false }
        retiringCircleIDs.insert(circleID)
        scheduledCircles.remove(circleID)
        pendingCircles.remove(circleID)
        await engine.cancelSynchronization()
        do {
            try await engine.supabase.deleteCircleData(circleID: circleID)
            forget(circleID: circleID)
            lastError = nil
            retiringCircleIDs.remove(circleID)
            return true
        } catch {
            retiringCircleIDs.remove(circleID)
            lastError = error.localizedDescription
            return false
        }
    }

    /// Retires every server circle still attached to the signed-in account but
    /// keeps the account itself. Reset App calls this before touching Core Data,
    /// so a reset cannot leave orphan memberships that are downloaded and
    /// merged into the next onboarding circle.
    func resetSyncedCircles() async -> Bool {
        guard let engine else { return false }
        do {
            let memberships = try await engine.supabase.memberships()
            let circleIDs = Set(memberships.map(\.circleID))
            retiringCircleIDs.formUnion(circleIDs)
            debounce?.cancel()
            debounce = nil
            for circleID in circleIDs {
                scheduledCircles.remove(circleID)
                pendingCircles.remove(circleID)
            }
            await engine.cancelSynchronization()

            for membership in memberships.sorted(by: { $0.circleID.uuidString < $1.circleID.uuidString }) {
                if membership.role == "owner" {
                    try await engine.supabase.deleteCircleData(circleID: membership.circleID)
                } else {
                    try await engine.supabase.leaveCircle(circleID: membership.circleID)
                }
                forget(circleID: membership.circleID)
            }
            retiringCircleIDs.subtract(circleIDs)
            members = []
            status = .idle
            lastError = nil
            return true
        } catch {
            retiringCircleIDs.removeAll()
            lastError = error.localizedDescription
            status = .failed(error.localizedDescription)
            return false
        }
    }

    /// Removes memberships, fully deletes every owned circle (including photo
    /// objects), and finally deletes the Supabase Auth account itself.
    func deleteAccount() async -> Bool {
        guard let engine else { return false }
        guard await resetSyncedCircles() else { return false }
        do {
            try await engine.supabase.deleteAccount()
            isSignedIn = false
            accountUserID = nil
            members = []
            status = .idle
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Running a pass

    /// Coalesces a burst of edits into one pass.
    func scheduleSync(circleID: UUID) {
        guard engine != nil, isSignedIn, hasKey(circleID: circleID),
              !retiringCircleIDs.contains(circleID) else { return }
        scheduledCircles.enqueue(circleID)
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.flushScheduledSyncs()
        }
    }

    private func flushScheduledSyncs() async {
        debounce = nil
        while let circleID = scheduledCircles.takeNext() {
            await sync(circleID: circleID)
        }
    }

    /// Recovers the most plausible dining log when this installation has no
    /// local data. Legacy builds could leave an account enrolled in several
    /// abandoned circles; downloading and merging all of them is both
    /// surprising and capable of combining unrelated member identities.
    func syncKnownCircles() async {
        guard let engine, isSignedIn else { return }
        do {
            let memberships = try await engine.supabase.memberships()
                .filter { hasKey(circleID: $0.circleID) }
            var candidates: [CircleRecoveryCandidate] = []
            for membership in memberships {
                let roster = try? await engine.supabase.members(circleID: membership.circleID)
                candidates.append(.init(
                    circleID: membership.circleID,
                    memberCount: roster?.count ?? 0,
                    lastActivity: membership.lastSeenAt ?? membership.joinedAt ?? .distantPast
                ))
            }
            if let selected = CircleRecoveryCandidate.preferred(from: candidates) {
                await sync(circleID: selected.circleID)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The circles this account belongs to, whether or not this device can read
    /// them. Used at launch to adopt a log that lives only on the service.
    func knownCircleIDs() async -> [UUID] {
        guard let engine, isSignedIn else { return [] }
        return (try? await engine.supabase.memberships().map(\.circleID)) ?? []
    }

    @discardableResult
    func sync(circleID: UUID) async -> Bool {
        guard let engine else { return false }
        guard isSignedIn, hasKey(circleID: circleID) else { return false }

        // A pass reads the local graph once, near its start. An edit that lands
        // after that read would otherwise wait for some later trigger, so the
        // request is remembered and replayed rather than dropped.
        guard !status.isBusy else {
            pendingCircles.enqueue(circleID)
            return false
        }

        var target: UUID? = circleID
        var requestedResult = false
        var isFirst = true
        while let next = target {
            let succeeded = await runPass(circleID: next, engine: engine)
            if isFirst { requestedResult = succeeded; isFirst = false }
            target = pendingCircles.takeNext()
        }
        return requestedResult
    }

    private func runPass(circleID: UUID, engine: SyncEngine) async -> Bool {
        status = .syncing
        do {
            let outcome = try await engine.synchronize(circleID: circleID)
            try? await engine.supabase.touchMembership(circleID: circleID, appVersion: clientVersion)
            lastOutcome = outcome
            status = .upToDate(.now)
            lastError = nil
            if outcome.conflicts > 0 {
                logger.notice("Sync kept this device's version of \(outcome.conflicts, privacy: .public) record(s).")
            }
            return true
        } catch let error as SyncTransportError where error.mayMeanCircleAccessWasRevoked {
            do {
                let stillAMember = try await engine.supabase.memberships()
                    .contains { $0.circleID == circleID }
                if !stillAMember {
                    circleNeedingFreshIdentity = circleID
                    status = .idle
                    lastError = nil
                    return false
                }
            } catch {
                // Preserve the original access error when the verification
                // query itself is unavailable.
            }
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            return false
        } catch let error as SyncTransportError where error.isTransient {
            status = .offline(error.localizedDescription)
            lastError = error.localizedDescription
            return false
        } catch let error as SyncError {
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            return false
        } catch {
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            return false
        }
    }
}
