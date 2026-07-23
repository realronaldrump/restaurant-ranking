import Observation
import SwiftUI

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

    var id: String {
        switch self {
        case .logMeal: "log"
        case .logMealAt(let id): "log-at-\(id)"
        case .rateVisit(let id): "rate-\(id)"
        case .addWant: "want"
        case .compare(let id): "compare-\(id)"
        case .shareCircle: "share"
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
