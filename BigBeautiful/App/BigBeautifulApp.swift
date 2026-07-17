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
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-seedSampleData") {
                    store.seedSampleLedger()
                    didCompleteGrandOpening = true
                }
            }
        }
    }
}
