import KeepoCore
import SwiftUI

/// What the transaction form says under an amount it cannot save — one
/// sentence naming the actual problem, because "Enter a valid amount."
/// named nothing the user could go and fix.
extension AmountIssue {
    var message: String {
        switch self {
        case .notNumeric: "Amount needs to be numeric."
        case .negative: "Amount needs to be positive."
        case .zero: "Amount needs to be more than zero."
        case .tooLarge: "Amount is too large."
        }
    }
}

/// A side-to-side shake, the way a lock screen turns away a wrong passcode.
///
/// A `GeometryEffect` driven by a counter rather than a spring with an
/// offset: bumping the counter by one animates `shakes` whole sine periods
/// from rest back to rest, so the view always lands exactly where it began
/// however often it is turned away, and no state is left to reset.
///
/// `nudges` is the gentle form — one small sway (`Motion.nudge`) for an
/// entry that is missing something rather than wrong.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    private let travel: CGFloat
    private let shakes: CGFloat

    init(rejections: Int) {
        animatableData = CGFloat(rejections)
        travel = AppTheme.Spacing.s
        shakes = 3
    }

    /// How long a refused entry stays on screen before it clears itself:
    /// the shake (`Motion.reject`, 0.4s) and a beat after it to read the
    /// red. The lock screen's rhythm — the pairing code and sign-in's email
    /// field both empty on it.
    static let rejectionHold: Duration = .milliseconds(800)

    init(nudges: Int) {
        animatableData = CGFloat(nudges)
        travel = AppTheme.Spacing.xs
        shakes = 1
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: travel * sin(animatableData * .pi * 2 * shakes), y: 0)
        )
    }
}
