import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct GrandOpeningView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncCoordinator.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isComplete: Bool
    @State private var page = 0
    @State private var myName = ""
    @State private var isImporting = false
    @State private var beliSelection: BeliImportSelection?
    @State private var isImportingBackup = false
    @State private var isShowingBackupRestoreConfirmation = false
    @State private var isProcessingImport = false
    @State private var importedCount = 0
    @State private var restoredBackup = false
    @State private var importMessage: String?
    @State private var importMessageIsError = false
    @State private var seedNames = ["", "", ""]
    @State private var seedReactions: [Reaction] = [.loved, .liked, .fine]
    @State private var calibrationPairs: [ComparisonQuestion] = []
    @State private var calibrationIndex = 0
    @State private var openingAnchorAnswered = false
    @State private var isJoining = false
    @State private var isSigningIn = false
    @State private var signInError: String?

    var body: some View {
        ZStack {
            PaperBackground()
            // Button-driven paging only: swiping ahead could reach data-creating
            // pages before the circle exists, orphaning imported records.
            Group {
                switch page {
                case 0: welcome
                case 1: people
                case 2: importPage
                case 3: calibration
                default: ready
                }
            }
            .id(page)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: page)
        .tint(BBTheme.oxblood)
        .safeAreaInset(edge: .top, spacing: 0) {
            if (1...3).contains(page) { onboardingProgress }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): beliSelection = .init(url: url)
            case .failure(let error): importMessageIsError = true; importMessage = error.localizedDescription
            }
        }
        .sheet(item: $beliSelection) { selection in
            BeliImportView(selection: selection) { summary in
                importedCount = summary.outingsCreated + summary.outingsLinked
                restoredBackup = false
                importMessageIsError = false
                importMessage = "Imported \(summary.outingsCreated) new outings and \(summary.photosAdded) photos from Beli."
            }
        }
        .sheet(isPresented: $isJoining) {
            JoinCircleView(onJoined: { isComplete = true })
        }
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.restaurantLogBackup]) { result in
            importBackup(result)
        }
        .editorialPrompt(isPresented: $isShowingBackupRestoreConfirmation) {
            EditorialPrompt.destructive(
                "Restore from backup?",
                message: "The selected backup will replace every current dining log on this iPhone. Export anything you may need before continuing.",
                actionTitle: "Choose backup and replace everything",
                cancelTitle: "Cancel"
            ) {
                isImportingBackup = true
            }
        }
    }

    private var onboardingProgress: some View {
        VStack(spacing: 8) {
            HStack {
                Text("SETUP")
                Spacer()
                Text("STEP \(page) OF 3")
            }
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            ProgressView(value: Double(page), total: 3)
                .tint(BBTheme.oxblood)
        }
        .padding(.horizontal, BBTheme.Spacing.page)
        .padding(.vertical, 10)
        .background(BBTheme.paper.opacity(0.96))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Setup step \(page) of 3")
    }

    /// Idempotent: creates the circle from the entered names if it does not exist yet.
    private func ensureCircle() {
        if store.activeCircle == nil { store.bootstrap(myName: myName) }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Spacer(minLength: 60)
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(BBTheme.oxbloodFill)
                        .frame(width: 64, height: 64)
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(BBTheme.cream)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Your dining log")
                    Text("Big Beautiful Restaurant Log")
                        .font(BBTheme.display(48)).minimumScaleFactor(0.62).lineSpacing(-3)
                    Text("Keep track of where you’ve eaten and where you’d go back.")
                        .font(.title3).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        principle("bolt.fill", "Quick to log", "A restaurant and a reaction")
                        principle("lock.fill", "Private", "Encrypted end to end")
                        principle("list.number", "Your ranking", "Built from your reactions")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        principle("bolt.fill", "Quick to log", "A restaurant and a reaction")
                        principle("lock.fill", "Private", "Encrypted end to end")
                        principle("list.number", "Your ranking", "Built from your reactions")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Get started") { page = 1 }
                    .buttonStyle(PrimaryButtonStyle())
                Text("No ads, no feed, no public profile. Only you can read your log.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 30)
            }
            .padding(24).readablePageWidth()
        }
        .scrollIndicators(.hidden)
    }

    private var people: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeading(
                    number: "01",
                    title: "Your name",
                    detail: "Your name goes on the outings you log. You can add the people you dine with later."
                )
                VStack(spacing: 0) {
                    editorialField("Your name", text: $myName)
                }
                .editorialCard(padding: 0)
                if nameIsEmpty {
                    Label("Enter your name above to continue.", systemImage: "info.circle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Name required. Enter your name above to continue.")
                        .accessibilityIdentifier("onboarding-name-required")
                }
                if sync.isConfigured {
                    signInStep
                } else {
                    Button("Continue") { continueFromName() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(nameIsEmpty)
                        .accessibilityHint(nameIsEmpty ? "Enter your name above to continue" : "Continues to import options")
                }
                if sync.isConfigured {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Someone already using this app?").font(.callout.weight(.semibold))
                        Text(CircleJoinDisclosure(store: store).onboardingDisclosure)
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Join with a code") {
                            store.bootstrap(myName: myName)
                            isJoining = true
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(nameIsEmpty || isSigningIn)
                        .accessibilityHint(nameIsEmpty ? "Enter your name above to continue" : "Opens the invitation code form")
                    }
                    .editorialCard()
                }
            }
            .padding(24).padding(.bottom, 12).readablePageWidth()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Signing in protects the log across devices and enables encrypted sharing,
    /// but a person can continue locally and sign in later from Settings.
    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Back up your log")
            Text("Sign in to keep your log")
                .font(.headline)
            Text("Signing in encrypts your log on this iPhone and keeps a copy safe if you lose your phone. It also lets you share your log with a circle.")
                .font(.callout).foregroundStyle(.secondary)
            Button {
                signInAndContinue()
            } label: {
                if isSigningIn {
                    HStack { ProgressView(); Text("Signing in…") }.frame(maxWidth: .infinity)
                } else {
                    Label("Sign in with Apple", systemImage: "apple.logo").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(nameIsEmpty || isSigningIn)
            .accessibilityIdentifier("onboarding-sign-in-button")
            .accessibilityHint(nameIsEmpty ? "Enter your name above to continue" : "Signs in, then continues to import options")
            if let signInError {
                Text(signInError).font(.caption).foregroundStyle(BBTheme.oxblood)
            }
            Button("Continue without signing in") { continueFromName() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(nameIsEmpty)
                .accessibilityHint(nameIsEmpty ? "Enter your name above to continue" : "Keeps this log on this iPhone and continues")
            Text("Your log stays on this iPhone until you sign in from Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .editorialCard()
    }

    private func continueFromName() {
        store.bootstrap(myName: myName)
        page = 2
    }

    private func signInAndContinue() {
        isSigningIn = true
        signInError = nil
        Task {
            defer { isSigningIn = false }
            if await sync.signInWithApple() {
                continueFromName()
            } else {
                signInError = sync.lastError
                    ?? "Sign in did not complete. Try again, or continue and sign in later from Settings."
            }
        }
    }

    private var nameIsEmpty: Bool {
        myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var importPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading(number: "02", title: "Bring your history", detail: "Restore a backup, import a Beli export, or start fresh.")
                VStack(spacing: 0) {
                    Button { isShowingBackupRestoreConfirmation = true } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(
                                isProcessingImport ? "Importing…" : "Restore a full backup",
                                systemImage: isProcessingImport ? "hourglass" : "arrow.down.doc"
                            )
                            .font(.headline)
                            Text("Restores every reaction, ranking, dish, and photo.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessingImport)
                    Divider()
                    Button { isImporting = true } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Import a Beli ZIP export", systemImage: "archivebox")
                                .font(.headline)
                            Text("Review the restaurant matches. Your rank order stays intact, and your photos are downloaded.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessingImport)
                }
                .editorialCard(padding: 0)
                if let importMessage {
                    Label(importMessage, systemImage: importMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.callout).foregroundStyle(importMessageIsError ? BBTheme.oxblood : BBTheme.sage)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Files are processed on this device", systemImage: "lock.shield")
                    Text("Your file is left unchanged. Restored records stay on this iPhone unless you have syncing turned on.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .editorialCard()
                Spacer(minLength: 12)
                HStack {
                    Button("Back") { page = 1 }.buttonStyle(.borderless)
                    Spacer()
                    Button(restoredBackup ? "Backup restored. Continue" : (importedCount > 0 ? "Imported \(importedCount). Continue" : "Continue without importing")) { page = 3 }
                        .font(.headline)
                        .disabled(isProcessingImport)
                }
                .frame(minHeight: 50)
            }
            .padding(24).padding(.bottom, 12).readablePageWidth()
        }
    }

    private var ready: some View {
        ScrollView {
                VStack(spacing: 25) {
                Spacer(minLength: 60)
                ZStack {
                    Circle().stroke(BBTheme.oxblood.opacity(0.18), lineWidth: 1).frame(width: 150, height: 150)
                    Circle().fill(BBTheme.oxblood.opacity(0.08)).frame(width: 112, height: 112)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(BBTheme.oxblood)
                }
                Eyebrow("Setup complete")
                Text("Your restaurant log is ready.").font(BBTheme.display(36)).multilineTextAlignment(.center)
                Text("Pick a restaurant and a reaction. Details and comparisons can come later.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                Button("Open restaurant log") { finish(useSample: false) }.buttonStyle(PrimaryButtonStyle())
                if store.locations.isEmpty {
                    Button("Preview with a sample Salt Lake log") { finish(useSample: true) }
                        .font(.callout.weight(.semibold))
                }
                Button("Back") { page = 3 }.buttonStyle(.borderless)
                Spacer(minLength: 30)
            }
            .padding(24).readablePageWidth()
        }
    }

    private var calibration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading(number: "03", title: "Your first ranking", detail: "Add a few restaurants you know, then answer as many comparisons as you like.")
                if store.locations.count < 2 {
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow("Quick add")
                        Text("Name up to three restaurants you know.").font(BBTheme.display(24))
                        ForEach(seedNames.indices, id: \.self) { index in
                            HStack(spacing: 12) {
                                TextField("Restaurant \(index + 1)", text: $seedNames[index])
                                    .textInputAutocapitalization(.words)
                                Picker("Reaction", selection: $seedReactions[index]) {
                                    ForEach(Reaction.allCases) { Label($0.compactTitle, systemImage: $0.symbol).tag($0) }
                                }
                                .pickerStyle(.menu)
                            }
                            .frame(minHeight: 52)
                            .padding(.vertical, 4)
                            if index < seedNames.count - 1 { Divider() }
                        }
                        Button("Add restaurants") { seedQuickPlaces() }.buttonStyle(PrimaryButtonStyle())
                    }.editorialCard()
                } else if calibrationPairs.isEmpty, !openingAnchorAnswered, let location = pendingOpeningAnchorLocation {
                    VStack(spacing: 12) {
                        Eyebrow("Settle the Score")
                        Text("Which statement best fits \(location.name)?").font(BBTheme.display(27)).multilineTextAlignment(.center)
                        Text("Pick the one that comes closest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        ForEach(ScoreAnchor.ladder) { anchor in
                            Button {
                                store.recordAnchor(for: location, value: anchor.score)
                                openingAnchorAnswered = true
                            } label: {
                                HStack(alignment: .firstTextBaseline) { Text(anchor.score.formatted(.number.precision(.fractionLength(0)))).font(BBTheme.score(21)).frame(width: 34, alignment: .leading); Text(anchor.statement).font(.callout); Spacer() }
                                    .padding(12).frame(maxWidth: .infinity).background(BBTheme.ink.opacity(0.05)).overlay(Rectangle().stroke(BBTheme.hairline))
                            }.buttonStyle(.plain)
                        }
                    }.editorialCard()
                } else if calibrationIndex < calibrationPairs.count {
                    let question = calibrationPairs[calibrationIndex]
                    VStack(spacing: 15) {
                        Eyebrow("Comparison \(calibrationIndex + 1) of \(calibrationPairs.count)")
                        Text("Which would you rather go back to?").font(BBTheme.display(27)).multilineTextAlignment(.center)
                        calibrationChoice(question.a, outcome: .a, question: question)
                        Text("OR").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                        calibrationChoice(question.b, outcome: .b, question: question)
                        Button("Too close to call") { answerCalibration(.tie, question: question) }
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .buttonStyle(.plain)
                            .accessibilityHint("Records these restaurants as roughly even")
                        Button("Skip") { calibrationIndex += 1 }.frame(minHeight: 44)
                    }.editorialCard()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 38, weight: .light)).foregroundStyle(BBTheme.oxblood)
                        Text("Your first ranking is ready.").font(BBTheme.display(27))
                        Text("You can compare restaurants anytime from the Settle tab.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).editorialCard()
                }
                HStack {
                    Button("Back") { page = 2 }
                    Spacer()
                    Button("Continue") { page = 4 }.font(.headline)
                }.frame(minHeight: 50)
            }.padding(24).readablePageWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { prepareCalibration() }
    }

    private func pageHeading(number: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow("Step \(number)")
            Text(title)
                .font(BBTheme.display(39))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
                .accessibilityIdentifier("onboarding-step-detail")
        }
        .padding(.top, 24)
    }

    private func principle(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.bold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        // Keep the horizontal variant honest: on compact screens each principle
        // needs enough room to remain readable, so ViewThatFits chooses the
        // full-width vertical layout instead of compressing three narrow columns.
        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
    }

    private func editorialField(_ title: String, text: Binding<String>, prompt: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(BBTheme.eyebrow).foregroundStyle(.secondary)
            TextField(prompt ?? title, text: text).font(BBTheme.display(25, weight: .regular)).textInputAutocapitalization(.words)
        }
        .padding(18).frame(minHeight: 84)
    }

    private func importBackup(_ result: Result<URL, Error>) {
        Task { await processBackupImport(result) }
    }

    private func processBackupImport(_ result: Result<URL, Error>) async {
        isProcessingImport = true
        importMessage = nil
        importMessageIsError = false
        defer { isProcessingImport = false }

        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let archive = try await Task.detached(priority: .userInitiated) {
                let data = try AppBackupCodec.readBackupData(from: url)
                return try AppBackupCodec.decode(data)
            }.value
            try Task.checkCancellation()

            var liveEnrollment: (circleID: UUID, circleName: String, personID: UUID, personName: String)?
            if sync.isConfigured, sync.isSignedIn, let circle = store.activeCircle {
                if let membership = try await sync.authenticatedMembership(circleID: circle.id) {
                    guard sync.hasKey(circleID: circle.id) else { throw SyncError.circleKeyMissing }
                    liveEnrollment = (
                        circle.id,
                        circle.name,
                        membership.personID,
                        store.person(id: membership.personID)?.name ?? store.currentPerson?.name ?? "Me"
                    )
                }
                await sync.prepareForBackupRestore(circleID: circle.id)
            }

            let commitHandler = store.didCommit
            store.didCommit = nil
            defer { store.didCommit = commitHandler }
            let summary = try await AppBackupService.restore(archive, into: store)
            if let liveEnrollment {
                guard store.reconnectRestoredLog(
                    to: liveEnrollment.circleID,
                    circleName: liveEnrollment.circleName,
                    memberPersonID: liveEnrollment.personID,
                    fallbackPersonName: liveEnrollment.personName
                ) else {
                    throw SyncError.deviceIdentityMissing
                }
            }
            if sync.isConfigured, sync.isSignedIn,
               let circle = store.activeCircle, let personID = store.currentPerson?.id {
                let activation = await sync.activate(circleID: circle.id, name: circle.name, personID: personID)
                guard case let .ready(serverPersonID) = activation, serverPersonID == personID else {
                    throw SyncError.deviceIdentityMissing
                }
            }
            importedCount = summary.visits
            restoredBackup = true
            importMessage = "Restored \(summary.visits) outings, \(summary.locations) restaurants, and \(summary.photos) photos."
            Haptics.success()
        } catch {
            importMessageIsError = true
            importMessage = error.localizedDescription
        }
    }

    private func finish(useSample: Bool) {
        if store.activeCircle == nil { store.bootstrap(myName: myName) }
        if useSample { store.seedSampleLog() }
        Haptics.success()
        isComplete = true
    }

    private func seedQuickPlaces() {
        ensureCircle()
        store.performBatch {
            for index in seedNames.indices {
                let name = seedNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                store.seedFamiliarRestaurant(name: name, reaction: seedReactions[index])
            }
        }
        prepareCalibration()
    }

    private func prepareCalibration() {
        guard calibrationPairs.isEmpty else { return }
        calibrationPairs = store.settleQuestions(limit: 3)
    }

    private var pendingOpeningAnchorLocation: RestaurantLocation? {
        store.settleScorePrompts(limit: 1).compactMap { prompt in
            if case .anchor(let location) = prompt { return location }
            return nil
        }.first
    }

    private func calibrationChoice(_ location: RestaurantLocation, outcome: ComparisonOutcome, question: ComparisonQuestion) -> some View {
        Button { answerCalibration(outcome, question: question) } label: {
            HStack(spacing: 12) {
                Image(systemName: location.category.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(location.name)
                        .font(BBTheme.display(21))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(location.category.shortTitle)
                        .font(.caption)
                        .foregroundStyle(BBTheme.cream.opacity(0.72))
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .foregroundStyle(BBTheme.cream)
            .background(BBTheme.oxbloodFill, in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(location.name), \(location.category.shortTitle)")
    }

    private func answerCalibration(_ outcome: ComparisonOutcome, question: ComparisonQuestion) {
        store.recordComparison(a: question.a, b: question.b, outcome: outcome)
        calibrationIndex += 1
        Haptics.selection()
    }
}
