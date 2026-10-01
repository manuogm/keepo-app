import SwiftUI

/// What privacy mode replaces a figure with, in one place. Four views were
/// each spelling the same four bullets inline, which is three too many for a
/// string that has to be identical everywhere it appears — a screen showing
/// `•••` beside another showing `••••` reads as a rendering fault.
enum PrivacyMask {
    static let hidden = "••••"
}

/// A figure that hides itself when privacy mode is on.
///
/// Only the *headline* on each dashboard tile used to do this
/// (`BalanceHeaderView`, and `MetricHeadline` through it). Everything smaller
/// beside it stayed perfectly readable, so turning privacy on blanked one
/// number per widget and left the breakdown under it — Cashflow's money in
/// and out, every category's amount, every account's balance — fully legible.
/// That is not privacy, it is a larger font.
///
/// One view rather than a fifth `isPrivacyMode ? "••••" : …`, because the
/// mask, the cross-fade, and the digit treatment are one decision. `—` is
/// masked along with everything else: privacy mode says "not shown", and
/// leaving the em dash visible would tell a shoulder-surfer which figures the
/// app could and could not compute.
struct PrivateText: View {
    let text: String
    /// What VoiceOver reads in place of `text`: the exact figure behind a
    /// short one, so "$56.8K" is heard as "$56,846.50" — a screen reader
    /// has no width to run out of. Masked like the text in privacy mode.
    let spoken: String?

    @Environment(\.isPrivacyMode) private var isPrivacyMode

    init(_ text: String, spoken: String? = nil) {
        self.text = text
        self.spoken = spoken
    }

    var body: some View {
        Text(isPrivacyMode ? PrivacyMask.hidden : text)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(AppTheme.Motion.colorSafe, value: isPrivacyMode)
            .accessibilityLabel(isPrivacyMode ? PrivacyMask.hidden : spoken ?? text)
    }
}
