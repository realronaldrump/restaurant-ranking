import SwiftUI

@MainActor
struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: tabSelection) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack(path: router.pathBinding(for: tab)) {
                    tabContent(tab)
                        .appDestinations()
                }
                .tabItem { Label(tab.rawValue, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
        .tint(BBTheme.oxblood)
        .toolbarBackground(BBTheme.paper.opacity(0.96), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .environment(router)
        .onChange(of: router.selectedTab) { _, _ in Haptics.selection() }
    }

    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { router.selectedTab },
            set: { newTab in
                if router.selectedTab == newTab {
                    router.resetPath(for: newTab)
                    Haptics.selection()
                } else {
                    router.selectedTab = newTab
                }
            }
        )
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .log: HomeView()
        case .rankings: RankingsView()
        case .history: HistoryView()
        case .settle: SettleScoreView { router.selectedTab = .rankings }
        case .more: MoreView()
        }
    }

}

private extension View {
    func appDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            DestinationView(route: route)
        }
    }
}

private struct DestinationView: View {
    @Environment(AppStore.self) private var store
    let route: AppRoute
    var body: some View {
        switch route {
        case .location(let id, let rankingScope):
            if let location = store.locations.first(where: { $0.id == id }) {
                EstablishmentDetailView(location: location, rankingScope: rankingScope)
            }
            else { ContentUnavailableView("Restaurant not found", systemImage: "mappin.slash") }
        case .visit(let id):
            if let visit = store.visits.first(where: { $0.id == id }) { VisitDetailView(visit: visit) }
            else { ContentUnavailableView("Outing not found", systemImage: "calendar.badge.exclamationmark") }
        case .atlas: DiningAtlasView()
        case .stats: StatsView()
        case .settleScore: SettleScoreView()
        case .wantToTry: WantToTryView()
        case .backfill: BackfillView()
        case .settings: SettingsView()
        case .merge: MergeLocationsView()
        }
    }
}
