import SwiftUI

@MainActor
struct MainTabView: View {
    @Environment(AppStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @State private var router = AppRouter()
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
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
        .environment(router)
        .sheet(item: $router.sheet) { sheet in
            sheetView(sheet)
                .environment(router)
                .environment(store)
                .environment(locationService)
                .presentationBackground(BBTheme.paper)
        }
        .onChange(of: router.selectedTab) { _, _ in Haptics.selection(enabled: hapticsEnabled) }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .ledger: HomeView()
        case .rankings: RankingsView()
        case .history: HistoryView()
        case .want: WantToTryView()
        case .more: MoreView()
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .logMeal: LogMealFlow()
        case .rateVisit(let id):
            if let visit = store.visits.first(where: { $0.id == id }) { SharedVisitRatingView(visit: visit) }
        case .addWant: AddWantView()
        case .compare(let id):
            if let location = store.locations.first(where: { $0.id == id }) { DirectComparisonView(source: location) }
        case .shareCircle: CircleSharingView()
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
        case .location(let id):
            if let location = store.locations.first(where: { $0.id == id }) { EstablishmentDetailView(location: location) }
            else { ContentUnavailableView("Place not found", systemImage: "mappin.slash") }
        case .visit(let id):
            if let visit = store.visits.first(where: { $0.id == id }) { VisitDetailView(visit: visit) }
            else { ContentUnavailableView("Visit not found", systemImage: "calendar.badge.exclamationmark") }
        case .stats: StatsView()
        case .settleScore: SettleScoreView()
        case .backfill: BackfillView()
        case .settings: SettingsView()
        case .merge: MergeLocationsView()
        }
    }
}
