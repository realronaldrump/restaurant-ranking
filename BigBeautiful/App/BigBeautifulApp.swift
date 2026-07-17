import SwiftUI

@main
@MainActor
struct BigBeautifulApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @State private var locationService = LocationService()
    @AppStorage("didCompleteGrandOpening") private var didCompleteGrandOpening = false

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
