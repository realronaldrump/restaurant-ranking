import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    static let storageKey = "appearancePreference"

    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum BBTheme {
    static let paper = Color("Paper")
    static let ink = Color("Ink")
    /// Oxblood used as ink, strokes, and small accents. It lightens in dark
    /// mode so it remains legible on the paper background.
    static let oxbloodInk = Color("Oxblood")
    /// Oxblood used as a filled surface. Unlike the ink token, this remains
    /// deep in dark mode so cream text keeps sufficient contrast and the
    /// editorial identity does not turn into a bright pink control language.
    static let oxbloodFill = adaptive(
        light: UIColor(red: 0.435, green: 0.114, blue: 0.169, alpha: 1),
        dark: UIColor(red: 0.365, green: 0.075, blue: 0.125, alpha: 1)
    )
    /// Semantic destructive fill. It deliberately differs from the brand fill
    /// so a dangerous action is communicated by more than wording alone.
    static let destructiveFill = adaptive(
        light: UIColor(red: 0.610, green: 0.105, blue: 0.125, alpha: 1),
        dark: UIColor(red: 0.690, green: 0.150, blue: 0.175, alpha: 1)
    )
    /// Compatibility alias for existing text/accent call sites.
    static let oxblood = oxbloodInk
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
        .system(size: scaled(size, minimumBodyScaleRatio: 0.86), weight: weight, design: .serif)
    }
    static func score(_ size: CGFloat) -> Font {
        .system(size: scaled(size, minimumBodyScaleRatio: 0.82), weight: .medium, design: .serif).monospacedDigit()
    }
    static let eyebrow = Font.system(.caption, design: .rounded, weight: .bold).smallCaps()

    /// The largest an editorial size may grow, as a multiple of its base size.
    /// Body text keeps climbing past this at accessibility sizes, which is the
    /// point: the ceiling lets headlines stop growing before they swallow the
    /// screen while the floor keeps them ahead of body copy until then.
    private static let maximumDisplayScale: CGFloat = 1.9

    /// Large editorial type follows Dynamic Type without falling behind body
    /// text at accessibility sizes, and without running away either.
    ///
    /// The proportional floor preserves the hierarchy that a plain title metric
    /// loses once body text scales past it; the ceiling is what actually bounds
    /// growth, because the floor rises with the body scale (roughly 3x at the
    /// largest accessibility size) and would otherwise dominate unopposed.
    private static func scaled(_ size: CGFloat, minimumBodyScaleRatio: CGFloat) -> CGFloat {
        let titleScaled = UIFontMetrics(forTextStyle: .title2).scaledValue(for: size)
        let bodyScale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 17) / 17
        let floor = size * bodyScale * minimumBodyScaleRatio
        return min(size * maximumDisplayScale, max(titleScaled, floor))
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
            .foregroundStyle(BBTheme.ink)
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
            .foregroundStyle(BBTheme.cream)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(
                configuration.isPressed ? BBTheme.oxbloodFill.opacity(0.78) : BBTheme.oxbloodFill,
                in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                    .stroke(BBTheme.oxbloodFill.opacity(0.9), lineWidth: 1)
            }
            .shadow(color: BBTheme.oxbloodFill.opacity(configuration.isPressed ? 0 : 0.16), radius: 10, y: 5)
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

// MARK: - Editorial prompts

/// The app-owned counterpart to a system alert or confirmation dialog.
/// System-owned permission prompts, document pickers, and sign-in surfaces
/// intentionally remain native iOS UI.
@MainActor
struct EditorialPrompt {
    enum Tone {
        case information
        case decision
        case destructive
        case error

        fileprivate var symbol: String {
            switch self {
            case .information: "info.circle.fill"
            case .decision: "checkmark.seal.fill"
            case .destructive: "exclamationmark.triangle.fill"
            case .error: "exclamationmark.octagon.fill"
            }
        }
    }

    struct Action: Identifiable {
        enum Role {
            case primary
            case secondary
            case destructive
            case cancel
        }

        let id: String
        let title: String
        let symbol: String?
        let role: Role
        let isEnabled: Bool
        fileprivate let perform: @MainActor () -> Void

