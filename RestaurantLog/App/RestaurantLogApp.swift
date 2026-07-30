import SwiftUI

@main
@MainActor
struct RestaurantLogApp: App {
    private static var hasSeededSampleData = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore?
    @State private var sync: SyncCoordinator?
    @State private var router = AppRouter()
    @State private var locationService = LocationService()
    @State private var launchMessage = "Opening your restaurant log…"
    @AppStorage("didCompleteGrandOpening") private var didCompleteGrandOpening = false
    @AppStorage(AppearancePreference.storageKey) private var appearancePreference = AppearancePreference.system

    init() {
        // Navigation titles in the editorial serif, matching the page headings.
        if let descriptor = UIFont.preferredFont(forTextStyle: .headline).fontDescriptor.withDesign(.serif) {
            UINavigationBar.appearance().titleTextAttributes = [.font: UIFont(descriptor: descriptor, size: 0)]
        }
        // Segmented controls in Big Beautiful colors rather than system gray.
        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = UIColor(named: "Oxblood")
        segmented.setTitleTextAttributes([.foregroundColor: UIColor(named: "Ink") ?? .label], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: UIColor(named: "Paper") ?? .systemBackground], for: .selected)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let store, let sync {
                    loadedContent(store, sync)
                } else {
                    AppLaunchView(message: launchMessage)
                        .task { await prepareApp() }
                }
            }
            .preferredColorScheme(appearancePreference.colorScheme)
            .onOpenURL { url in
                receiveInvitation(url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                receiveInvitation(url)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, let store, let sync,
                      let circleID = store.activeCircleID else { return }
                Task { await sync.sync(circleID: circleID) }
            }
        }
    }

    private func receiveInvitation(_ url: URL) {
        _ = router.receiveInvitation(url)
    }

    @ViewBuilder
    private func loadedContent(_ store: AppStore, _ sync: SyncCoordinator) -> some View {
        @Bindable var router = router
        Group {
            if didCompleteGrandOpening, store.activeCircle != nil {
                MainTabView()
            } else {
                GrandOpeningView(isComplete: $didCompleteGrandOpening)
            }
        }
        .environment(store)
        .environment(sync)
        .environment(router)
        .environment(locationService)
        .sheet(item: $router.sheet, onDismiss: {
            if let circleID = router.takePendingLocalCircleRemoval() {
                _ = store.removeCircleFromThisDevice(circleID)
            }
        }) { sheet in
            appSheet(sheet, store: store, sync: sync)
                .environment(router)
                .environment(store)
                .environment(sync)
                .environment(locationService)
                .presentationBackground(BBTheme.paper)
                .presentationDragIndicator(.visible)
                .tint(BBTheme.oxblood)
        }
        .fullScreenCover(isPresented: Binding(
            get: { didCompleteGrandOpening && store.needsDeviceIdentity },
            set: { _ in }
        )) {
            DeviceIdentitySelectionView()
                .environment(store)
                .interactiveDismissDisabled()
        }
        .alert("Couldn’t Save or Sync", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearLastError() } }
        )) {
            Button("OK") { store.clearLastError() }
        } message: {
            Text(store.lastError ?? "Big Beautiful Log encountered an unexpected persistence error.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .circleDidArriveFromSync)) { _ in
            // A circle pulled from the sync service is itself completed setup;
            // the identity gate then asks which member uses this device.
            didCompleteGrandOpening = true
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-seedSampleData"), !Self.hasSeededSampleData {
                Self.hasSeededSampleData = true
                store.seedSampleLog()
                didCompleteGrandOpening = true
            }
        }
    }

    @MainActor
    private func prepareApp() async {
        guard store == nil else { return }
        // Let SwiftUI commit the branded launch view before Core Data performs
        // migrations or reconciles an existing dining history.
        await Task.yield()
        let persistence = PersistenceController.shared
        await persistence.prepare()
        let preparedStore = AppStore(persistence: persistence)
        let coordinator = SyncCoordinator(container: persistence.container)
        await coordinator.restoreSession()

        // Every successful save asks for a sync; the coordinator debounces the
        // burst that one logged meal produces.
        preparedStore.didCommit = { [weak coordinator] circleID in
            coordinator?.scheduleSync(circleID: circleID)
        }

        // A fresh installation that already has an account may be waiting on the
        // first pull of an existing circle. Show that rather than empty onboarding.
        if preparedStore.circles.isEmpty, coordinator.isConfigured, coordinator.isSignedIn {
            launchMessage = "Looking for your dining log…"
            await coordinator.syncKnownCircles()
            preparedStore.reload()
        }
        if !preparedStore.circles.isEmpty {
            didCompleteGrandOpening = true
        }
        store = preparedStore
        sync = coordinator
        router.restorePendingInvitation()
    }

    @ViewBuilder
    private func appSheet(_ sheet: AppSheet, store: AppStore, sync: SyncCoordinator) -> some View {
        switch sheet {
        case .logMeal:
            LogMealFlow()
        case .logMealAt(let id):
            LogMealFlow(initialLocationID: id)
        case .rateVisit(let id):
            if let visit = store.visits.first(where: { $0.id == id }) {
                SharedVisitRatingView(visit: visit)
            } else {
                ContentUnavailableView("Visit unavailable", systemImage: "calendar.badge.exclamationmark")
            }
        case .addWant:
            AddWantView()
        case .compare(let id):
            if let location = store.locations.first(where: { $0.id == id }) {
                DirectComparisonView(source: location)
            } else {
                ContentUnavailableView("Place unavailable", systemImage: "mappin.slash")
            }
        case .shareCircle:
            CircleSharingView()
        case .joinCircle(let invitation):
            JoinCircleView(
                invitation: invitation,
                onJoined: {
                    didCompleteGrandOpening = true
                    router.completeInvitation(invitation)
                },
                onDiscard: {
                    router.discardInvitation(invitation)
                }
            )
        }
    }
}

private struct AppLaunchView: View {
    let message: String

    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(BBTheme.oxblood)
                        .frame(width: 64, height: 64)
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(BBTheme.paper)
                }
                VStack(spacing: 6) {
                    Text("Big Beautiful")
                        .font(BBTheme.display(30))
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ProgressView()
                    .tint(BBTheme.oxblood)
            }
            .padding(28)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
            .accessibilityIdentifier("app-launch-progress")
        }
        .foregroundStyle(BBTheme.ink)
    }
}
