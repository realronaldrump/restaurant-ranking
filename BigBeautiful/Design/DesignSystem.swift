import SwiftUI

enum BBTheme {
    static let paper = Color("Paper")
    static let ink = Color("Ink")
    static let oxblood = Color("Oxblood")
    static let parchment = Color(red: 0.90, green: 0.85, blue: 0.76)
    static let sage = Color(red: 0.36, green: 0.43, blue: 0.34)
    static let blueInk = Color(red: 0.18, green: 0.34, blue: 0.38)
    static let hairline = ink.opacity(0.16)

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func score(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .serif).monospacedDigit()
    }
    static let eyebrow = Font.system(.caption, design: .rounded, weight: .bold).smallCaps()
}

struct PaperBackground: View {
    var body: some View {
        ZStack {
            BBTheme.paper
            LinearGradient(
                colors: [BBTheme.oxblood.opacity(0.035), .clear, BBTheme.parchment.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, size in
                for index in 0..<90 {
                    let x = CGFloat((index * 47) % 97) / 97 * size.width
                    let y = CGFloat((index * 71) % 101) / 101 * size.height
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.7, height: 0.7)), with: .color(BBTheme.ink.opacity(0.035)))
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

struct LedgerCardModifier: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(BBTheme.paper.opacity(0.9))
            .overlay { RoundedRectangle(cornerRadius: 3).stroke(BBTheme.hairline, lineWidth: 1) }
            .shadow(color: BBTheme.ink.opacity(0.055), radius: 10, y: 5)
    }
}

extension View {
    func ledgerCard(padding: CGFloat = 18) -> some View { modifier(LedgerCardModifier(padding: padding)) }
    func editorialPage() -> some View {
        background(PaperBackground()).foregroundStyle(BBTheme.ink).tint(BBTheme.oxblood)
    }
    func readablePageWidth() -> some View { frame(maxWidth: 760, alignment: .center).frame(maxWidth: .infinity) }
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(BBTheme.eyebrow).tracking(1.2).foregroundStyle(BBTheme.oxblood) }
}

struct EditorialSectionHeader: View {
    let eyebrow: String?
    let title: String
    let action: (() -> Void)?
    let actionTitle: String

    init(_ title: String, eyebrow: String? = nil, actionTitle: String = "See All", action: (() -> Void)? = nil) {
        self.title = title; self.eyebrow = eyebrow; self.action = action; self.actionTitle = actionTitle
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow { Eyebrow(eyebrow) }
                Text(title).font(BBTheme.display(27))
            }
            Spacer()
            if let action {
                Button(actionTitle, action: action)
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
        }
    }
}

struct ScoreMark: View {
    let score: Double
    var caption: String? = nil
    var size: CGFloat = 56
    var provisional = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(score.formatted(.number.precision(.fractionLength(1))))
                .font(BBTheme.score(size))
                .foregroundStyle(BBTheme.oxblood)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.7)
                .accessibilityLabel("Score \(score.formatted(.number.precision(.fractionLength(1)))) out of 100")
            if provisional { Text("PROVISIONAL").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.8).foregroundStyle(.secondary) }
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct RankChip: View {
    let text: String
    var emphasized = false
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(emphasized ? BBTheme.paper : BBTheme.ink)
            .background(emphasized ? BBTheme.oxblood : BBTheme.ink.opacity(0.06), in: Capsule())
    }
}

struct CategoryArtwork: View {
    let category: DiningCategory
    var height: CGFloat = 160
    var body: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(BBTheme.paper.opacity(0.13)).frame(width: height * 1.1).offset(x: -height * 0.42, y: height * 0.32)
            Circle().stroke(BBTheme.paper.opacity(0.25), lineWidth: 1).frame(width: height * 0.72).offset(x: height * 0.43, y: -height * 0.26)
            Image(systemName: category.symbol)
                .font(.system(size: height * 0.26, weight: .thin))
                .foregroundStyle(BBTheme.paper.opacity(0.92))
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
    private var palette: [Color] {
        switch category {
        case .fullService: [BBTheme.oxblood, Color(red: 0.34, green: 0.12, blue: 0.12)]
        case .counterService: [Color(red: 0.65, green: 0.32, blue: 0.16), BBTheme.oxblood]
        case .coffeeTea: [Color(red: 0.25, green: 0.18, blue: 0.13), Color(red: 0.52, green: 0.38, blue: 0.25)]
        case .bakeries: [Color(red: 0.68, green: 0.45, blue: 0.42), Color(red: 0.46, green: 0.23, blue: 0.27)]
        case .barsBreweries: [BBTheme.blueInk, Color(red: 0.12, green: 0.20, blue: 0.21)]
        case .dessert: [Color(red: 0.49, green: 0.32, blue: 0.44), Color(red: 0.74, green: 0.50, blue: 0.49)]
        case .trucksStands: [BBTheme.sage, Color(red: 0.23, green: 0.30, blue: 0.19)]
        }
    }
}

struct ReactionPicker: View {
    let selected: Reaction?
    let onSelect: (Reaction) -> Void
    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Reaction.allCases) { reaction in
                Button { onSelect(reaction) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: reaction.symbol)
                        Text(reaction.rawValue).font(.body.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    .foregroundStyle(selected == reaction ? BBTheme.paper : BBTheme.ink)
                    .background(selected == reaction ? BBTheme.oxblood : BBTheme.ink.opacity(0.055))
                    .overlay { Rectangle().stroke(selected == reaction ? BBTheme.oxblood : BBTheme.hairline) }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reaction-\(reaction.rawValue)")
            }
        }
    }
}

struct EmptyLedgerView: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(BBTheme.oxblood)
            Text(title).font(BBTheme.display(23)).multilineTextAlignment(.center)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
    }
}
