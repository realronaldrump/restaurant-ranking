import SwiftUI

@main
@MainActor
struct RestaurantLogApp: App {
    private static var hasSeededSampleData = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore?
    @State private var sync: SyncCoordinator?
    @State private var pendingInvitation: CircleInvitation?
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
        if let invitation = CircleInvitation(url: url) {
            pendingInvitation = invitation
        }
    }

    @ViewBuilder
    private func loadedContent(_ store: AppStore, _ sync: SyncCoordinator) -> some View {
        Group {
            if didCompleteGrandOpening, store.activeCircle != nil {
                MainTabView()
            } else {
                GrandOpeningView(isComplete: $didCompleteGrandOpening)
            }
        }
        .environment(store)
        .environment(sync)
        .environment(locationService)
        .sheet(item: $pendingInvitation) { invitation in
            JoinCircleView(invitation: invitation) {
                didCompleteGrandOpening = true
                pendingInvitation = nil
            }
            .environment(store)
            .environment(sync)
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
