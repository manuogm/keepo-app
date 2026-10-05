import SwiftUI

/// How much of a figure an expanded widget's line is showing.
///
/// Collapsed, every widget figure is the short form ("$56.8K") — a tile is
/// read at a glance. Expanded, the widget has the width for more, so the
/// exact figure is shown **whenever it fits its line as laid out**; when it
/// does not, the short form stays, with a chevron. The chevron reveals the
/// exact figure by clearing the line: whatever shares it (Upcoming's counts,
/// Cashflow's In/Out toggle) steps aside until the figure is shortened
/// again, and comes back with it.
struct FigureFit {
    enum Form { case exact, short, revealed }

    let form: Form
    let toggle: () -> Void

    /// Draw the exact figure — it fits, or the user asked for it.
    var showsExact: Bool { form != .short }
    /// Everything else on the line steps aside for the revealed figure.
    var clearsLine: Bool { form == .revealed }
}

/// Picks a `FigureFit` for one line: exact if the whole line fits with it,
/// short otherwise, revealed once the chevron is tapped.
///
/// `row` is drawn once per candidate and `ViewThatFits` keeps the first
/// whose ideal width fits, so the test is the real line — figure, chevron
/// and neighbours — at full size, before any `minimumScaleFactor` gets a
/// chance to shrink an exact figure into "fitting".
///
/// The reveal is local state, so it ends with the expanded layout itself:
/// collapsing the widget removes this view, and a widget always reopens in
/// its known state.
struct FittingFigure<Row: View>: View {
    @ViewBuilder let row: (FigureFit) -> Row

    @State private var isRevealed = false

    var body: some View {
        if isRevealed {
            row(fit(.revealed))
        } else {
            ViewThatFits(in: .horizontal) {
                row(fit(.exact))
                row(fit(.short))
            }
        }
    }

    private func fit(_ form: FigureFit.Form) -> FigureFit {
        FigureFit(form: form) {
            withAnimation(AppTheme.Motion.standard) { isRevealed.toggle() }
        }
    }
}

/// The chevron beside a short or revealed figure — none beside one that
/// simply fits. Points the way the figure will go: right to open it out,
/// left to shorten it again (the amount field's chevron, same directions).
struct FigureFitToggle: View {
    let fit: FigureFit

    var body: some View {
        if fit.form != .exact {
            Button(action: fit.toggle) {
                Image(systemName: fit.clearsLine ? "chevron.left" : "chevron.right")
                    .font(AppTheme.Typography.microEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    // Beside the figure, where a miss collapses the widget.
                    .hitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(fit.clearsLine ? "Show the short amount" : "Show the full amount")
        }
    }
}
