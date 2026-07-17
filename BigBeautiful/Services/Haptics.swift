import UIKit

@MainActor
enum Haptics {
    static func selection(enabled: Bool = true) {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func success(enabled: Bool = true) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func impact(enabled: Bool = true) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
