import SwiftUI

@MainActor
struct SettleScoreView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onDone: (() -> Void)?
    @State private var prompts: [SettleScorePrompt] = []
    @State private var index = 0
    @State private var answered = 0
    @State private var isReady = false
    /// What each answered question recorded, so going back can withdraw it.
    /// A skipped question records nothing and stores `nil`, which keeps the
    /// stack aligned with the questions the person actually moved through.
    @State private var recordedAnswers: [UUID?] = []

    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
    }

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
        EmptyLogView(
            title: "All settled",
            message: "Your ranking is up to date. New reactions will bring more questions.",
            symbol: "checkmark.seal"
        )
            .padding(20)
    }

    @ViewBuilder
    private func promptView(_ prompt: SettleScorePrompt) -> some View {
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
                Text("Which would you rather go back to?")
                    .font(BBTheme.display(34))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                comparisonButton(question.a, side: .a, question: question)
                Text("OR").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                comparisonButton(question.b, side: .b, question: question)
                Button("Too close to call") { answer(.tie, question: question) }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                    .accessibilityHint("Records these restaurants as roughly even")
                HStack(spacing: 22) {
                    backButton
                    Button("Skip") { advance() }.foregroundStyle(.secondary).frame(minHeight: 44)
                }
            }.padding(22).padding(.bottom, 12).readablePageWidth()
        }
    }

    private func anchorQuestion(_ location: RestaurantLocation) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                progressHeader
                Spacer(minLength: 18)
                Text("Which statement best fits \(location.name)?").font(BBTheme.display(32)).multilineTextAlignment(.center)
                Text("Pick the one that comes closest.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 8) {
                    ForEach(ScoreAnchor.ladder) { anchor in
                        Button {
                            let recordedID = store.recordAnchor(for: location, value: anchor.score)
                            answered += 1
                            Haptics.selection()
                            advance(recording: recordedID)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(anchor.score.formatted(.number.precision(.fractionLength(0)))).font(BBTheme.score(24)).frame(width: 36, alignment: .leading)
                                Text(anchor.statement).font(.callout).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(BBTheme.surface, in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                                    .stroke(BBTheme.hairline)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                HStack(spacing: 22) {
                    backButton
                    Button("Skip") { advance() }.foregroundStyle(.secondary).frame(minHeight: 44)
                }
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
            ProgressView(value: Double(min(index + 1, prompts.count)), total: Double(max(1, prompts.count)))
                .tint(BBTheme.oxblood)
                .scaleEffect(y: 0.8)
        }
    }

    private enum Side { case a, b }
    private func comparisonButton(_ location: RestaurantLocation, side: Side, question: ComparisonQuestion) -> some View {
        Button { answer(side == .a ? .a : .b, question: question) } label: {
            HStack(spacing: 14) {
                Image(systemName: location.category.symbol)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(location.name)
                        .font(BBTheme.display(23))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(location.category.shortTitle)
                        .font(.caption)
                        .foregroundStyle(BBTheme.cream.opacity(0.72))
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
                .padding(19)
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                .foregroundStyle(BBTheme.cream)
                .background(BBTheme.oxbloodFill, in: RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(location.name), \(location.category.shortTitle)")
    }

    private var complete: some View {
        ScrollView {
            VStack(spacing: 19) { Image(systemName: "checkmark.seal.fill").font(.system(size: 58, weight: .light)).foregroundStyle(BBTheme.oxblood); Eyebrow("Done"); Text("Ranking updated").font(BBTheme.display(36)).multilineTextAlignment(.center); Text("\(answered) \(answered == 1 ? "answer" : "answers") added.").foregroundStyle(.secondary).multilineTextAlignment(.center); Button("Done") { finish() }.buttonStyle(PrimaryButtonStyle()) }.padding(24).readablePageWidth()
        }
    }
    private func answer(_ outcome: ComparisonOutcome, question: ComparisonQuestion) {
        let recordedID = store.recordComparison(a: question.a, b: question.b, outcome: outcome)
        answered += 1
        Haptics.selection()
        advance(recording: recordedID)
    }

    private func advance(recording recordedID: UUID? = nil) {
        recordedAnswers.append(recordedID)
        if reduceMotion { index += 1 }
        else { withAnimation(.snappy) { index += 1 } }
    }

    private var canGoBack: Bool { index > 0 && !recordedAnswers.isEmpty }

    /// Steps back a question and withdraws the answer it recorded, so a
    /// mistapped comparison leaves no evidence behind instead of having to be
    /// argued down by a later contradicting answer.
    private func goBack() {
        guard canGoBack else { return }
        let recordedID = recordedAnswers.removeLast()
        if let recordedID, store.removeComparison(id: recordedID) {
            answered = max(0, answered - 1)
        }
        Haptics.selection()
        if reduceMotion { index -= 1 }
        else { withAnimation(.snappy) { index -= 1 } }
    }

    @ViewBuilder
    private var backButton: some View {
        if canGoBack {
            Button {
                goBack()
            } label: {
                Label("Back", systemImage: "arrow.uturn.backward")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .accessibilityHint("Returns to the previous question and undoes its answer")
        }
    }

    private func buildPrompts() {
        prompts = store.settleScorePrompts()
    }

    private func finish() {
        if let onDone {
            onDone()
        } else {
            dismiss()
        }
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
                else {
                    List(candidates) { location in
                        Button { opponent = location } label: {
                            HStack(spacing: 12) {
                                IconTile(symbol: location.category.symbol)
                                VStack(alignment: .leading) {
                                    Text(location.name).font(.headline)
                                    Text(location.category.shortTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 54)
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(BBTheme.ink)
                    }
                    .scrollContentBackground(.hidden)
                }
            }.background(PaperBackground()).searchable(text: $query, prompt: "Choose any restaurant")
            .navigationTitle("Direct Comparison").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
    private var candidates: [RestaurantLocation] { store.locations.filter { $0 != source && !$0.isClosed && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) } }
    private func comparison(_ other: RestaurantLocation) -> some View {
        ScrollView {
            VStack(spacing: 17) {
                Spacer(minLength: 12)
                Text("Which would you rather go back to?")
                    .font(BBTheme.display(31))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                choice(source, outcome: .a, against: other)
                Text("OR").font(.caption2.weight(.bold))
                choice(other, outcome: .b, against: other)
                Button("Too close to call") { record(.tie, other) }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                    .accessibilityHint("Records these restaurants as roughly even")
                Button("Choose another") { opponent = nil }
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                Spacer(minLength: 12)
            }
            .padding(22)
            .readablePageWidth()
        }
    }
    private func choice(_ location: RestaurantLocation, outcome: ComparisonOutcome, against other: RestaurantLocation) -> some View {
        Button { record(outcome, other) } label: {
            HStack {
                Image(systemName: location.category.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(location.name)
                        .font(BBTheme.display(23))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(location.category.shortTitle)
                        .font(.caption)
                        .foregroundStyle(BBTheme.cream.opacity(0.72))
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(19)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .foregroundStyle(BBTheme.cream)
            .background(BBTheme.oxbloodFill, in: RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(location.name), \(location.category.shortTitle)")
    }
    private func record(_ outcome: ComparisonOutcome, _ other: RestaurantLocation) { store.recordComparison(a: source, b: other, outcome: outcome); Haptics.success(); dismiss() }
}