        init(
            _ title: String,
            id: String? = nil,
            symbol: String? = nil,
            role: Role = .secondary,
            isEnabled: Bool = true,
            perform: @escaping @MainActor () -> Void = {}
        ) {
            self.id = id ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
            self.title = title
            self.symbol = symbol
            self.role = role
            self.isEnabled = isEnabled
            self.perform = perform
        }

        static func primary(
            _ title: String,
            symbol: String? = nil,
            isEnabled: Bool = true,
            perform: @escaping @MainActor () -> Void
        ) -> Self {
            .init(title, symbol: symbol, role: .primary, isEnabled: isEnabled, perform: perform)
        }

        static func secondary(
            _ title: String,
            symbol: String? = nil,
            perform: @escaping @MainActor () -> Void
        ) -> Self {
            .init(title, symbol: symbol, role: .secondary, perform: perform)
        }

        static func destructive(
            _ title: String,
            symbol: String? = nil,
            perform: @escaping @MainActor () -> Void
        ) -> Self {
            .init(title, symbol: symbol, role: .destructive, perform: perform)
        }

        static func cancel(
            _ title: String = "Cancel",
            perform: @escaping @MainActor () -> Void = {}
        ) -> Self {
            .init(title, role: .cancel, perform: perform)
        }
    }

    struct Field {
        let label: String
        let text: Binding<String>
        let capitalization: TextInputAutocapitalization
        let submitLabel: SubmitLabel

        init(
            _ label: String,
            text: Binding<String>,
            capitalization: TextInputAutocapitalization = .sentences,
            submitLabel: SubmitLabel = .done
        ) {
            self.label = label
            self.text = text
            self.capitalization = capitalization
            self.submitLabel = submitLabel
        }
    }

    let title: String
    let message: String?
    let tone: Tone
    let field: Field?
    let actions: [Action]

    init(
        _ title: String,
        message: String? = nil,
        tone: Tone = .decision,
        field: Field? = nil,
        actions: [Action] = []
    ) {
        self.title = title
        self.message = message
        self.tone = tone
        self.field = field
        self.actions = actions
    }

    static func information(
        _ title: String,
        message: String,
        dismissTitle: String = "Done",
        onDismiss: @escaping @MainActor () -> Void = {}
    ) -> Self {
        .init(
            title,
            message: message,
            tone: .information,
            actions: [.primary(dismissTitle, symbol: "checkmark", perform: onDismiss)]
        )
    }

    static func error(
        _ title: String,
        message: String,
        dismissTitle: String = "OK",
        onDismiss: @escaping @MainActor () -> Void = {}
    ) -> Self {
        .init(
            title,
            message: message,
            tone: .error,
            actions: [.primary(dismissTitle, perform: onDismiss)]
        )
    }

    static func destructive(
        _ title: String,
        message: String,
        actionTitle: String,
        actionSymbol: String? = nil,
        cancelTitle: String = "Cancel",
        perform: @escaping @MainActor () -> Void
    ) -> Self {
        .init(
            title,
            message: message,
            tone: .destructive,
            actions: [
                .destructive(actionTitle, symbol: actionSymbol, perform: perform),
                .cancel(cancelTitle)
            ]
        )
    }
}

@MainActor
private struct EditorialPromptBooleanModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresented: Bool
    @State private var snapshot: EditorialPrompt?
    let makePrompt: @MainActor () -> EditorialPrompt

    func body(content: Content) -> some View {
        ZStack {
            content
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)
            if isPresented {
                let prompt = snapshot ?? makePrompt()
                EditorialPromptHost(prompt: prompt) {
                    snapshot = nil
                    isPresented = false
                }
                .zIndex(10)
                .transition(.opacity.combined(with: .scale(scale: 0.975)))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12), value: isPresented)
        .onChange(of: isPresented) { _, presented in
            snapshot = presented ? makePrompt() : nil
        }
    }
}

