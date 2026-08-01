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
    @State private var isOnboardingSessionActive = false
    @AppStorage("didCompleteGrandOpening") private var didCompleteGrandOpening = false
    @AppStorage(AppearancePreference.storageKey) private var appearancePreference = AppearancePreference.system

    init() {
        // Navigation titles in the editorial serif, matching the page headings.
        if let descriptor = UIFont.preferredFont(forTextStyle: .headline).fontDescriptor.withDesign(.serif) {
            UINavigationBar.appearance().titleTextAttributes = [.font: UIFont(descriptor: descriptor, size: 0)]
        }
        // Segmented controls in Big Beautiful colors rather than system gray.
        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.365, green: 0.075, blue: 0.125, alpha: 1)
                : UIColor(red: 0.435, green: 0.114, blue: 0.169, alpha: 1)
        }
        segmented.setTitleTextAttributes([.foregroundColor: UIColor(named: "Ink") ?? .label], for: .normal)
        segmented.setTitleTextAttributes([
            .foregroundColor: UIColor(red: 0.957, green: 0.922, blue: 0.867, alpha: 1)
        ], for: .selected)
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
                guard phase == .active, let store, let sync else { return }
                Task { await connectCircle(store, sync) }
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
            if didCompleteGrandOpening, store.activeCircle != nil, !isOnboardingSessionActive {
                MainTabView()
            } else {
                GrandOpeningView(isComplete: Binding(
                    get: { didCompleteGrandOpening },
                    set: { completed in
                        didCompleteGrandOpening = completed
                        if completed { isOnboardingSessionActive = false }
                    }
                ))
                .onAppear { isOnboardingSessionActive = true }
            }
        }
        .environment(store)
        .environment(sync)
        .environment(router)
        .environment(locationService)
        // An invitation gets its own presenter, bound directly to the pending
        // value. Whether the link arrived during launch, while the app was in
        // the background, or while another sheet was open, it is shown as soon
        // as there is an interface to show it in.
        .sheet(item: $router.pendingInvitation) { invitation in
            JoinCircleView(
                invitation: invitation,
                onJoined: {
                    didCompleteGrandOpening = true
                    isOnboardingSessionActive = false
                    router.completeInvitation(invitation)
                },
                onDiscard: { router.discardInvitation(invitation) }
            )
            .environment(router)
            .environment(store)
            .environment(sync)
            .presentationBackground(BBTheme.paper)
            .presentationDragIndicator(.visible)
            .tint(BBTheme.oxblood)
        }
        .sheet(item: $router.sheet) { sheet in
            appSheet(sheet, store: store, sync: sync)
                .environment(router)
                .environment(store)
                .environment(sync)
                .environment(locationService)
                .presentationBackground(BBTheme.paper)
                .presentationDragIndicator(.visible)
                .tint(BBTheme.oxblood)
        }
        .editorialPrompt(isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearLastError() } }
        )) {
            EditorialPrompt.error(
            "Couldn’t save or sync",
            message: store.lastError ?? "Big Beautiful Restaurant Log encountered an unexpected persistence error.",
                dismissTitle: "OK"
            )
        }
        // Registration follows the log rather than a switch: whenever the
        // circle changes identity — first launch, a join, or leaving a shared
        // circle — it is registered and brought up to date automatically.
        .task(id: "\(store.activeCircleID?.uuidString ?? "none")-\(sync.isSignedIn)-\(sync.circleNeedingFreshIdentity?.uuidString ?? "stable")") {
            await connectCircle(store, sync)
        }
        .onReceive(NotificationCenter.default.publisher(for: .circleDidArriveFromSync)) { _ in
            // A log downloaded from the account is itself completed setup.
            didCompleteGrandOpening = true
        }
    }

    @MainActor
    private func prepareApp() async {
        guard store == nil else { return }
        // Keychain items outlive an app installation, so a test run would
        // otherwise inherit an invitation from an earlier one and open on a
        // sheet nothing in the test asked for.
        if ProcessInfo.processInfo.arguments.contains("-resetForUITests") {
            CircleKeychain.removePendingInvitation()
        }
        // Let SwiftUI commit the branded launch view before Core Data performs
        // migrations or reconciles an existing dining history.
        await Task.yield()
        let persistence = PersistenceController.shared
        await persistence.prepare()
        let preparedStore = AppStore(persistence: persistence)
        // One device, one dining log. Older builds could leave a second circle
        // behind after an invitation, which stranded records where nobody else
        // could see them.
        preparedStore.consolidateCircles()
        // UI-test fixtures must exist before loadedContent chooses its first
        // screen. Seeding from a view onAppear races GrandOpeningView's own
        // appearance callback and can leave onboarding latched over the newly
        // seeded log for the lifetime of the process.
        if ProcessInfo.processInfo.arguments.contains("-seedSampleData"), !Self.hasSeededSampleData {
            Self.hasSeededSampleData = true
            preparedStore.seedSampleLog()
            didCompleteGrandOpening = true
            isOnboardingSessionActive = false
        }
        if ProcessInfo.processInfo.arguments.contains("-seedRankingLayoutStressData") {
            _ = preparedStore.seedFamiliarRestaurant(
                name: "Mi Mexico Family Mexican Restaurant - Glenwood",
                reaction: .liked
            )
        }
        let coordinator = SyncCoordinator(container: persistence.container)
        await coordinator.restoreSession()

        // Every successful save asks for a sync; the coordinator debounces the
        // burst that one logged meal produces.
        preparedStore.didCommit = { [weak coordinator] circleID in
            coordinator?.scheduleSync(circleID: circleID)
        }

        // A fresh installation that already has an account is waiting on the
        // first download of an existing log. Show that rather than empty
        // onboarding, and adopt whichever circle the account belongs to.
        if preparedStore.circles.isEmpty, coordinator.isConfigured, coordinator.isSignedIn {
            launchMessage = "Looking for your dining log…"
            await coordinator.syncKnownCircles()
            preparedStore.reload()
            preparedStore.consolidateCircles()
        }
        if !preparedStore.circles.isEmpty {
            didCompleteGrandOpening = true
        }
        store = preparedStore
        sync = coordinator
        router.restorePendingInvitation()
        await connectCircle(preparedStore, coordinator)
    }

    /// Keeps the one log registered and syncing. There is no switch for this:
    /// being signed in is the whole opt-in.
    @MainActor
    private func connectCircle(_ store: AppStore, _ sync: SyncCoordinator) async {
        guard sync.isConfigured, sync.isSignedIn,
              let circle = store.activeCircle else { return }
        let result = await sync.activate(
            circleID: circle.id,
            name: circle.name,
            personID: store.currentPerson?.id
        )
        switch result {
        case let .ready(personID):
            // This only fills a missing local selection. An established phone
            // identity is never replaced by a roster refresh.
            store.adoptDeviceIdentity(preferring: personID)

        case .needsFreshCircleIdentity:
            // A successful membership query proved this account was removed or
            // the old account/circle was reset. Preserve the entire local log,
            // rotate it to a private identity, and enroll that new identity.
            let retiredID = circle.id
            sync.forget(circleID: retiredID)
            guard let newID = store.startFreshCircleIdentity(),
                  let freshCircle = store.activeCircle,
                  let personID = store.currentPerson?.id else { return }
            _ = await sync.activate(
                circleID: newID,
                name: freshCircle.name,
                personID: personID
            )

        case .failed:
            break
        }
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
                ContentUnavailableView("Outing unavailable", systemImage: "calendar.badge.exclamationmark")
            }
        case .addWant:
            AddWantView()
        case .compare(let id):
            if let location = store.locations.first(where: { $0.id == id }) {
                DirectComparisonView(source: location)
            } else {
                ContentUnavailableView("Restaurant unavailable", systemImage: "mappin.slash")
            }
        case .circle:
            CircleView()
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
                        .fill(BBTheme.oxbloodFill)
                        .frame(width: 64, height: 64)
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(BBTheme.cream)
                }
                VStack(spacing: 6) {
                    Text("Big Beautiful\nRestaurant Log")
                        .font(BBTheme.display(30))
                        .multilineTextAlignment(.center)
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
