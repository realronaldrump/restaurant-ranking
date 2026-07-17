import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct GrandOpeningView: View {
    @Environment(AppStore.self) private var store
    @Binding var isComplete: Bool
    @State private var page = 0
    @State private var myName = "Davis"
    @State private var partnerName = "Kelsey"
    @State private var circleName = "The Table"
    @State private var isImporting = false
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
            TabView(selection: $page) {
                welcome.tag(0)
                people.tag(1)
                importPage.tag(2)
                calibration.tag(3)
                ready.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.35), value: page)
        }
        .tint(BBTheme.oxblood)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            importCSV(result)
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Spacer(minLength: 60)
                Image(systemName: "star.fill").font(.title2).foregroundStyle(BBTheme.oxblood)
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("The Grand Opening")
                    Text("Davis’s Big Beautiful Restaurant Ranking App")
                        .font(BBTheme.display(48)).minimumScaleFactor(0.62).lineSpacing(-3)
                    Text("A beautifully kept record of everywhere you’ve eaten—and how excited you are to go back.")
                        .font(.title3).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        principle("Three taps", "A complete meal log")
                        principle("Your iCloud", "No account, no server")
                        principle("Living scores", "Evidence, never law")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        principle("Three taps", "A complete meal log")
                        principle("Your iCloud", "No account, no server")
                        principle("Living scores", "Evidence, never law")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { page = 1 } label: {
                    Text("Cut the Ribbon").font(.headline).frame(maxWidth: .infinity).frame(height: 56)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 2))
                Text("No feed. No followers. No guilt. Absolutely no streaks.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer(minLength: 30)
            }
            .padding(24).readablePageWidth()
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeading(number: "01", title: "Who’s at the table?", detail: "Each person keeps an independent ranking. Your shared view is descriptive, never a compromise score.")
            VStack(spacing: 0) {
                editorialField("Your name", text: $myName)
                Divider()
                editorialField("Partner (optional)", text: $partnerName)
                Divider()
                editorialField("Circle name", text: $circleName)
            }
            .ledgerCard(padding: 0)
            Spacer()
            Button("Continue") {
                store.bootstrap(myName: myName, partnerName: partnerName, circleName: circleName)
                page = 2
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(24).readablePageWidth()
    }

    private var importPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            pageHeading(number: "02", title: "Bring the history.", detail: "Import a Beli-style CSV now, or begin clean. The importer recognizes common names for places, dates, scores, cuisines, dishes, and notes.")
            Button { isImporting = true } label: {
                Label("Choose a CSV", systemImage: "tablecells.badge.ellipsis")
                    .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .buttonStyle(.plain).ledgerCard(padding: 0)
            if let importMessage {
                Label(importMessage, systemImage: importedCount > 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(importedCount > 0 ? BBTheme.sage : BBTheme.oxblood)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("Nothing is uploaded", systemImage: "lock.shield")
                Text("Parsing happens on this device. Your originals are unchanged. You can also rebuild history from selected photos with Backfill after opening.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .ledgerCard()
            Spacer()
            HStack {
                Button("Back") { page = 1 }.buttonStyle(.borderless)
                Spacer()
                Button(importedCount > 0 ? "Imported \(importedCount) — Continue" : "Continue without import") { page = 3 }
                    .font(.headline)
            }
            .frame(minHeight: 50)
        }
        .padding(24).readablePageWidth()
    }

    private var ready: some View {
        ScrollView {
            VStack(spacing: 25) {
                Spacer(minLength: 60)
                ZStack {
                    Circle().stroke(BBTheme.oxblood.opacity(0.18), lineWidth: 1).frame(width: 150, height: 150)
                    Text("100").font(BBTheme.score(66)).foregroundStyle(BBTheme.oxblood)
                }
                Eyebrow("The ledger is open")
                Text("Start with the truth you remember.").font(BBTheme.display(36)).multilineTextAlignment(.center)
                Text("A first reaction is enough. Comparisons and return visits will quietly sharpen the order over time.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                Button("Open My Ledger") { finish(useSample: false) }.buttonStyle(PrimaryButtonStyle())
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
                pageHeading(number: "03", title: "Give the ledger a head start.", detail: "A few seeded judgments keep the first ranking from feeling cold. Every question is optional and can be corrected later with more evidence.")
                if store.locations.count < 2 {
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow("Rapid quick-add")
                        Text("Name up to three places you already know.").font(BBTheme.display(24))
                        ForEach(seedNames.indices, id: \.self) { index in
                            VStack(spacing: 8) {
                                TextField("Establishment \(index + 1)", text: $seedNames[index]).textInputAutocapitalization(.words)
                                Picker("Reaction", selection: $seedReactions[index]) { ForEach(Reaction.allCases) { Text($0.compactTitle).tag($0) } }.pickerStyle(.segmented)
                            }.padding(.vertical, 7)
                            if index < seedNames.count - 1 { Divider() }
                        }
                        Button("Seed the Ledger") { seedQuickPlaces() }.buttonStyle(PrimaryButtonStyle())
                    }.ledgerCard()
                } else if calibrationPairs.isEmpty, !openingAnchorAnswered, let location = store.ranked().first?.location {
                    VStack(spacing: 12) {
                        Eyebrow("Absolute calibration")
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
                        Button("Too Close to Call") { answerCalibration(.tie, question: question) }.buttonStyle(.bordered)
                        Button("Skip") { calibrationIndex += 1 }.frame(minHeight: 44)
                    }.ledgerCard()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 38, weight: .light)).foregroundStyle(BBTheme.oxblood)
                        Text("The opening order is set.").font(BBTheme.display(27))
                        Text("Settle the Score will quietly find better questions over time.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
            Eyebrow("Act \(number)")
            Text(title).font(BBTheme.display(39))
            Text(detail).font(.body).foregroundStyle(.secondary).frame(maxWidth: 620, alignment: .leading)
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

    private func editorialField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(BBTheme.eyebrow).foregroundStyle(.secondary)
            TextField(title, text: text).font(BBTheme.display(25, weight: .regular)).textInputAutocapitalization(.words)
        }
        .padding(18).frame(minHeight: 84)
    }

    private func importCSV(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let summary = try CSVImporter.parse(data: Data(contentsOf: url))
            for meal in summary.meals {
                let location = store.createLocation(name: meal.establishment, category: meal.category, address: meal.address, cuisines: meal.cuisines)
                let visit = store.logVisit(at: location, reaction: meal.reaction, date: meal.date, hazy: meal.hazy)
                if let memory = meal.memory { store.updateVisit(visit, type: nil, priceBand: 0, occasion: nil, memory: memory, companions: []) }
                if let dish = meal.dish, let personID = store.currentPerson?.id {
                    _ = store.addDish(name: dish, role: .entree, reaction: meal.reaction ?? .fine, wouldOrderAgain: true, to: visit, personID: personID)
                }
            }
            importedCount = summary.meals.count
            importMessage = "Imported \(summary.meals.count) visits. \(summary.skippedRows) incomplete rows were skipped."
        } catch { importMessage = error.localizedDescription }
    }

    private func finish(useSample: Bool) {
        if store.activeCircle == nil { store.bootstrap(myName: myName, partnerName: partnerName, circleName: circleName) }
        if useSample { store.seedSampleLedger() }
        Haptics.success()
        isComplete = true
    }

    private func seedQuickPlaces() {
        for index in seedNames.indices {
            let name = seedNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let location = store.createLocation(name: name, category: DiningCategory.suggested(for: name))
            _ = store.logVisit(at: location, reaction: seedReactions[index], date: .now.addingTimeInterval(Double(-index) * 60))
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
        }.buttonStyle(.plain)
    }

    private func answerCalibration(_ outcome: ComparisonOutcome, question: ComparisonQuestion) {
        store.recordComparison(a: question.a, b: question.b, outcome: outcome)
        calibrationIndex += 1
        Haptics.selection()
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).foregroundStyle(BBTheme.paper)
            .frame(maxWidth: .infinity).frame(minHeight: 56)
            .background(configuration.isPressed ? BBTheme.oxblood.opacity(0.78) : BBTheme.oxblood)
            .overlay { Rectangle().stroke(BBTheme.oxblood, lineWidth: 1) }
    }
}