@MainActor
private struct EditorialPromptItemModifier<Item>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var item: Item?
    @State private var snapshot: Item?
    let makePrompt: @MainActor (Item) -> EditorialPrompt

    func body(content: Content) -> some View {
        let presentedItem = snapshot ?? item
        ZStack {
            content
                .allowsHitTesting(presentedItem == nil)
                .accessibilityHidden(presentedItem != nil)
            if let presentedItem {
                EditorialPromptHost(prompt: makePrompt(presentedItem)) {
                    snapshot = nil
                    self.item = nil
                }
                .zIndex(10)
                .transition(.opacity.combined(with: .scale(scale: 0.975)))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12), value: presentedItem != nil)
        .onChange(of: item != nil) { _, presented in
            snapshot = presented ? item : nil
        }
    }
}

@MainActor
private struct EditorialPromptHost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AccessibilityFocusState private var titleIsFocused: Bool
    @FocusState private var fieldIsFocused: Bool
    @State private var didChooseAction = false

    let prompt: EditorialPrompt
    let dismiss: @MainActor () -> Void

    private var normalizedActions: [EditorialPrompt.Action] {
        var result = prompt.actions
        if result.isEmpty {
            result = [.primary("Done", perform: {})]
        }
        if result.contains(where: { $0.role == .destructive }),
           !result.contains(where: { $0.role == .cancel }) {
            result.append(.cancel())
        }
        return result
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(colorScheme == .dark ? 0.62 : 0.42)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header

                        if let message = prompt.message {
                            Text(message)
                                .font(.body)
                                .foregroundStyle(BBTheme.ink.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let field = prompt.field {
                            TextField(field.label, text: field.text)
                                .textInputAutocapitalization(field.capitalization)
                                .submitLabel(field.submitLabel)
                                .textFieldStyle(.plain)
                                .font(.body)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 52)
                                .background(BBTheme.surface, in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                                        .stroke(fieldIsFocused ? BBTheme.oxbloodInk : BBTheme.strongHairline, lineWidth: fieldIsFocused ? 2 : 1)
                                }
                                .focused($fieldIsFocused)
                        }

                        VStack(spacing: 10) {
                            ForEach(normalizedActions) { action in
                                Button {
                                    choose(action)
                                } label: {
                                    HStack(spacing: 9) {
                                        if let symbol = action.symbol {
                                            Image(systemName: symbol)
                                        }
                                        Text(action.title)
                                            .multilineTextAlignment(.center)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(EditorialPromptActionStyle(role: action.role))
                                .disabled(!action.isEnabled || didChooseAction)
                                .accessibilityIdentifier("editorial-prompt-action-\(action.id)")
                            }
                        }
                    }
                    .padding(22)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: 520)
                .frame(maxHeight: max(260, proxy.size.height - 44))
                .background(BBTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(BBTheme.strongHairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 30, y: 16)
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editorial-prompt")
        .accessibilityAction(.escape) { cancel() }
        .onAppear {
            if prompt.field == nil {
                titleIsFocused = true
            } else {
                fieldIsFocused = true
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: didChooseAction)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(prompt.title)
                .font(BBTheme.display(29))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleIsFocused)
                .accessibilityIdentifier("editorial-prompt-title")
            Spacer(minLength: 8)
            Image(systemName: prompt.tone.symbol)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(toneColor)
                .frame(width: 48, height: 48)
                .background(toneColor.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
        }
    }

    private var toneColor: Color {
        switch prompt.tone {
        case .destructive, .error: BBTheme.destructiveFill
        case .information, .decision: BBTheme.oxbloodInk
        }
    }

    private func choose(_ action: EditorialPrompt.Action) {
        guard !didChooseAction else { return }
        didChooseAction = true
        let perform = action.perform
        dismiss()
        Task { @MainActor in
            await Task.yield()
            perform()
        }
    }

    private func cancel() {
        if let action = normalizedActions.first(where: { $0.role == .cancel }) {
            choose(action)
        } else if let action = normalizedActions.last {
            choose(action)
        } else {
            dismiss()
        }
    }
}

private struct EditorialPromptActionStyle: ButtonStyle {
    let role: EditorialPrompt.Action.Role
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : .spring(duration: 0.2), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary, .destructive: BBTheme.cream
        case .secondary, .cancel: BBTheme.ink
        }
    }

    private func background(_ isPressed: Bool) -> Color {
        let base: Color = switch role {
        case .primary: BBTheme.oxbloodFill
        case .destructive: BBTheme.destructiveFill
        case .secondary: BBTheme.surface
        case .cancel: BBTheme.surfaceMuted.opacity(0.55)
        }
        return base.opacity(isPressed ? 0.76 : 1)
    }

    private var border: Color {
        switch role {
        case .primary: BBTheme.oxbloodFill
        case .destructive: BBTheme.destructiveFill
        case .secondary, .cancel: BBTheme.hairline
        }
    }
}

