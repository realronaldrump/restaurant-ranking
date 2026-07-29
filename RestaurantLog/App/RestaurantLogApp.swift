import SwiftUI

@main
@MainActor
struct RestaurantLogApp: App {
    private static var hasSeededSampleData = false
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: AppStore?
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
                if let store {
                    loadedContent(store)
                } else {
                    AppLaunchView(message: launchMessage)
                        .task { await prepareApp() }
                }
            }
            .preferredColorScheme(appearancePreference.colorScheme)
        }
    }

    @ViewBuilder
    private func loadedContent(_ store: AppStore) -> some View {
        Group {
            if didCompleteGrandOpening, store.activeCircle != nil {
                MainTabView()
            } else {
                GrandOpeningView(isComplete: $didCompleteGrandOpening)
            }
        }
        .environment(store)
        .environment(locationService)
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
        .onReceive(NotificationCenter.default.publisher(for: .cloudShareWasAccepted)) { _ in
            // Accepting an invitation is itself setup; once its records arrive,
            // the identity gate will ask which circle member uses this device.
            didCompleteGrandOpening = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudCircleWasRestored)) { _ in
            // A previously accepted share may import after the first local fetch.
            // Treat its first circle as restored setup instead of leaving the
            // device in empty-log onboarding.
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

        // CloudKit imports accepted shares asynchronously after the stores open.
        // Give a fresh installation a short, visible restore window before empty
        // onboarding. Later arrivals are still handled by cloudCircleWasRestored.
        if preparedStore.circles.isEmpty, persistence.isCloudSyncActive {
            launchMessage = "Looking for your iCloud restaurant log…"
            for _ in 0..<10 where preparedStore.circles.isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)
                preparedStore.reload()
            }
        }
        if !preparedStore.circles.isEmpty {
            didCompleteGrandOpening = true
        }
        store = preparedStore
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
