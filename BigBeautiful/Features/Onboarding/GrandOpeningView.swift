import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct GrandOpeningView: View {
    @Environment(AppStore.self) private var store
    @Binding var isComplete: Bool
    @State private var page = 0
    @State private var myName = ""
    @State private var partnerName = ""
    @State private var circleName = ""
    @State private var isImporting = false
    @State private var isProcessingImport = false
    @State private var importedCount = 0
    @State private var importMessage: String?
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
        .animation(.easeInOut(duration: 0.35), value: page)
        .tint(BBTheme.oxblood)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            importCSV(result)
        }
    }

    /// Idempotent: creates the circle from the entered names if it does not exist yet.
    private func ensureCircle() {
        if store.activeCircle == nil { store.bootstrap(myName: myName, partnerName: partnerName, circleName: circleName) }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Spacer(minLength: 60)
                Image(systemName: "book.closed.fill").font(.title2).foregroundStyle(BBTheme.oxblood)
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Welcome")
                    Text("Big Beautiful Restaurant Log")
                        .font(BBTheme.display(48)).minimumScaleFactor(0.62).lineSpacing(-3)
                    Text("Keep track of where you’ve eaten and where you’d go back.")
                        .font(.title3).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        principle("Fast logging", "Place and reaction")
                        principle("Private by default", "Stored in iCloud")
                        principle("Personal rankings", "Built from your choices")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        principle("Fast logging", "Place and reaction")
                        principle("Private by default", "Stored in iCloud")
                        principle("Personal rankings", "Built from your choices")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Get Started") { page = 1 }
                    .buttonStyle(PrimaryButtonStyle())
                Text("Best restaurant logger in the world!")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer(minLength: 30)
            }
            .padding(24).readablePageWidth()
        }
    }

    private var people: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeading(number: "01", title: "Who’s at the table?", detail: "Rankings stay personal. Shared visits appear for everyone in your circle.")
                VStack(spacing: 0) {
                    editorialField("Your name", text: $myName)
                    Divider()
                    editorialField("Partner (optional)", text: $partnerName)
                    Divider()
                    editorialField("Circle name", text: $circleName, prompt: "Our Table")
                }
                .ledgerCard(padding: 0)
                Spacer(minLength: 12)
                Button("Continue") {
                    store.bootstrap(myName: myName, partnerName: partnerName, circleName: circleName)
                    page = 2
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(24).padding(.bottom, 12).readablePageWidth()
        }
    }

    private var importPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading(number: "02", title: "Import past visits", detail: "Choose a Beli-style CSV, or skip this step. We can import place, date, score, cuisine, dish, and note columns.")
                Button { isImporting = true } label: {
                    Label(
                        isProcessingImport ? "Importing…" : "Choose a CSV",
                        systemImage: isProcessingImport ? "hourglass" : "tablecells.badge.ellipsis"
                    )
                        .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                .buttonStyle(.plain)
                .disabled(isProcessingImport)
                .ledgerCard(padding: 0)
                if let importMessage {
                    Label(importMessage, systemImage: importedCount > 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(importedCount > 0 ? BBTheme.sage : BBTheme.oxblood)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Import stays on this device", systemImage: "lock.shield")
                    Text("The file is processed locally and left unchanged. You can also add older visits from photos later.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .ledgerCard()
                Spacer(minLength: 12)
                HStack {
                    Button("Back") { page = 1 }.buttonStyle(.borderless)
                    Spacer()
                    Button(importedCount > 0 ? "Imported \(importedCount). Continue" : "Continue without import") { page = 3 }
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
                    Text("100").font(BBTheme.score(66)).foregroundStyle(BBTheme.oxblood)
                }
                Eyebrow("Setup complete")
                Text("Your restaurant log is ready.").font(BBTheme.display(36)).multilineTextAlignment(.center)
                Text("Log a place and choose a reaction. You can add details or compare places later.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                Button("Open Restaurant Log") { finish(useSample: false) }.buttonStyle(PrimaryButtonStyle())
                if store.locations.isEmpty {
                    Button("Preview with a sample Salt Lake ledger") { finish(useSample: true) }
                        .font(.callout.weight(.semibold))
                }
                Button("Back") { page = 2 }.buttonStyle(.borderless)
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
                            VStack(spacing: 8) {
                                TextField("Establishment \(index + 1)", text: $seedNames[index]).textInputAutocapitalization(.words)
                                Picker("Reaction", selection: $seedReactions[index]) { ForEach(Reaction.allCases) { Text($0.compactTitle).tag($0) } }.pickerStyle(.segmented)
                            }.padding(.vertical, 7)
                            if index < seedNames.count - 1 { Divider() }
                        }
                        Button("Add Places") { seedQuickPlaces() }.buttonStyle(PrimaryButtonStyle())
                    }.ledgerCard()
                } else if calibrationPairs.isEmpty, !openingAnchorAnswered, let location = store.ranked().first?.location {
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
                    }.ledgerCard()
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
                    }.ledgerCard()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 38, weight: .light)).foregroundStyle(BBTheme.oxblood)
                        Text("Your first ranking is ready.").font(BBTheme.display(27))
                        Text("You can compare places anytime from More.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).ledgerCard()
                }
                HStack {
                    Button("Back") { page = 2 }
                    Spacer()
                    Button("Continue") { page = 4 }.font(.headline)
                }.frame(minHeight: 50)
            }.padding(24).readablePageWidth()
        }
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
        .padding(.top, 46)
    }

    private func principle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.bold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 130, alignment: .leading)
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

    private func processCSVImport(_ result: Result<URL, Error>) async {
        isProcessingImport = true
        importMessage = nil
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
            importMessage = summary.skippedRows > 0
                ? "Imported \(summary.meals.count) visits. \(summary.skippedRows) incomplete rows were skipped."
                : "Imported \(summary.meals.count) visits."
        } catch { importMessage = error.localizedDescription }
    }

    private func finish(useSample: Bool) {
        if store.activeCircle == nil { store.bootstrap(myName: myName, partnerName: partnerName, circleName: circleName) }
        if useSample { store.seedSampleLedger() }
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
        var pairs: [ComparisonQuestion] = []
        for category in DiningCategory.allCases {
            let values = store.ranked().filter { $0.location.category == category }
            for pair in zip(values, values.dropFirst()) where pairs.count < 3 {
                pairs.append(.init(a: pair.0.location, b: pair.1.location))
            }
        }
        calibrationPairs = pairs
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
