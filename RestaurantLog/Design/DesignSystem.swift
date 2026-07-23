import SwiftUI

enum BBTheme {
    static let paper = Color("Paper")
    static let ink = Color("Ink")
    static let oxblood = Color("Oxblood")
    /// The light-paper tone as a fixed color, for text and motifs that sit on
    /// fixed dark fills (artwork gradients) and must stay legible in dark mode.
    static let cream = Color(red: 0.957, green: 0.922, blue: 0.867)
    static let parchment = Color(red: 0.90, green: 0.85, blue: 0.76)
    static let sage = adaptive(
        light: UIColor(red: 0.36, green: 0.43, blue: 0.34, alpha: 1),
        dark: UIColor(red: 0.63, green: 0.71, blue: 0.58, alpha: 1)
    )
    static let blueInk = Color(red: 0.18, green: 0.34, blue: 0.38)
    static let surface = adaptive(
        light: UIColor(red: 0.985, green: 0.968, blue: 0.936, alpha: 1),
        dark: UIColor(red: 0.095, green: 0.090, blue: 0.085, alpha: 1)
    )
    static let surfaceRaised = adaptive(
        light: UIColor(red: 1.000, green: 0.992, blue: 0.976, alpha: 1),
        dark: UIColor(red: 0.125, green: 0.118, blue: 0.110, alpha: 1)
    )
    static let surfaceMuted = adaptive(
        light: UIColor(red: 0.925, green: 0.890, blue: 0.825, alpha: 1),
        dark: UIColor(red: 0.155, green: 0.145, blue: 0.135, alpha: 1)
    )
    static let hairline = ink.opacity(0.14)
    static let strongHairline = ink.opacity(0.24)

