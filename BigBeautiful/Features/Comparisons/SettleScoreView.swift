import SwiftUI

@MainActor
struct SettleScoreView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private enum Prompt {
        case comparison(ComparisonQuestion)
        case anchor(RestaurantLocation)
    }
    @State private var prompts: [Prompt] = []
    @State private var index = 0
    @State private var answered = 0
    @State private var isReady = false

    var body: some View {
        ZStack {
            PaperBackground()
            if !isReady { ProgressView().tint(BBTheme.oxblood) }
            else if prompts.isEmpty { empty }
            else if index >= prompts.count { complete }
            else { promptView(prompts[index]) }
        }
        .navigationTitle("Settle the Score").navigationBarTitleDisplayMode(.inline)
        .task { buildPrompts(); isReady = true }
    }

    private var empty: some View {
        EmptyLedgerView(title: "No comparisons yet", message: "Add a few more ratings and check back.", symbol: "checkmark.seal")
            .padding(20)
    }

    @ViewBuilder
    private func promptView(_ prompt: Prompt) -> some View {
        switch prompt {
        case .comparison(let question): comparisonQuestion(question)
        case .anchor(let location): anchorQuestion(location)
        }
    }

    private func comparisonQuestion(_ question: ComparisonQuestion) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                progressHeader
                Spacer(minLength: 12)
                Text("Which would you rather revisit tonight?")
                    .font(BBTheme.display(34))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                comparisonButton(question.a, side: .a, question: question)
                Text("OR").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                comparisonButton(question.b, side: .b, question: question)
                Button("Too Close to Call") { answer(.tie, question: question) }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 2)).frame(minHeight: 48)
                Button("Skip") { advance() }.foregroundStyle(.secondary).frame(minHeight: 44)
                Text("You can skip any question or choose a tie.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(22).padding(.bottom, 12).readablePageWidth()
        }
    }

    private func anchorQuestion(_ location: RestaurantLocation) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                progressHeader
                Spacer(minLength: 18)
                Eyebrow("Score check")
                Text("Which statement best fits \(location.name)?").font(BBTheme.display(32)).multilineTextAlignment(.center)
                Text("Pick the statement that comes closest.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(spacing: 8) {
                    ForEach(ScoreAnchor.ladder) { anchor in
                        Button { store.recordAnchor(for: location, value: anchor.score); answered += 1; Haptics.selection(); advance() } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(anchor.score.formatted(.number.precision(.fractionLength(0)))).font(BBTheme.score(24)).frame(width: 36, alignment: .leading)
                                Text(anchor.statement).font(.callout).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(BBTheme.ink.opacity(0.055)).overlay(Rectangle().stroke(BBTheme.hairline))
                        }.buttonStyle(.plain)
                    }
                }
                Button("Skip") { advance() }.foregroundStyle(.secondary).frame(minHeight: 44)
            }.padding(22).readablePageWidth()
        }
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow("Question \(index + 1) of \(prompts.count)")
                Spacer()
                Text("\(answered) answered").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(index), total: Double(max(1, prompts.count)))
                .tint(BBTheme.oxblood)
                .scaleEffect(y: 0.8)
        }
    }

    private enum Side { case a, b }
    private func comparisonButton(_ location: RestaurantLocation, side: Side, question: ComparisonQuestion) -> some View {
        Button { answer(side == .a ? .a : .b, question: question) } label: {
            HStack(spacing: 14) { Image(systemName: location.category.symbol).font(.title2); VStack(alignment: .leading) { Text(location.name).font(BBTheme.display(23)); Text(location.category.shortTitle).font(.caption).foregroundStyle(BBTheme.paper.opacity(0.72)) }; Spacer(); if let score = store.score(for: location) { Text(score.displayScore).font(BBTheme.score(24)) } }
                .padding(19).foregroundStyle(BBTheme.paper).background(BBTheme.oxblood)
        }.buttonStyle(.plain)
    }

    private var complete: some View {
        ScrollView {
            VStack(spacing: 19) { Image(systemName: "checkmark.seal.fill").font(.system(size: 58, weight: .light)).foregroundStyle(BBTheme.oxblood); Eyebrow("Done"); Text("Ranking updated").font(BBTheme.display(36)).multilineTextAlignment(.center); Text("\(answered) \(answered == 1 ? "answer" : "answers") added.").foregroundStyle(.secondary).multilineTextAlignment(.center); Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()) }.padding(24).readablePageWidth()
        }
    }
    private func answer(_ outcome: ComparisonOutcome, question: ComparisonQuestion) { store.recordComparison(a: question.a, b: question.b, outcome: outcome); answered += 1; Haptics.selection(); advance() }
    private func advance() { withAnimation { index += 1 } }

    private func buildPrompts() {
        let comparisons = store.settleQuestions(limit: 4).map(Prompt.comparison)
        let anchor = store.ranked().sorted { $0.certainty < $1.certainty }.first.map { Prompt.anchor($0.location) }
        if let anchor, comparisons.count >= 2 {
            prompts = Array(comparisons.prefix(2)) + [anchor] + Array(comparisons.dropFirst(2))
        } else if let anchor {
            prompts = comparisons + [anchor]
        } else {
            prompts = comparisons
        }
        prompts = Array(prompts.prefix(5))
    }
}

@MainActor
struct DirectComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let source: RestaurantLocation
    @State private var opponent: RestaurantLocation?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if let opponent { comparison(opponent) }
                else { List(candidates) { location in Button { opponent = location } label: { HStack { Image(systemName: location.category.symbol); VStack(alignment: .leading) { Text(location.name); Text(location.category.shortTitle).font(.caption).foregroundStyle(.secondary) } } }.foregroundStyle(BBTheme.ink) }.scrollContentBackground(.hidden) }
            }.background(PaperBackground()).searchable(text: $query, prompt: "Choose any establishment")
            .navigationTitle("Direct Comparison").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
    private var candidates: [RestaurantLocation] { store.locations.filter { $0 != source && !$0.isClosed && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) } }
    private func comparison(_ other: RestaurantLocation) -> some View {
        ScrollView {
            VStack(spacing: 17) { Spacer(minLength: 12); Text("Which would you rather revisit?").font(BBTheme.display(31)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true); choice(source, outcome: .a, against: other); Text("OR").font(.caption2.weight(.bold)); choice(other, outcome: .b, against: other); Button("Too Close to Call") { record(.tie, other) }.buttonStyle(.bordered); Button("Choose another") { opponent = nil }.foregroundStyle(.secondary); Spacer(minLength: 12) }.padding(22)
        }
    }
    private func choice(_ location: RestaurantLocation, outcome: ComparisonOutcome, against other: RestaurantLocation) -> some View { Button { record(outcome, other) } label: { HStack { Image(systemName: location.category.symbol); Text(location.name).font(BBTheme.display(23)); Spacer(); if let score = store.score(for: location) { Text(score.displayScore).font(BBTheme.score(22)) } }.padding(19).foregroundStyle(BBTheme.paper).background(BBTheme.oxblood) }.buttonStyle(.plain) }
    private func record(_ outcome: ComparisonOutcome, _ other: RestaurantLocation) { store.recordComparison(a: source, b: other, outcome: outcome); Haptics.success(); dismiss() }
}
