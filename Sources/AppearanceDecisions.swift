import Foundation

/// The decisions that depend on `#available(macOS 26.0, *)`.
///
/// An availability check can only ever take one branch on the machine running it,
/// so the branches that only older systems take — the bordered button style, and
/// the white shortcut title colour that compensates for the flat accent fill —
/// would otherwise never execute during development or in CI. Each decision is a
/// pure function over the availability flag, so tests cover both branches
/// everywhere; only the reference to the macOS 26 types stays behind the check.
enum AppearanceDecisions {
    enum ProminentButtonStyle: Equatable {
        case glass
        case bordered
    }

    enum ShortcutTitleColor: Equatable {
        case white
        case label
        case disabled
    }

    /// `.glassProminent` exists on macOS 26 and later; everything older keeps the
    /// bordered style it had before.
    static func prominentButtonStyle(glassAvailable: Bool) -> ProminentButtonStyle {
        glassAvailable ? .glass : .bordered
    }

    /// Called every time the view moves to a window, so it must not install a
    /// second background.
    static func shouldInstallGlass(glassAvailable: Bool, alreadyInstalled: Bool) -> Bool {
        glassAvailable && !alreadyInstalled
    }

    /// White is only readable on the flat accent fill used while recording without
    /// glass; with glass, and otherwise, the standard label colours apply.
    static func shortcutTitleColor(isRecording: Bool, usesGlass: Bool, isEnabled: Bool) -> ShortcutTitleColor {
        if isRecording, !usesGlass { return .white }
        return isEnabled ? .label : .disabled
    }

    /// Whether this process can use the macOS 26 Liquid Glass types at all.
    static var isGlassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}
