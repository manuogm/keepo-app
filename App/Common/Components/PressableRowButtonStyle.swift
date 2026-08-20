import SwiftUI

/// Why this exists: every tappable row in the app used to be a plain view
/// with `.onTapGesture`. That is the single biggest reason the UI felt
/// unresponsive, for two compounding reasons:
///
///   1. A bare tap gesture inside a `List` competes with the scroll view's
///      own recognizer. Immediately after a scroll settles, the first tap is
///      routinely swallowed — the "I had to tap twice" symptom.
///   2. It draws no press state at all. A row that shows nothing between
///      finger-down and the sheet appearing reads as broken even when it is
///      working perfectly, because the only feedback is whatever comes after
///      the work finishes.
///
/// A `Button` with this style fixes both: SwiftUI's button machinery
/// coordinates with the scroll recognizer properly, and the press state is
/// drawn on the very first frame of the touch — before any `await`, any
/// database read, any sheet presentation.
struct PressableRowButtonStyle: ButtonStyle {
    /// Rows inside a `List` already sit on their own background, so they
    /// dim rather than draw a second surface; free-standing cards get the
    /// scale instead, which reads better without a row separator to anchor it.
    enum Emphasis {
        case row
        case card
    }

    var emphasis: Emphasis = .row

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(scale(isPressed: configuration.isPressed))
            // Fast in, gentle out: the press must register instantly, but a
            // snap back on release looks twitchy.
            .animation(
                configuration.isPressed ? .easeOut(duration: 0.08) : .easeOut(duration: 0.18),
                value: configuration.isPressed
            )
    }

    private func scale(isPressed: Bool) -> CGFloat {
        guard emphasis == .card else { return 1 }
        return isPressed ? 0.975 : 1
    }
}

extension ButtonStyle where Self == PressableRowButtonStyle {
    /// Tappable rows in a `List`.
    static var pressableRow: PressableRowButtonStyle { PressableRowButtonStyle(emphasis: .row) }
    /// Free-standing tappable cards and tiles.
    static var pressableCard: PressableRowButtonStyle { PressableRowButtonStyle(emphasis: .card) }
}
