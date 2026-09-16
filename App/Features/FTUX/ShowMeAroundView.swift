import KeepoCore
import SwiftUI

/// Everything Keepo teaches, in one place, on demand.
///
/// **The replay, and the reason the tips can stay quiet.** TipKit shows
/// each lesson once and then never again — which is right for an
/// interruption and wrong as the only copy of the information. This screen
/// is where a user who dismissed a tip, or never triggered one, can read
/// all of it without hunting.
///
/// It renders `FTUXLessons`, the same values the tips render, so the two
/// surfaces cannot drift. It also deliberately does **not** re-arm the
/// tips: re-firing six popovers across four screens is a worse answer to
/// "remind me" than a page that simply says all six. Only the spotlight
/// replays, because a gesture has to be *seen* where it happens.
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
        ZStack {
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

                    replayButton
                }
                .padding(AppTheme.Spacing.l)
            }
        }
        .navigationTitle("Show Me Around")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ lesson: FTUXLesson) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
            Image(systemName: lesson.symbol)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.brandPrimary)
                .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(lesson.title)
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text(lesson.message)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Only the scope swipe replays as a coach mark — it is the one lesson
    /// about a gesture, and a gesture has to be pointed at where it
    /// happens. Dismissing this screen is what lets the spotlight land on
    /// the tab underneath it.
    private var replayButton: some View {
        Button {
            ftux.replaySpotlight()
            onClose()
        } label: {
            Text("Show me the header swipe again")
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(maxWidth: .infinity)
                .frame(height: AppTheme.Size.touchTarget)
                .background(AppTheme.Palette.brandPrimary, in: Capsule())
        }
        .buttonStyle(.pressableCard)
    }
}
