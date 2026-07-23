import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct GrandOpeningView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isComplete: Bool
    @State private var page = 0
    @State private var myName = ""
    @State private var circleName = "Our Table"
    @State private var isImporting = false
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
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            importCSV(result)
        }
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.restaurantLogBackup]) { result in
            importBackup(result)
        }
        .confirmationDialog(
            "Restore from backup?",
            isPresented: $isShowingBackupRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Choose Backup and Replace Everything", role: .destructive) {
                isImportingBackup = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected backup will replace every current dining log, including records already restored from iCloud. Export anything you may need before continuing.")
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
        if store.activeCircle == nil { store.bootstrap(myName: myName, circleName: circleName) }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Spacer(minLength: 60)
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(BBTheme.oxblood)
                        .frame(width: 64, height: 64)
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(BBTheme.paper)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Your personal dining ledger")
                    Text("Big Beautiful Restaurant Log")
                        .font(BBTheme.display(48)).minimumScaleFactor(0.62).lineSpacing(-3)
                    Text("Keep track of where you’ve eaten and where you’d go back.")
                        .font(.title3).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        principle("bolt.fill", "Fast logging", "Place and reaction")
                        principle("lock.fill", "Private by default", "Stored in iCloud")
                        principle("list.number", "Personal rankings", "Built from your choices")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        principle("bolt.fill", "Fast logging", "Place and reaction")
                        principle("lock.fill", "Private by default", "Stored in iCloud")
                        principle("list.number", "Personal rankings", "Built from your choices")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Get Started") { page = 1 }
                    .buttonStyle(PrimaryButtonStyle())
                Text("No account, ads, or public profile. Your log is yours.")
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
                pageHeading(number: "01", title: "Make it yours", detail: "Start with your identity. You can add and tag anyone in your circle when you log visits.")
                VStack(spacing: 0) {
                    editorialField("Your name", text: $myName)
                    Divider()
                    editorialField("Circle name", text: $circleName, prompt: "Our Table")
                }
                .editorialCard(padding: 0)
                Spacer(minLength: 12)
                Button("Continue") {
                    store.bootstrap(myName: myName, circleName: circleName)
                    page = 2
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(24).padding(.bottom, 12).readablePageWidth()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var importPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading(number: "02", title: "Bring your history", detail: "Restore a complete Big Beautiful backup, import past visits from a Beli-style CSV, or start fresh.")
                VStack(spacing: 0) {
                    Button { isShowingBackupRestoreConfirmation = true } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(
                                isProcessingImport ? "Importing…" : "Restore a Full Backup",
                                systemImage: isProcessingImport ? "hourglass" : "arrow.down.doc"
                            )
                            .font(.headline)
                            Text("Restores every circle, rating, ranking, dish, and photo.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessingImport)
                    Divider()
                    Button { isImporting = true } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Import a Beli CSV", systemImage: "tablecells.badge.ellipsis")
                                .font(.headline)
                            Text("Imports place, date, score, cuisine, dish, and note columns.")
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
                    Text("The selected file is left unchanged. Restored records return to your private iCloud database when sync is available. Sharing invitations can be recreated afterward.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .editorialCard()
                Spacer(minLength: 12)
                HStack {
                    Button("Back") { page = 1 }.buttonStyle(.borderless)
                    Spacer()
                    Button(restoredBackup ? "Backup restored. Continue" : (importedCount > 0 ? "Imported \(importedCount). Continue" : "Continue without import")) { page = 3 }
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
                Text("Log a place and choose a reaction. You can add details or compare places later.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                Button("Open Restaurant Log") { finish(useSample: false) }.buttonStyle(PrimaryButtonStyle())
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
                pageHeading(number: "03", title: "Set up your first ranking", detail: "Add a few familiar places, then answer as many comparisons as you like.")
                if store.locations.count < 2 {
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow("Quick add")
                        Text("Name up to three places you already know.").font(BBTheme.display(24))
                        ForEach(seedNames.indices, id: \.self) { index in
                            HStack(spacing: 12) {
                                TextField("Establishment \(index + 1)", text: $seedNames[index])
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
                        Button("Add Places") { seedQuickPlaces() }.buttonStyle(PrimaryButtonStyle())
                    }.editorialCard()
                } else if calibrationPairs.isEmpty, !openingAnchorAnswered, let location = pendingOpeningAnchorLocation {
                    VStack(spacing: 12) {
                        Eyebrow("Score check")
                        Text("Which statement best fits \(location.name)?").font(BBTheme.display(27)).multilineTextAlignment(.center)
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
                        Text("Which would you rather revisit tonight?").font(BBTheme.display(27)).multilineTextAlignment(.center)
                        calibrationChoice(question.a, outcome: .a, question: question)
                        Text("OR").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                        calibrationChoice(question.b, outcome: .b, question: question)
                        Button("Too Close to Call") { answerCalibration(.tie, question: question) }.buttonStyle(SecondaryButtonStyle())
                        Button("Skip") { calibrationIndex += 1 }.frame(minHeight: 44)
                    }.editorialCard()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 38, weight: .light)).foregroundStyle(BBTheme.oxblood)
                        Text("Your first ranking is ready.").font(BBTheme.display(27))
                        Text("You can compare places anytime from More.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
        .frame(maxWidth: 180, alignment: .leading)
    }

    private func editorialField(_ title: String, text: Binding<String>, prompt: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(BBTheme.eyebrow).foregroundStyle(.secondary)
            TextField(prompt ?? title, text: text).font(BBTheme.display(25, weight: .regular)).textInputAutocapitalization(.words)
        }
        .padding(18).frame(minHeight: 84)
    }

    private func importCSV(_ result: Result<URL, Error>) {
        Task { await processCSVImport(result) }
    }

    private func importBackup(_ result: Result<URL, Error>) {
        Task { await processBackupImport(result) }
    }

    private func processCSVImport(_ result: Result<URL, Error>) async {
        isProcessingImport = true
        importMessage = nil
        importMessageIsError = false
        defer { isProcessingImport = false }

        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let summary = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return try CSVImporter.parse(data: data)
            }.value
            try Task.checkCancellation()
            ensureCircle()
            store.performBatch {
                for meal in summary.meals {
                    let location = store.createLocation(name: meal.establishment, category: meal.category, address: meal.address, cuisines: meal.cuisines)
                    let visit = store.logVisit(at: location, reaction: meal.reaction, date: meal.date, hazy: meal.hazy)
                    if let memory = meal.memory { store.updateVisit(visit, type: nil, priceBand: 0, occasion: nil, memory: memory, companions: []) }
                    if let dish = meal.dish, let personID = store.currentPerson?.id {
                        _ = store.addDish(name: dish, role: .entree, reaction: meal.reaction ?? .fine, wouldOrderAgain: true, to: visit, personID: personID)
                    }
                }
            }
            importedCount = summary.meals.count
            restoredBackup = false
            importMessage = summary.skippedRows > 0
                ? "Imported \(summary.meals.count) visits. \(summary.skippedRows) incomplete rows were skipped."
                : "Imported \(summary.meals.count) visits."
        } catch {
            importMessageIsError = true
            importMessage = error.localizedDescription
        }
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
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return try AppBackupCodec.decode(data)
            }.value
            try Task.checkCancellation()
            let summary = try await AppBackupService.restore(archive, into: store)
            importedCount = summary.visits
            restoredBackup = true
            importMessage = "Restored \(summary.visits) visits, \(summary.locations) restaurants, and \(summary.photos) photos."
            Haptics.success()
        } catch {
            importMessageIsError = true
            importMessage = error.localizedDescription
        }
    }

    private func finish(useSample: Bool) {
        if store.activeCircle == nil { store.bootstrap(myName: myName, circleName: circleName) }
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
                let location = store.createLocation(name: name, category: DiningCategory.suggested(for: name))
                _ = store.logVisit(at: location, reaction: seedReactions[index], date: .now.addingTimeInterval(Double(-index) * 60))
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
            HStack { Image(systemName: location.category.symbol); Text(location.name).font(BBTheme.display(21)); Spacer(); if let score = store.score(for: location) { Text(score.displayScore).font(BBTheme.score(20)) } }
                .padding(16).foregroundStyle(BBTheme.paper).background(BBTheme.oxblood)
        }.buttonStyle(.pressable)
    }

    private func answerCalibration(_ outcome: ComparisonOutcome, question: ComparisonQuestion) {
        store.recordComparison(a: question.a, b: question.b, outcome: outcome)
        calibrationIndex += 1
        Haptics.selection()
    }
}