    enum Spacing {
        static let page: CGFloat = 18
        static let section: CGFloat = 28
        static let card: CGFloat = 18
        static let compact: CGFloat = 10
    }

    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 13
        static let small: CGFloat = 9
    }

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: scaled(size, cap: 1.4), weight: weight, design: .serif)
    }
    static func score(_ size: CGFloat) -> Font {
        .system(size: scaled(size, cap: 1.3), weight: .medium, design: .serif).monospacedDigit()
    }
    static let eyebrow = Font.system(.caption, design: .rounded, weight: .bold).smallCaps()

    /// Display and score sizes follow the user's Dynamic Type setting, capped
    /// so the biggest headlines stay headlines instead of filling the screen.
    private static func scaled(_ size: CGFloat, cap: CGFloat) -> CGFloat {
        min(UIFontMetrics(forTextStyle: .title2).scaledValue(for: size), size * cap)
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

struct PaperBackground: View {
    var body: some View {
        ZStack {
            BBTheme.paper
            RadialGradient(
                colors: [BBTheme.oxblood.opacity(0.075), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [BBTheme.sage.opacity(0.045), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 460
            )
            Canvas { context, size in
                for index in 0..<64 {
                    let x = CGFloat((index * 47) % 97) / 97 * size.width
                    let y = CGFloat((index * 71) % 101) / 101 * size.height
                    let diameter: CGFloat = index.isMultiple(of: 7) ? 1.1 : 0.7
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                        with: .color(BBTheme.ink.opacity(0.035))
                    )
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct EditorialCardModifier: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(BBTheme.surface, in: RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous)
                    .stroke(BBTheme.hairline, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.055), radius: 14, y: 7)
    }
}

extension View {
    func editorialCard(padding: CGFloat = 18) -> some View { modifier(EditorialCardModifier(padding: padding)) }
    func editorialPage() -> some View {
        background(PaperBackground())
            .foregroundStyle(BBTheme.ink)
            .tint(BBTheme.oxblood)
            .toolbarBackground(BBTheme.paper.opacity(0.96), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
    /// The `Form`-based counterpart to `editorialPage()`.
    func editorialForm() -> some View {
        scrollContentBackground(.hidden)
            .background(PaperBackground())
            .tint(BBTheme.oxblood)
            .toolbarBackground(BBTheme.paper.opacity(0.96), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .environment(\.defaultMinListRowHeight, 52)
    }
    func readablePageWidth() -> some View { frame(maxWidth: 720, alignment: .center).frame(maxWidth: .infinity) }
}

/// Dims and gently compresses card-shaped buttons while pressed, so every
/// tappable surface answers the touch.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.24), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(BBTheme.paper)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(
                configuration.isPressed ? BBTheme.oxblood.opacity(0.78) : BBTheme.oxblood,
                in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                    .stroke(BBTheme.oxblood.opacity(0.9), lineWidth: 1)
            }
            .shadow(color: BBTheme.oxblood.opacity(configuration.isPressed ? 0 : 0.16), radius: 10, y: 5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .spring(duration: 0.22), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(BBTheme.oxblood)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(
                configuration.isPressed ? BBTheme.oxblood.opacity(0.11) : BBTheme.surface,
                in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                    .stroke(configuration.isPressed ? BBTheme.oxblood : BBTheme.hairline, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .spring(duration: 0.22), value: configuration.isPressed)
    }
}

struct Eyebrow: View {
    let text: String
    var color: Color = BBTheme.oxblood
    init(_ text: String, color: Color = BBTheme.oxblood) { self.text = text; self.color = color }
    var body: some View { Text(text.uppercased()).font(BBTheme.eyebrow).tracking(1.2).foregroundStyle(color) }
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
                    .accessibilityHint("Opens (title.lowercased())")
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
            if caption != nil || provisional {
                HStack(spacing: 4) {
                    if let caption { Text(caption) }
                    if caption != nil, provisional { Text("·") }
                    if provisional { Text("PROVISIONAL").fontWeight(.bold).tracking(0.4) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RankChip: View {
    let text: String
    var emphasized = false
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 6)
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
            Circle().fill(BBTheme.cream.opacity(0.13)).frame(width: height * 1.1).offset(x: -height * 0.42, y: height * 0.32)
            Circle().stroke(BBTheme.cream.opacity(0.25), lineWidth: 1).frame(width: height * 0.72).offset(x: height * 0.43, y: -height * 0.26)
            Image(systemName: category.symbol)
                .font(.system(size: height * 0.26, weight: .thin))
                .foregroundStyle(BBTheme.cream.opacity(0.92))
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }

    // Fixed colors: the artwork reads as printed plates, identical in light and dark.
    private var palette: [Color] {
        switch category {
        case .fullService: [Color(red: 0.435, green: 0.114, blue: 0.169), Color(red: 0.34, green: 0.12, blue: 0.12)]
        case .counterService: [Color(red: 0.65, green: 0.32, blue: 0.16), Color(red: 0.435, green: 0.114, blue: 0.169)]
        case .coffeeTea: [Color(red: 0.25, green: 0.18, blue: 0.13), Color(red: 0.52, green: 0.38, blue: 0.25)]
        case .bakeries: [Color(red: 0.68, green: 0.45, blue: 0.42), Color(red: 0.46, green: 0.23, blue: 0.27)]
        case .barsBreweries: [BBTheme.blueInk, Color(red: 0.12, green: 0.20, blue: 0.21)]
        case .dessert: [Color(red: 0.49, green: 0.32, blue: 0.44), Color(red: 0.74, green: 0.50, blue: 0.49)]
        case .trucksStands: [Color(red: 0.36, green: 0.43, blue: 0.34), Color(red: 0.23, green: 0.30, blue: 0.19)]
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
                            .frame(width: 24, height: 24)
                        Text(reaction.rawValue).font(.body.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: selected == reaction ? "checkmark.circle.fill" : "circle")
                            .font(.callout)
                            .opacity(selected == nil || selected == reaction ? 1 : 0.45)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    .foregroundStyle(selected == reaction ? BBTheme.paper : BBTheme.ink)
                    .background(
                        selected == reaction ? BBTheme.oxblood : BBTheme.surface,
                        in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                            .stroke(selected == reaction ? BBTheme.oxblood : BBTheme.hairline)
                    }
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("reaction-\(reaction.rawValue)")
                .accessibilityValue(selected == reaction ? "Selected" : "Not selected")
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    var symbol: String? = nil
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.caption.weight(.semibold)) }
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundStyle(selected ? BBTheme.paper : BBTheme.ink)
            .background(selected ? BBTheme.oxblood : BBTheme.surface, in: Capsule())
            .overlay { Capsule().stroke(selected ? BBTheme.oxblood : BBTheme.hairline, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct IconTile: View {
    let symbol: String
    var emphasized = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(emphasized ? BBTheme.paper : BBTheme.oxblood)
            .frame(width: 46, height: 46)
            .background(emphasized ? BBTheme.oxblood : BBTheme.oxblood.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct EmptyLogView: View {
    let title: String
    let message: String
    let symbol: String
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(BBTheme.oxblood.opacity(0.08)).frame(width: 72, height: 72)
                Circle().stroke(BBTheme.oxblood.opacity(0.18), lineWidth: 1).frame(width: 72, height: 72)
                Image(systemName: symbol).font(.system(size: 27, weight: .light)).foregroundStyle(BBTheme.oxblood)
            }
            Text(title)
                .font(BBTheme.display(23))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 38)
        .accessibilityElement(children: .combine)
    }
}
