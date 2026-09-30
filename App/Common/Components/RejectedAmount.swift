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
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    private let travel = AppTheme.Spacing.s
    private let shakes: CGFloat = 3

    init(rejections: Int) {
        animatableData = CGFloat(rejections)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: travel * sin(animatableData * .pi * 2 * shakes), y: 0)
        )
    }
}
