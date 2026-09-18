import KeepoCore
import SwiftUI

/// Everything Keepo teaches, in one place, on demand.
///
/// **The replay, and the reason a coach mark can be a one-shot.** Each is
/// shown once and then never again — which is right for an interruption and
/// wrong as the only copy of the information. This screen is where a user
/// who dismissed one, or never triggered it, can read all of them without
/// hunting.
///
/// It renders `FTUXLessons` — the same values, glyphs and sentences the
/// coach marks render — so the two surfaces cannot drift, and a lesson
/// reworded for the card is reworded here by the same edit.
///
/// **Show Tips arms all of them again.** Reading a page is not the same as
/// being shown where a gesture happens, and the list cannot point at the
/// header, a row, or a button — so the button hands the whole tour back,
/// one mark per screen as the user reaches it, exactly as a first run has
/// it.
struct ShowMeAroundView: View {
    let ftux: FTUXCoordinator
    /// Closes the **whole Profile sheet**, not just this screen.
    ///
    /// `@Environment(\.dismiss)` would only pop back to Profile, leaving
    /// the replayed spotlight stranded behind a modal — so the button would
    /// appear to do nothing at all. The coach mark points at the scope
    /// banner, which is on the tab underneath.
    let onClose: () -> Void

    var body: some View {
        // **Bottom-aligned, past the safe area.** The button is measured
        // from the screen's own edge rather than from the home indicator's
        // strip, so the gap under it equals the gap beside it — the same
        // `margin` the tab bar and onboarding's forward button take, and
        // the same reason: an equal inset on every side is what puts a
        // capsule concentrically inside the device's corner.
        ZStack(alignment: .bottom) {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    Text("A few things that are easy to miss.")
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(FTUXLessons.all) { lesson in
                        row(lesson)
                    }
                }
                .padding(AppTheme.Spacing.l)
            }
            // At rest the last lesson stops where the fade begins, so
            // nothing is dissolved until the list is actually scrolling.
            .contentMargins(.bottom, Self.fadeRamp, for: .scrollContent)
            // **No top fade.** Every other screen using this hides the
            // navigation bar and hands off to the scope banner; this one is
            // pushed, so the system bar above it already does its own
            // scroll-edge treatment and a second dissolve under it would be
            // two effects on one hand-off.
            .fadingEdges(top: 0, bottom: Self.fadeRamp)
            // **The scroll view stops at the button's top edge.** Running it
            // to the screen's bottom put the last of the fade behind the
            // capsule, where a dissolve nobody can see is just content
            // sliding under an opaque shape. Ending it here spends the whole
            // ramp in the open: a row is gone by the time it reaches the
            // button rather than halfway through going.
            .padding(.bottom, Self.buttonZone)

            showTipsButton
                .padding(.horizontal, KeepoTabBarMetrics.margin)
                .padding(.bottom, KeepoTabBarMetrics.margin)
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Show Me Around")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ lesson: FTUXLesson) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
            // `ScopeGlyph`, like the coach mark's own card: a lesson's
            // symbol is an SF Symbol today and could be one of Keepo's
            // `icon-` assets tomorrow, and neither surface should care.
            // The same ink as the title beside it, which is also how the
            // coach mark draws it. Seven brand-orange glyphs down one page
            // read as seven things asking for attention — the page is a
            // reference, not a call to action.
            ScopeGlyph(name: lesson.symbol)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(lesson.title)
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text(lesson.message)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The rest of the two lessons whose message is only a
                // lead-in. Without it the scope row stops at "3 scopes to
                // filter your data:" and never names one.
                FTUXLessonDetail(lesson: lesson)
                    .padding(.top, AppTheme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The strip the button occupies, measured from the screen's own edge:
    /// its margin plus its height.
    private static let buttonZone = KeepoTabBarMetrics.margin + AppTheme.Size.touchTarget

    /// How far above the button content takes to dissolve completely.
    private static let fadeRamp = AppTheme.Spacing.xxl

    /// Arms every coach mark and gets out of the way. Closing the whole
    /// sheet is what lets the first one land on the tab underneath — see
    /// `onClose`.
    private var showTipsButton: some View {
        Button {
            ftux.replayAll()
            onClose()
        } label: {
            Text("Show Tips")
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(maxWidth: .infinity)
                .frame(height: AppTheme.Size.touchTarget)
                .background(AppTheme.Palette.brandPrimary, in: Capsule())
        }
        .buttonStyle(.pressableCard)
    }
}
