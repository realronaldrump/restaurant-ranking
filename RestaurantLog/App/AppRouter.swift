import Observation
import SwiftUI

protocol InvitationPersistence {
    var pendingInvitation: CircleInvitation? { get }
    func store(_ invitation: CircleInvitation) throws
    func remove()
}

struct KeychainInvitationPersistence: InvitationPersistence {
    var pendingInvitation: CircleInvitation? { CircleKeychain.pendingInvitation }
    func store(_ invitation: CircleInvitation) throws { try CircleKeychain.storePendingInvitation(invitation) }
    func remove() { CircleKeychain.removePendingInvitation() }
}

enum AppTab: String, CaseIterable, Identifiable {
    case log = "Log"
    case rankings = "Rankings"
    case history = "History"
    case want = "Want to Try"
    case more = "More"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .log: "book.closed.fill"
        case .rankings: "list.number"
        case .history: "clock.arrow.circlepath"
        case .want: "bookmark.fill"
        case .more: "ellipsis.circle.fill"
        }
    }
}

enum AppRoute: Hashable {
    case location(UUID)
    case visit(UUID)
    case atlas
    case stats
    case settleScore
    case backfill
    case settings
    case merge
}

enum AppSheet: Identifiable, Hashable {
    case logMeal
    case logMealAt(UUID)
    case rateVisit(UUID)
    case addWant
    case compare(UUID)
    case shareCircle
    case joinCircle(CircleInvitation)

    var id: String {
        switch self {
        case .logMeal: "log"
        case .logMealAt(let id): "log-at-\(id)"
        case .rateVisit(let id): "rate-\(id)"
        case .addWant: "want"
        case .compare(let id): "compare-\(id)"
        case .shareCircle: "share"
        case .joinCircle(let invitation): "join-\(invitation.id)"
        }
    }
}

@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .log
    var sheet: AppSheet?
    var logPath: [AppRoute] = []
    var rankingPath: [AppRoute] = []
    var historyPath: [AppRoute] = []
    var wantPath: [AppRoute] = []
    var morePath: [AppRoute] = []
    private(set) var pendingInvitation: CircleInvitation?
    @ObservationIgnored private var invitationPresentationTask: Task<Void, Never>?
    @ObservationIgnored private let invitationPersistence: any InvitationPersistence
    @ObservationIgnored private var pendingLocalCircleRemovalID: UUID?

    init(invitationPersistence: any InvitationPersistence = KeychainInvitationPersistence()) {
        self.invitationPersistence = invitationPersistence
    }

    @discardableResult
    func receiveInvitation(_ url: URL) -> Bool {
        guard let invitation = CircleInvitation(url: url) else { return false }
        do {
            try invitationPersistence.store(invitation)
        } catch {
            // The in-memory handoff can still succeed during this launch. A
            // Keychain failure must not make a valid universal link look dead.
        }
        presentInvitation(invitation)
        return true
    }

    func restorePendingInvitation() {
        guard let invitation = invitationPersistence.pendingInvitation else { return }
        presentInvitation(invitation)
    }

    func completeInvitation(_ invitation: CircleInvitation) {
        guard pendingInvitation == invitation else { return }
        invitationPresentationTask?.cancel()
        pendingInvitation = nil
        invitationPersistence.remove()
        if case .joinCircle = sheet { sheet = nil }
    }

    func discardInvitation(_ invitation: CircleInvitation) {
        completeInvitation(invitation)
    }

    /// Dismiss circle management before deleting its Core Data graph. SwiftUI
    /// rows in the outgoing sheet may still retain managed objects until the
    /// presentation has completed.
    func dismissCircleManagement(removing circleID: UUID) {
        pendingLocalCircleRemovalID = circleID
        sheet = nil
    }

    func takePendingLocalCircleRemoval() -> UUID? {
        defer { pendingLocalCircleRemovalID = nil }
        return pendingLocalCircleRemovalID
    }

    private func presentInvitation(_ invitation: CircleInvitation) {
        pendingInvitation = invitation
        invitationPresentationTask?.cancel()
        if sheet == nil {
            sheet = .joinCircle(invitation)
            return
        }
        if case .joinCircle = sheet {
            sheet = .joinCircle(invitation)
            return
        }

        // There can only be one SwiftUI sheet presenter. Dismiss an editing or
        // management sheet first, then present the invitation from that same
        // root so a link opened while another sheet is visible is not dropped.
        sheet = nil
        invitationPresentationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, self.pendingInvitation == invitation else { return }
            self.sheet = .joinCircle(invitation)
        }
    }

    func pathBinding(for tab: AppTab) -> Binding<[AppRoute]> {
        switch tab {
        case .log: Binding(get: { self.logPath }, set: { self.logPath = $0 })
        case .rankings: Binding(get: { self.rankingPath }, set: { self.rankingPath = $0 })
        case .history: Binding(get: { self.historyPath }, set: { self.historyPath = $0 })
        case .want: Binding(get: { self.wantPath }, set: { self.wantPath = $0 })
        case .more: Binding(get: { self.morePath }, set: { self.morePath = $0 })
        }
    }

    func resetPath(for tab: AppTab) {
        switch tab {
        case .log: logPath.removeAll()
        case .rankings: rankingPath.removeAll()
        case .history: historyPath.removeAll()
        case .want: wantPath.removeAll()
        case .more: morePath.removeAll()
        }
    }
}
