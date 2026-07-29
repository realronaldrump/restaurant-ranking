import CoreData
import Foundation
import Observation
import OSLog
import UIKit

/// The app-facing face of sync: status for the UI, and the handful of actions a
/// person can take (sign in, turn a circle on, invite someone, join, sync now).
@MainActor
@Observable
final class SyncCoordinator {
    private(set) var status: SyncStatus = .disabled
    private(set) var isSignedIn = false
    private(set) var lastOutcome: SyncOutcome?
    var lastError: String?

    @ObservationIgnored private let configuration: SyncConfiguration?
    @ObservationIgnored private let container: NSPersistentContainer
    @ObservationIgnored private let engine: SyncEngine?
    @ObservationIgnored private var debounce: Task<Void, Never>?
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

    init(container: NSPersistentContainer, configuration: SyncConfiguration? = SyncConfiguration.fromBundle()) {
        self.container = container
        self.configuration = configuration
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
            isSignedIn = try await engine.supabase.restore() != nil
        } catch {
            isSignedIn = false
        }
    }

    func signInWithApple() async {
        guard let engine else {
            lastError = SyncError.notConfigured.localizedDescription
            return
        }
        do {
            let credential = try await signIn.requestCredential()
            _ = try await engine.supabase.signInWithApple(
                idToken: credential.identityToken,
                nonce: credential.rawNonce
            )
            isSignedIn = true
            lastError = nil
        } catch AppleSignInError.cancelled {
            // Not a failure worth surfacing.
        } catch {
            isSignedIn = false
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        guard let engine else { return }
        await engine.supabase.signOut()
        isSignedIn = false
        status = .idle
    }

    // MARK: - Circle enrolment

    func isSyncing(circleID: UUID) -> Bool {
        CircleKeychain.key(for: circleID) != nil
    }

    /// Turns sync on for a circle this device already owns. Generates the key,
    /// stores it locally, and registers the circle server side. The key itself
    /// is never part of that request.
    func enableSync(circleID: UUID, circleName: String) async {
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
            try CircleKeychain.storeKey(key, for: circleID)
            let sealedName = try CircleCrypto.seal(Data(circleName.utf8), with: key).base64EncodedString()
            try await engine.supabase.createCircle(id: circleID, nameCipher: sealedName)
            lastError = nil
            await sync(circleID: circleID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Builds a single-use invitation. The code is registered server side as a
    /// hash; the code and the circle key exist in clear text only inside the
    /// returned value, which the owner hands over out of band.
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
            let code = CircleCrypto.makeInviteCode()
            try await engine.supabase.createInvite(circleID: circleID, code: code)
            lastError = nil
            return CircleInvitation(
                circleID: circleID,
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
            let circleID = try await engine.supabase.redeemInvite(code: invitation.code)
            guard circleID == invitation.circleID else {
                lastError = "That invitation points at a different circle than its link claims."
                return false
            }
            try CircleKeychain.storeKey(key, for: circleID)
            lastError = nil
            await sync(circleID: circleID)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Stops syncing a circle on this device and forgets its key. Records
    /// already on the server stay there for the other members.
    func disableSync(circleID: UUID) {
        CircleKeychain.removeKey(for: circleID)
        SyncBaselineStore.reset(circleID: circleID)
        status = .idle
    }

    // MARK: - Running a pass

    /// Coalesces a burst of edits into one pass.
    func scheduleSync(circleID: UUID) {
        guard engine != nil, isSyncing(circleID: circleID) else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.sync(circleID: circleID)
        }
    }

    /// Syncs every circle this account belongs to and this device holds a key
    /// for. Used at launch, when a reinstalled app has an account but no data.
    func syncKnownCircles() async {
        guard let engine, isSignedIn else { return }
        do {
            for membership in try await engine.supabase.memberships()
            where CircleKeychain.key(for: membership.circleID) != nil {
                await sync(circleID: membership.circleID)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func sync(circleID: UUID) async {
        guard let engine else { return }
        guard isSyncing(circleID: circleID) else { return }
        guard !status.isBusy else { return }

        status = .syncing
        do {
            let outcome = try await engine.synchronize(circleID: circleID)
            lastOutcome = outcome
            status = .upToDate(.now)
            lastError = nil
            if outcome.conflicts > 0 {
                logger.notice("Sync kept this device's version of \(outcome.conflicts, privacy: .public) record(s).")
            }
        } catch let error as SyncTransportError where error.isTransient {
            status = .offline(error.localizedDescription)
        } catch let error as SyncError {
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        } catch {
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }
}
