import Observation
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case ledger = "Ledger"
    case rankings = "Rankings"
    case history = "History"
    case want = "Want to Try"
    case more = "More"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .ledger: "book.closed.fill"
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
    case stats
    case settleScore
    case backfill
    case settings
    case merge
}

enum AppSheet: Identifiable, Hashable {
    case logMeal
    case rateVisit(UUID)
    case addWant
    case compare(UUID)
    case shareCircle

    var id: String {
        switch self {
        case .logMeal: "log"
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
    var selectedTab: AppTab = .ledger
    var sheet: AppSheet?
    var ledgerPath: [AppRoute] = []
    var rankingPath: [AppRoute] = []
    var historyPath: [AppRoute] = []
    var wantPath: [AppRoute] = []
    var morePath: [AppRoute] = []

    func pathBinding(for tab: AppTab) -> Binding<[AppRoute]> {
        switch tab {
        case .ledger: Binding(get: { self.ledgerPath }, set: { self.ledgerPath = $0 })
        case .rankings: Binding(get: { self.rankingPath }, set: { self.rankingPath = $0 })
        case .history: Binding(get: { self.historyPath }, set: { self.historyPath = $0 })
        case .want: Binding(get: { self.wantPath }, set: { self.wantPath = $0 })
        case .more: Binding(get: { self.morePath }, set: { self.morePath = $0 })
        }
    }
}
