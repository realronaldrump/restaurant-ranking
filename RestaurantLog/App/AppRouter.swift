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
    case settle = "Settle"
    case more = "More"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .log: "book.closed.fill"
        case .rankings: "list.number"
        case .history: "clock.arrow.circlepath"
        case .settle: "scale.3d"
        case .more: "ellipsis.circle.fill"
        }
    }
}

enum RankingScope: Hashable {
    case person(UUID)
    case circle
}

enum AppRoute: Hashable {
    case location(UUID, rankingScope: RankingScope? = nil)
    case comparisonHistory(UUID, rankingScope: RankingScope)
    case visit(UUID)
    case atlas
    case stats
    case statsDetail(StatsDrilldown)
    case notifications
    case settleScore
    case wantToTry
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
    case circle

    var id: String {
        switch self {
        case .logMeal: "log"
        case .logMealAt(let id): "log-at-\(id)"
        case .rateVisit(let id): "rate-\(id)"
        case .addWant: "want"
        case .compare(let id): "compare-\(id)"
        case .circle: "circle"
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
    var settlePath: [AppRoute] = []
    var morePath: [AppRoute] = []

    /// An invitation waiting to be accepted.
    ///
    /// This is presentation state rather than a command: the invitation sheet
    /// is bound straight to this value, so a link that arrives while the app is
    /// still opening its database is shown the moment the interface exists.
    /// The previous design pushed a sheet at whatever was on screen at the
    /// time, which is how a cold-start invitation could open the app and then
    /// appear to do nothing at all.
    var pendingInvitation: CircleInvitation?
    @ObservationIgnored private let invitationPersistence: any InvitationPersistence

    init(invitationPersistence: any InvitationPersistence = KeychainInvitationPersistence()) {
        self.invitationPersistence = invitationPersistence
    }

    @discardableResult
    func receiveInvitation(_ url: URL) -> Bool {
        guard let invitation = CircleInvitation(url: url) else { return false }
        receiveInvitation(invitation)
        return true
    }

    func receiveInvitation(_ invitation: CircleInvitation) {
        do {
            try invitationPersistence.store(invitation)
        } catch {
            // The in-memory handoff can still succeed during this launch. A
            // Keychain failure must not make a valid invitation look dead.
        }
        // Only one sheet can be presented at a time, and an invitation is more
        // urgent than whatever was being edited.
        sheet = nil
        pendingInvitation = invitation
    }

    func restorePendingInvitation() {
        guard pendingInvitation == nil, let invitation = invitationPersistence.pendingInvitation else { return }
        pendingInvitation = invitation
    }

    func completeInvitation(_ invitation: CircleInvitation) {
        guard pendingInvitation == invitation else { return }
        pendingInvitation = nil
        invitationPersistence.remove()
    }

    func discardInvitation(_ invitation: CircleInvitation) {
        completeInvitation(invitation)
    }

    func pathBinding(for tab: AppTab) -> Binding<[AppRoute]> {
        switch tab {
        case .log: Binding(get: { self.logPath }, set: { self.logPath = $0 })
        case .rankings: Binding(get: { self.rankingPath }, set: { self.rankingPath = $0 })
        case .history: Binding(get: { self.historyPath }, set: { self.historyPath = $0 })
        case .settle: Binding(get: { self.settlePath }, set: { self.settlePath = $0 })
        case .more: Binding(get: { self.morePath }, set: { self.morePath = $0 })
        }
    }

    func resetPath(for tab: AppTab) {
        switch tab {
        case .log: logPath.removeAll()
        case .rankings: rankingPath.removeAll()
        case .history: historyPath.removeAll()
        case .settle: settlePath.removeAll()
        case .more: morePath.removeAll()
        }
    }

    /// Removes a deleted restaurant and anything presented from its detail
    /// screen from every tab's retained navigation stack.
    func removeRoutes(toDeletedRestaurant restaurantID: UUID) {
        logPath = trimmingDeletedRestaurant(restaurantID, from: logPath)
        rankingPath = trimmingDeletedRestaurant(restaurantID, from: rankingPath)
        historyPath = trimmingDeletedRestaurant(restaurantID, from: historyPath)
        settlePath = trimmingDeletedRestaurant(restaurantID, from: settlePath)
        morePath = trimmingDeletedRestaurant(restaurantID, from: morePath)
    }

    private func trimmingDeletedRestaurant(_ restaurantID: UUID, from path: [AppRoute]) -> [AppRoute] {
        guard let index = path.firstIndex(where: { route in
            switch route {
            case .location(let routeID, _), .comparisonHistory(let routeID, _):
                return routeID == restaurantID
            default:
                return false
            }
        }) else { return path }
        return Array(path[..<index])
    }
}
