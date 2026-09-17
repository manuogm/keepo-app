import KeepoCore
import SwiftUI

/// The question the celebration is not allowed to ask: what happens to the
/// purchase Keepo just invented.
///
/// **A sheet rather than two buttons under the tile.** The test capture is
/// never auto-deleted — the user made it, so the user removes it — but the
/// screen that says capture works is the wrong place to also ask somebody to
/// tidy up. Separated, the celebration gets to be a celebration and the
/// housekeeping gets a direct question with two answers.
///
/// Swiping it away answers Keep, which is why neither answer is destructive
/// by default and why the same offer stays in Profile → My Automations for
/// as long as a test purchase exists.
struct TestPurchaseDecisionSheet: View {
    let capture: TestCaptureQueries.TestCapture
    let baseCurrency: String?
    let onDecide: (CaptureConnectionTestView.TestPurchaseDecision) -> Void

    @Environment(\.dismiss) private var dismiss

    /// What the detent is set to, measured from the content rather than
    /// guessed at.
    ///
    /// **A sheet this small has to hug.** `presentationDetents` takes a
    /// number, not "whatever this is tall", so the height was a constant —
    /// and a constant is wrong twice over: tuned to look right it still left
    /// a band of empty canvas under the buttons, and it cannot survive a
    /// larger Dynamic Type size, where the question wraps to a third line and
    /// the content grows past whatever was typed in. Measuring it makes the
    /// sheet exactly as tall as what is in it, at any type size.
    ///
    /// Seeded near the real value so the first frame is not a zero-height
    /// sheet snapping open.
    @State private var contentHeight: CGFloat = 260

    var body: some View {
        ZStack(alignment: .bottom) {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                Text("What do you want Keepo to do with the Test purchase?")
                    // A step up from `rowTitle`: on a sheet that now hugs its
                    // content there is room for the question to carry the
                    // weight it deserves, and `cardTitle` is what a card's
                    // own heading takes elsewhere.
                    .font(AppTheme.Typography.cardTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                TestCaptureCard(capture: capture, baseCurrency: baseCurrency)

                HStack(spacing: AppTheme.Spacing.m) {
                    OnboardingSecondaryButton(title: "Keep it", fillsWidth: true) { answer(.keep) }
                    OnboardingPrimaryButton(title: "Delete it", fillsWidth: true) { answer(.delete) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // **`KeepoTabBarMetrics.margin` beside the buttons and under
            // them.** The same inset the tab bar and onboarding's forward
            // button take: an equal gap on both edges is what puts a capsule
            // concentrically inside the device's own corner.
            //
            // **No bottom padding, and the stack is bottom-aligned.** A
            // presented sheet renders taller than the detent it is handed and
            // holds back a strip for the home indicator, and it reports
            // neither: `safeAreaInsets.bottom` reads zero in here, and
            // `ignoresSafeArea` at any depth only made the sheet taller
            // still. Top-aligned, every point of that slack fell *under* the
            // buttons — 62pt of it against 29pt at the sides, and adding or
            // removing padding of my own barely moved it.
            //
            // Anchoring to the bottom spends the slack above the question
            // instead, where it reads as breathing room, and leaves the
            // buttons on the strip the sheet reserves — which measures within
            // a few points of `margin`, so the gap under them matches the gap
            // beside them.
            .padding(.horizontal, KeepoTabBarMetrics.margin)
            .padding(.top, AppTheme.Spacing.xxl)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                contentHeight = height
            }
        }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
    }

    /// Records the answer and closes; the caller acts on it once the sheet
    /// is actually gone.
    private func answer(_ decision: CaptureConnectionTestView.TestPurchaseDecision) {
        onDecide(decision)
        dismiss()
    }
}

/// The captured test purchase: what it was, where it went, and what it cost.
///
/// **Merchant on top, not the category.** `TransactionRow` leads with the
/// category, which is right in a list where every row is a purchase and the
/// category is what distinguishes them — and wrong here, where there is one
/// row and the only question a reader has is *what is this*. "Test purchase"
/// answers it; "Other" would not.
///
/// Everything under that is the list's own vocabulary, because this is still
/// a transaction and should look like one: the category badge, the account
/// line, the capture glyph that marks a row the automation wrote, and a
/// figure in `.ledger` style — an expense drops its minus sign, since the
/// row already says which way the money went.
///
/// The badge is `CategoryIconView` and the figure is `MoneyFormatter`, so
/// nothing that could actually drift from the list is written twice; only
/// the arrangement is, which is the one thing that is deliberately different.
struct TestCaptureCard: View {
    let capture: TestCaptureQueries.TestCapture
    /// Shown when the capture has no currency of its own, which is always:
    /// the test card is by construction mapped to no account, so nothing
    /// ever resolved one. A fixed "USD" was a foreign amount shown to
    /// everybody who does not happen to hold dollars.
    let baseCurrency: String?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            CategoryIconView(icon: capture.categoryIcon, color: Color(hex: capture.categoryColor))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(capture.merchant)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .lineLimit(1)

                HStack(spacing: AppTheme.Spacing.xs) {
                    // Words, not a dash. The row has no account because the
                    // test card is mapped to nothing, and saying so is the
                    // difference between a blank and an explanation.
                    Text("\(capture.categoryName) · \(capture.accountName ?? "No account")")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .lineLimit(1)
                    // The provenance marker every captured row carries, and
                    // it is the truth here: this row really did arrive
                    // through the automation, which is the whole thing being
                    // demonstrated.
                    KeepoIcon(name: "icon-robot", size: AppTheme.Size.glyphNano)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .accessibilityLabel("Captured automatically")
                }
            }

            Spacer(minLength: AppTheme.Spacing.s)

            Text(formattedAmount)
                .font(AppTheme.Typography.bodyEmphasis)
                .monospacedDigit()
                .foregroundStyle(AppTheme.Palette.textPrimary)
        }
        .padding(AppTheme.Spacing.m)
        .frame(maxWidth: .infinity)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var formattedAmount: String {
        guard let code = capture.currency ?? baseCurrency else { return "—" }
        return MoneyFormatter.format(
            capture.amountE4,
            currency: CurrencyInfo(code: code, minorUnit: capture.minorUnit),
            signStyle: .ledger
        )
    }
}
