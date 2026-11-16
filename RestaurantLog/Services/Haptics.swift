import UIKit

@MainActor
enum Haptics {
    /// Mirrors the "Subtle haptics" toggle in Settings. On unless explicitly disabled.
    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }
    static func selection() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func impact() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    /// A light tick for small things: a chip, a skip, a step back.
    static func tick() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.8)
    }
    /// A crisp click for choosing an answer.
    static func snap() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
    /// A soft bump for something settling downward.
    static func soft() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
    /// A heavy thump for a moment that lands: a rank won, a score unlocked.
    static func thump() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
}
