import CoreData
import Foundation
import Observation
import OSLog
import UIKit

struct CircleSyncPreferences {
    private static let pausedCircleIDsKey = "pausedCircleSyncIDs"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isPaused(_ circleID: UUID) -> Bool {
        Set(defaults.stringArray(forKey: Self.pausedCircleIDsKey) ?? [])
            .contains(circleID.uuidString)
    }

    func setPaused(_ paused: Bool, for circleID: UUID) {
        var circleIDs = Set(defaults.stringArray(forKey: Self.pausedCircleIDsKey) ?? [])
        if paused {
            circleIDs.insert(circleID.uuidString)
        } else {
            circleIDs.remove(circleID.uuidString)
        }
        if circleIDs.isEmpty {
            defaults.removeObject(forKey: Self.pausedCircleIDsKey)
        } else {
            defaults.set(circleIDs.sorted(), forKey: Self.pausedCircleIDsKey)
        }
    }
}

/// Coalesces repeat requests while retaining every distinct circle. A single
/// optional UUID can silently lose work when edits in two circles arrive while
/// a pass is running or while the debounce timer is being restarted.
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

/// The app-facing face of sync: status for the UI, and the handful of actions a
/// person can take (sign in, turn a circle on, invite someone, join, sync now).
@MainActor
@Observable
final class SyncCoordinator {
    private(set) var status: SyncStatus = .disabled
    private(set) var isSignedIn = false
    private(set) var accountUserID: UUID?
    private(set) var lastOutcome: SyncOutcome?
    private(set) var circleMemberships: [SupabaseClient.MembershipRow] = []
    var lastError: String?

