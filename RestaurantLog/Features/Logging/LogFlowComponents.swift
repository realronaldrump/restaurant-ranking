import SwiftUI

// The moving parts of the full-screen logging wizard. The wizard is the one
// place the app turns its red all the way up: cream answers on a deep red
// stage, the same in light and dark, like a printed menu cover.

/// Fixed colors for the wizard. Nothing here adapts to dark mode on purpose:
/// cream cards need dark ink whatever the system appearance is.
enum WizardPalette {
    static let red = Color(red: 0.58, green: 0.11, blue: 0.19)
    static let redDeep = Color(red: 0.34, green: 0.05, blue: 0.11)
    static let cream = BBTheme.cream
    static let card = Color(red: 0.992, green: 0.972, blue: 0.938)
    static let ink = Color(red: 0.15, green: 0.11, blue: 0.10)
    static let glowWarm = Color(red: 0.96, green: 0.50, blue: 0.22)
    static let glowRose = Color(red: 0.93, green: 0.27, blue: 0.40)

    static func tint(_ tone: WizardOption.Tone) -> Color {
        switch tone {
        case .best, .plain: Color(red: 0.60, green: 0.12, blue: 0.20)
        case .good: Color(red: 0.80, green: 0.42, blue: 0.12)
        case .okay: Color(red: 0.33, green: 0.47, blue: 0.33)
        case .poor: Color(red: 0.17, green: 0.36, blue: 0.44)
        }
    }
}

extension Reaction {
    var wizardTone: WizardOption.Tone {
        switch self {
        case .loved: .best
        case .liked: .good
        case .fine: .okay
        case .notForMe: .poor
        }
    }

    /// How much confetti a save earns. A meal that was not enjoyed is saved
    /// without any.
    var celebrationSize: Int {
        switch self {
        case .loved: 46
        case .liked: 28
        case .fine: 10
        case .notForMe: 0
        }
    }
}

/// Changes wizard state with the wizard's one spring, or without animation
/// when motion is reduced.
@MainActor
func wizardMove(_ reduceMotion: Bool, _ change: () -> Void) {
    if reduceMotion { change() } else { withAnimation(.spring(duration: 0.46, bounce: 0.24), change) }
}

// MARK: - Stage

/// The red stage everything plays on, with two slow glows drifting across it
/// so the screen is never completely still.
struct WizardBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrifting = false

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height)
            ZStack {
                LinearGradient(
                    colors: [WizardPalette.red, WizardPalette.redDeep],
                    startPoint: .top,
                    endPoint: .bottom
                )
                glow(WizardPalette.glowWarm, opacity: 0.42, diameter: side * 0.9)
                    .offset(x: side * (isDrifting ? 0.30 : 0.16), y: side * (isDrifting ? -0.42 : -0.34))
                    .animation(drift, value: isDrifting)
                glow(WizardPalette.glowRose, opacity: 0.34, diameter: side * 0.8)
                    .offset(x: side * (isDrifting ? -0.32 : -0.2), y: side * (isDrifting ? 0.30 : 0.40))
                    .animation(drift, value: isDrifting)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear { isDrifting = true }
    }

    /// Scoped to the two glows. A repeating animation started with
    /// `withAnimation` would ride along on whatever else changed in the same
    /// update and keep the wizard's own views animating forever.
    private var drift: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 7).repeatForever(autoreverses: true)
    }

    private func glow(_ color: Color, opacity: Double, diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)], center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
    }
}

/// One short bar per question, filling as they are passed.
struct LogFlowProgress: View {
    let step: Int
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(WizardPalette.cream.opacity(index <= step ? 1 : 0.26))
                    .frame(maxWidth: index == step ? 26 : 12)
                    .frame(height: 5)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.3), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of \(count)")
    }
}

struct LogFlowIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.bold))
                .foregroundStyle(WizardPalette.cream)
                .frame(width: 44, height: 44)
                .background(WizardPalette.cream.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(BouncyPressStyle())
        .accessibilityLabel(label)
    }
}

/// A lively press: the wizard is meant to answer every touch.
struct BouncyPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.5), value: configuration.isPressed)
    }
}

/// The wizard's main button: cream on red, the inverse of the app's usual one.
struct WizardPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(WizardPalette.redDeep)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(WizardPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.5), value: configuration.isPressed)
    }
}

struct WizardSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(WizardPalette.cream)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(WizardPalette.cream.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(WizardPalette.cream.opacity(0.3), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0.5), value: configuration.isPressed)
    }
}

/// Lets a set of options arrive one after another instead of all at once.
private struct StaggeredAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown ? 0 : 26)
            .scaleEffect(isShown ? 1 : 0.9)
            .onAppear {
                guard !isShown else { return }
                if reduceMotion {
                    isShown = true
                } else {
                    withAnimation(.spring(duration: 0.44, bounce: 0.36).delay(Double(min(index, 10)) * 0.045)) {
                        isShown = true
                    }
                }
            }
    }
}

