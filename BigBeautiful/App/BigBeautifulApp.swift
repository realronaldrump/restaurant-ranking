import SwiftUI

@main
@MainActor
struct BigBeautifulApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @State private var locationService = LocationService()
    @AppStorage("didCompleteGrandOpening") private var didCompleteGrandOpening = false

    init() {
        // Navigation titles in the editorial serif, matching the page headings.
        if let descriptor = UIFont.preferredFont(forTextStyle: .headline).fontDescriptor.withDesign(.serif) {
            UINavigationBar.appearance().titleTextAttributes = [.font: UIFont(descriptor: descriptor, size: 0)]
        }
        // Segmented controls in ledger colors rather than system gray.
        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = UIColor(named: "Oxblood")
        segmented.setTitleTextAttributes([.foregroundColor: UIColor(named: "Ink") ?? .label], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: UIColor(named: "Paper") ?? .systemBackground], for: .selected)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if didCompleteGrandOpening, store.activeCircle != nil {
                    MainTabView()
                } else {
                    GrandOpeningView(isComplete: $didCompleteGrandOpening)
                }
            }
            .environment(store)
            .environment(locationService)
            .preferredColorScheme(nil)
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
                Text(store.lastError ?? "The ledger encountered an unexpected persistence error.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .cloudShareWasAccepted)) { _ in
                // Accepting an invitation is itself setup; once its records arrive,
                // the identity gate will ask which circle member uses this device.
                didCompleteGrandOpening = true
            }
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-seedSampleData") {
                    store.seedSampleLedger()
                    didCompleteGrandOpening = true
                }
            }
        }
    }
}