    @ObservationIgnored private let configuration: SyncConfiguration?
    @ObservationIgnored private let engine: SyncEngine?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var scheduledCircles = CircleSyncQueue()
    @ObservationIgnored private var pendingCircles = CircleSyncQueue()
    @ObservationIgnored private let signIn = AppleSignIn()
    @ObservationIgnored private let syncPreferences: CircleSyncPreferences
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
        syncPreferences: CircleSyncPreferences = CircleSyncPreferences()
    ) {
        self.configuration = configuration
        self.syncPreferences = syncPreferences
        if let configuration {
            engine = SyncEngine(configuration: configuration, container: container)
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

    func signInWithApple() async {
        guard let engine else {
            lastError = SyncError.notConfigured.localizedDescription
            return
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
        } catch AppleSignInError.cancelled {
            // Not a failure worth surfacing.
        } catch {
            isSignedIn = false
            accountUserID = nil
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        guard let engine else { return }
        debounce?.cancel()
        debounce = nil
        scheduledCircles.removeAll()
        pendingCircles.removeAll()
        await engine.supabase.signOut()
        isSignedIn = false
        accountUserID = nil
        circleMemberships = []
        status = .idle
    }

    // MARK: - Circle enrolment

    func hasCircleKey(circleID: UUID) -> Bool { CircleKeychain.key(for: circleID) != nil }

    func isPaused(circleID: UUID) -> Bool {
        hasCircleKey(circleID: circleID) && syncPreferences.isPaused(circleID)
    }

    func isSyncing(circleID: UUID) -> Bool {
        hasCircleKey(circleID: circleID) && !syncPreferences.isPaused(circleID)
    }

    /// Turns sync on for a circle this device already owns. Generates the key,
    /// stores it locally, and registers the circle server side. The key itself
    /// is never part of that request.
    func enableSync(circleID: UUID, circleName: String, personID: UUID) async {
        guard let engine else {
            lastError = SyncError.notConfigured.localizedDescription
            return
        }
        guard isSignedIn else {
            lastError = SyncError.notSignedIn.localizedDescription
            return
        }
        do {
            let key = CircleKeychain.key(for: circleID) ?? CircleCrypto.makeKey()
            let sealedName = try CircleCrypto.seal(
                Data(circleName.utf8),
                with: key,
                authenticating: CircleCrypto.circleNameIdentity(circleID: circleID)
            ).base64EncodedString()
            // The RPC creates both server rows transactionally. Persisting the
            // key afterward means a failed request never makes the UI claim
            // that this circle is enrolled; a retry is idempotent either way.
            try await engine.supabase.createCircle(id: circleID, nameCipher: sealedName, personID: personID)
            try CircleKeychain.storeKey(key, for: circleID)
            syncPreferences.setPaused(false, for: circleID)
            lastError = nil
            _ = await sync(circleID: circleID)
            await refreshMembers(circleID: circleID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Builds a single-use invitation. The code is registered server side as a
    /// hash; the code and the circle key exist in clear text only inside the
    /// returned value, which the owner hands over out of band.
    func makeInvitation(circleID: UUID, personID: UUID, circleName: String) async -> CircleInvitation? {
        guard let engine else {
            lastError = SyncError.notConfigured.localizedDescription
            return nil
        }
        guard let key = CircleKeychain.key(for: circleID) else {
            lastError = SyncError.circleKeyMissing.localizedDescription
            return nil
        }
        do {
            let code = CircleCrypto.makeInviteCode()
            try await engine.supabase.createInvite(circleID: circleID, personID: personID, code: code)
            lastError = nil
            return CircleInvitation(
                circleID: circleID,
                personID: personID,
                circleName: circleName,
                code: code,
                key: CircleCrypto.encode(key)
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Accepts an invitation: redeems the code for membership, stores the key
    /// that came with it, and pulls the circle down.
    @discardableResult
    func join(_ invitation: CircleInvitation) async -> Bool {
        guard let engine else {
            lastError = SyncError.notConfigured.localizedDescription
            return false
        }
        guard isSignedIn else {
            lastError = SyncError.notSignedIn.localizedDescription
            return false
        }
        do {
            let key = try CircleCrypto.decodeKey(invitation.key)
            let circleID = try await engine.supabase.redeemInvite(
                code: invitation.code,
                expectedCircleID: invitation.circleID,
                expectedPersonID: invitation.personID
            )
            guard circleID == invitation.circleID else {
                lastError = "That invitation points at a different circle than its link claims."
                return false
            }
            try CircleKeychain.storeKey(key, for: circleID)
            syncPreferences.setPaused(false, for: circleID)
            lastError = nil
            guard await sync(circleID: circleID) else {
                if lastError == nil { lastError = "Membership is saved. Try syncing again to finish downloading this circle." }
                return false
            }
            await refreshMembers(circleID: circleID)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Pauses network work without destroying the only local copy of the E2EE
    /// key. Forgetting it would make a member unable to resume and could make
    /// an owner generate a different key that peers cannot decrypt.
    func pauseSync(circleID: UUID) {
        scheduledCircles.remove(circleID)
        pendingCircles.remove(circleID)
        syncPreferences.setPaused(true, for: circleID)
        status = .idle
    }

    @discardableResult
    func resumeSync(circleID: UUID) async -> Bool {
        guard hasCircleKey(circleID: circleID) else {
            lastError = SyncError.circleKeyMissing.localizedDescription
            return false
        }
        syncPreferences.setPaused(false, for: circleID)
        return await sync(circleID: circleID)
    }

    private func forgetCircleAccess(circleID: UUID) {
        scheduledCircles.remove(circleID)
        pendingCircles.remove(circleID)
        syncPreferences.setPaused(false, for: circleID)
        CircleKeychain.removeKey(for: circleID)
        SyncBaselineStore.reset(circleID: circleID)
        status = .idle
    }

    func refreshMembers(circleID: UUID) async {
        guard let engine, isSignedIn, hasCircleKey(circleID: circleID) else {
            circleMemberships = []
            return
        }
        // This deliberately stores only operational metadata. The service
        // still cannot read a circle name, dining record, note, or photo. A
        // presence failure must not hide an otherwise readable member roster.
        do {
            try await engine.supabase.touchMembership(circleID: circleID, appVersion: clientVersion)
        } catch {
            logger.debug("Could not update membership presence: \(error.localizedDescription, privacy: .public)")
        }
        do {
            circleMemberships = try await engine.supabase.members(circleID: circleID)
                .sorted { lhs, rhs in
                    if lhs.role != rhs.role { return lhs.role == "owner" }
                    return lhs.personID.uuidString < rhs.personID.uuidString
                }
        } catch {
            circleMemberships = []
            lastError = error.localizedDescription
        }
    }

    func memberships(circleID: UUID) -> [SupabaseClient.MembershipRow] {
        circleMemberships.filter { $0.circleID == circleID }
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

    /// Deletes the server copy and Storage blobs while preserving the on-device
    /// dining log. Failure is recoverable: the owner can press the same button
    /// again and the deletion protocol resumes where it stopped.
    func deleteSyncedCircle(circleID: UUID) async -> Bool {
        guard let engine else { return false }
        do {
            try await engine.supabase.deleteCircleData(circleID: circleID)
            forgetCircleAccess(circleID: circleID)
            circleMemberships = []
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func leaveSyncedCircle(circleID: UUID) async -> Bool {
        guard let engine else { return false }
        do {
            try await engine.supabase.leaveCircle(circleID: circleID)
            forgetCircleAccess(circleID: circleID)
            circleMemberships = []
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Removes memberships, fully deletes every owned circle (including photo
    /// objects), and finally deletes the Supabase Auth account itself.
    func deleteSyncAccount() async -> Bool {
        guard let engine else { return false }
        do {
            let memberships = try await engine.supabase.memberships()
            for membership in memberships {
                if membership.role == "owner" {
                    try await engine.supabase.deleteCircleData(circleID: membership.circleID)
                } else {
                    try await engine.supabase.leaveCircle(circleID: membership.circleID)
                }
                forgetCircleAccess(circleID: membership.circleID)
            }
            try await engine.supabase.deleteAccount()
            isSignedIn = false
            accountUserID = nil
            circleMemberships = []
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
        guard engine != nil, isSyncing(circleID: circleID) else { return }
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

    /// Syncs every circle this account belongs to and this device holds a key
    /// for. Used at launch, when a reinstalled app has an account but no data.
    func syncKnownCircles() async {
        guard let engine, isSignedIn else { return }
        do {
            for membership in try await engine.supabase.memberships()
            where isSyncing(circleID: membership.circleID) {
                await sync(circleID: membership.circleID)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func sync(circleID: UUID) async -> Bool {
        guard let engine else { return false }
        guard isSyncing(circleID: circleID) else { return false }

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