extension View {
    func staggeredAppear(index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
}

// MARK: - Where

/// A restaurant offered as a one-tap answer. The prominent form is for the
/// single best guess; the rest sit in a grid.
struct LogPlaceTile: View {
    let name: String
    let subtitle: String
    let symbol: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isProminent { prominent } else { regular }
        }
        .buttonStyle(BouncyPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtitle.isEmpty ? name : "\(name), \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }

    private var prominent: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(WizardPalette.cream)
                .frame(width: 52, height: 52)
                .background(WizardPalette.red, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(BBTheme.display(24))
                    .foregroundStyle(WizardPalette.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WizardPalette.ink.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "arrow.right")
                .font(.headline)
                .foregroundStyle(WizardPalette.red)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(WizardPalette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.24), radius: 14, y: 8)
    }

    private var regular: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(WizardPalette.red)
                .frame(width: 36, height: 36)
                .background(WizardPalette.red.opacity(0.11), in: Circle())
            Text(name)
                .font(.headline)
                .foregroundStyle(WizardPalette.ink)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(WizardPalette.ink.opacity(0.58))
                    .lineLimit(1)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 114, alignment: .topLeading)
        .background(WizardPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 9, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A search result. Results are a list rather than a grid because there the
/// eye is matching a name it already has in mind.
struct LogPlaceRow: View {
    let name: String
    let subtitle: String
    let symbol: String
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(WizardPalette.red)
                    .frame(width: 40, height: 40)
                    .background(WizardPalette.red.opacity(0.11), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(WizardPalette.ink)
                        .multilineTextAlignment(.leading)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(WizardPalette.ink.opacity(0.58))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(WizardPalette.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(WizardPalette.red.opacity(0.11), in: Capsule())
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(WizardPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(BouncyPressStyle())
    }
}

// MARK: - Questions

/// One answer to a question. The card says which answer was taken: it lifts,
/// its badge fills and gains a check, and the answers not taken fall back.
struct WizardOptionCard: View {
    enum Layout { case stacked, wide, compact }

    let option: WizardOption
    let isSelected: Bool
    /// True while another answer has just been picked on this screen.
    let isPassedOver: Bool
    var layout: Layout = .stacked
    let action: () -> Void

    private var tint: Color { WizardPalette.tint(option.tone) }

    var body: some View {
        Button(action: action) {
            Group {
                switch layout {
                case .stacked:
                    VStack(spacing: 12) { emblem(size: 58); caption(size: 21) }
                        .frame(maxWidth: .infinity, minHeight: 146)
                case .compact:
                    VStack(spacing: 8) { emblem(size: 46); caption(size: 17) }
                        .frame(maxWidth: .infinity, minHeight: 112)
                case .wide:
                    HStack(spacing: 16) { emblem(size: 62); caption(size: 28); Spacer(minLength: 0) }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                }
            }
            .padding(12)
            .background(WizardPalette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(WizardPalette.card, tint)
                        .padding(10)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(tint, lineWidth: isSelected ? 4 : 0)
            }
            .shadow(color: .black.opacity(isSelected ? 0.34 : 0.18), radius: isSelected ? 18 : 10, y: isSelected ? 10 : 5)
            .scaleEffect(isPassedOver ? 0.93 : 1)
            .opacity(isPassedOver ? 0.42 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(BouncyPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.glyph.map { "\(option.title), \($0)" } ?? option.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Named to stay clear of SwiftUI's own `badge(_:)` modifier, which an
    /// integer literal would silently pick instead and wrap the card in itself.
    @ViewBuilder
    private func emblem(size: CGFloat) -> some View {
        if let glyph = option.glyph {
            Text(glyph)
                .font(BBTheme.display(size * 0.5, weight: .bold))
                .foregroundStyle(isSelected ? WizardPalette.card : tint)
                .padding(.horizontal, 14)
                .frame(minWidth: size, minHeight: size)
                .background(isSelected ? tint : tint.opacity(0.12), in: Capsule())
        } else if let symbol = option.symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(isSelected ? WizardPalette.card : tint)
                .symbolEffect(.bounce, value: isSelected)
                .frame(width: size, height: size)
                .background(isSelected ? tint : tint.opacity(0.12), in: Circle())
        }
    }

    private func caption(size: CGFloat) -> some View {
        Text(option.title)
            .font(BBTheme.display(size))
            .foregroundStyle(WizardPalette.ink)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
    }
}

/// A person, a known dish, an answer on the recap: anything small that can be
/// tapped on the red stage.
struct WizardChip: View {
    let title: String
    var symbol: String? = nil
    var isSelected = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.footnote.weight(.bold)) }
                Text(title).lineLimit(1)
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 15)
            .frame(minHeight: 46)
            .foregroundStyle(isSelected ? WizardPalette.redDeep : WizardPalette.cream)
            .background(isSelected ? WizardPalette.card : WizardPalette.cream.opacity(0.16), in: Capsule())
            .overlay { Capsule().stroke(WizardPalette.cream.opacity(isSelected ? 0 : 0.32), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(BouncyPressStyle())
        .animation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0.4), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Ranking

/// A number that counts its way to a new value instead of snapping to it.
struct RollingNumber: View, @preconcurrency Animatable {
    var value: Double
    /// Spoken value. Kept apart from the animated one so VoiceOver reads the
    /// real score rather than whatever frame the count happens to be on.
    let label: String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Int(value.rounded()), format: .number)
            .monospacedDigit()
            .accessibilityLabel(label)
    }
}

struct LadderRow: Identifiable, Equatable {
    let id: UUID
    let rank: Int
    let name: String
    let isFocus: Bool
}

/// The few places either side of the one just logged. Rows keep their identity
/// as the order changes, so answering a face-off makes them trade places.
/// There are no scores here: the ladder is about order.
struct RankLadder: View {
    let rows: [LadderRow]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Text("\(row.rank)")
                        .font(BBTheme.score(20))
                        .contentTransition(.numericText(value: Double(row.rank)))
                        .frame(minWidth: 26, alignment: .leading)
                    Text(row.name)
                        .font(row.isFocus ? .headline : .subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if row.isFocus {
                        Image(systemName: "sparkle")
                            .font(.footnote.weight(.bold))
                    }
                }
                .padding(.horizontal, 15)
                .frame(minHeight: row.isFocus ? 50 : 40)
                .foregroundStyle(row.isFocus ? WizardPalette.redDeep : WizardPalette.cream)
                .background(
                    row.isFocus ? WizardPalette.card : WizardPalette.cream.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .padding(.horizontal, row.isFocus ? 0 : 14)
                .shadow(color: .black.opacity(row.isFocus ? 0.26 : 0), radius: 12, y: 6)
                .zIndex(row.isFocus ? 1 : 0)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rank \(row.rank), \(row.name)\(row.isFocus ? ", just logged" : "")")
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.34), value: rows)
    }
}

/// One side of a face-off.
struct FaceOffCard: View {
    enum Verdict { case undecided, chosen, passedOver }

    let name: String
    let detail: String
    let symbol: String
    let verdict: Verdict
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(WizardPalette.cream)
                    .frame(width: 46, height: 46)
                    .background(WizardPalette.red, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(BBTheme.display(21))
                        .foregroundStyle(WizardPalette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WizardPalette.ink.opacity(0.58))
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if verdict == .chosen {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(WizardPalette.red)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(WizardPalette.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(verdict == .chosen ? 0.34 : 0.18), radius: verdict == .chosen ? 16 : 9, y: 6)
            .scaleEffect(verdict == .chosen ? 1.03 : (verdict == .passedOver ? 0.95 : 1))
            .opacity(verdict == .passedOver ? 0.45 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(BouncyPressStyle())
        .allowsHitTesting(verdict == .undecided)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.isEmpty ? name : "\(name), \(detail)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A short burst of confetti. Fired by changing `trigger`; it draws nothing
/// and costs nothing between bursts.
struct CelebrationBurst: View {
    let trigger: Int
    var particleCount = 28

    private static let duration = 1.6
    private static let palette: [Color] = [
        WizardPalette.card,
        Color(red: 0.98, green: 0.78, blue: 0.36),
        Color(red: 0.97, green: 0.55, blue: 0.30),
        Color(red: 0.72, green: 0.84, blue: 0.62),
        Color(red: 0.99, green: 0.62, blue: 0.68)
    ]

    @State private var startedAt: Date?

    var body: some View {
        TimelineView(.animation(paused: startedAt == nil)) { timeline in
            Canvas { context, size in
                guard let startedAt else { return }
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                guard elapsed >= 0, elapsed < Self.duration else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.34)
                let fade = max(0, 1 - pow(elapsed / Self.duration, 3))
                for index in 0..<particleCount {
                    let angle = -Double.pi * (0.06 + 0.88 * Self.unit(index, 1))
                    let speed = 300 + 620 * Self.unit(index, 2)
                    let travel = speed * elapsed * (1 - 0.3 * elapsed)
                    let x = origin.x + cos(angle) * travel
                    let y = origin.y + sin(angle) * travel + 420 * elapsed * elapsed
                    let side = 8 + 9 * Self.unit(index, 3)
                    var particle = context
                    particle.opacity = fade
                    particle.translateBy(x: x, y: y)
                    particle.rotate(by: .radians(elapsed * (Self.unit(index, 4) - 0.5) * 18))
                    let rect = CGRect(x: -side / 2, y: -side / 3, width: side, height: side * 0.62)
                    let shape = index.isMultiple(of: 3)
                        ? Path(ellipseIn: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
                        : Path(roundedRect: rect, cornerRadius: 2)
                    particle.fill(shape, with: .color(Self.palette[index % Self.palette.count]))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in startedAt = .now }
        .task(id: startedAt) {
            guard startedAt != nil else { return }
            try? await Task.sleep(for: .seconds(Self.duration))
            if !Task.isCancelled { startedAt = nil }
        }
    }

    /// A repeatable value in 0..<1, so a burst looks scattered without the
    /// view holding any random state.
    private static func unit(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43_758.5453
        return value - floor(value)
    }
}