extension View {
    @MainActor
    func editorialPrompt(
        isPresented: Binding<Bool>,
        content: @escaping @MainActor () -> EditorialPrompt
    ) -> some View {
        modifier(EditorialPromptBooleanModifier(isPresented: isPresented, makePrompt: content))
    }

    @MainActor
    func editorialPrompt<Item>(
        item: Binding<Item?>,
        content: @escaping @MainActor (Item) -> EditorialPrompt
    ) -> some View {
        modifier(EditorialPromptItemModifier(item: item, makePrompt: content))
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

    init(_ title: String, eyebrow: String? = nil, actionTitle: String = "See all", action: (() -> Void)? = nil) {
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
                    .frame(minWidth: 44, minHeight: 46, alignment: .trailing)
                    .contentShape(Rectangle())
                    .accessibilityHint("Opens \(title.lowercased())")
            }
        }
    }
}

struct ScoreMark: View {
    let score: Double
    var caption: String? = nil
    var size: CGFloat = 56
    var provisional = false
    var showsDecimal = false
    var alignment: HorizontalAlignment = .trailing

    private var formattedScore: String {
        score.formatted(.number.precision(.fractionLength(showsDecimal ? 1 : 0)))
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(formattedScore)
                .font(BBTheme.score(size))
                .foregroundStyle(BBTheme.oxblood)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.7)
                .accessibilityLabel("Return score \(formattedScore) out of 100\(provisional ? ", early score" : "")")
            if caption != nil || provisional {
                HStack(spacing: 4) {
                    if let caption { Text(caption) }
                    if caption != nil, provisional { Text("·") }
                    if provisional { Text("EARLY SCORE").fontWeight(.bold).tracking(0.25) }
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
            .foregroundStyle(emphasized ? BBTheme.cream : BBTheme.ink)
            .background(emphasized ? BBTheme.oxbloodFill : BBTheme.ink.opacity(0.06), in: Capsule())
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
                        Text(reaction.title)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Spacer(minLength: 0)
                        Image(systemName: selected == reaction ? "checkmark.circle.fill" : "circle")
                            .font(.callout)
                            .opacity(selected == nil || selected == reaction ? 1 : 0.45)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 56)
                    .foregroundStyle(selected == reaction ? BBTheme.cream : BBTheme.ink)
                    .background(
                        selected == reaction ? BBTheme.oxbloodFill : BBTheme.surface,
                        in: RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: BBTheme.Radius.control, style: .continuous)
                            .stroke(selected == reaction ? BBTheme.oxbloodFill : BBTheme.hairline)
                    }
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("reaction-\(reaction.rawValue)")
                .accessibilityValue(selected == reaction ? "Selected" : "Not selected")
            }
        }
    }
}

struct CoonReactionArtwork: View {
    let reaction: CoonReaction
    var size: CGFloat = 72

    var body: some View {
        Image(reaction.assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(reaction.title)
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
            .foregroundStyle(selected ? BBTheme.cream : BBTheme.ink)
            .background(selected ? BBTheme.oxbloodFill : BBTheme.surface, in: Capsule())
            .overlay { Capsule().stroke(selected ? BBTheme.oxbloodFill : BBTheme.hairline, lineWidth: 1) }
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
            .foregroundStyle(emphasized ? BBTheme.cream : BBTheme.oxblood)
            .frame(width: 46, height: 46)
            .background(emphasized ? BBTheme.oxbloodFill : BBTheme.oxblood.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
