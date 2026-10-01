import KeepoCore
import SwiftUI
import UIKit

/// The four steps of wiring a Wallet automation to Keepo, rendered from
/// `ShortcutsWalkthrough` — which is the only copy of those instructions in
/// the app.
///
/// **Two callers, one implementation**: setup step 4 and Profile → My
/// Automations. They used to be two hand-written lists, and the Profile one
/// still described the six-step variable-mapping procedure that shipping
/// the prebuilt shortcut deleted — a screen quietly telling users to do
/// something that no longer exists, which is exactly the drift the shared
/// model was introduced to stop.
///
/// A list, not a pager. The steps are short, the user is holding a phone
/// they are about to leave for Shortcuts, and being able to see step 4
/// while doing step 2 is the difference between following instructions and
/// remembering them.
struct ShortcutsWalkthroughView: View {
    /// Setup shows the install button; Profile shows it too, because a user
    /// who deleted the shortcut needs exactly that. The difference is only
    /// that setup is the one that also offers the test.
    var onInstallFailed: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            ShortcutInstallButton(onInstallFailed: onInstallFailed)

            ForEach(ShortcutsWalkthrough.steps) { step in
                stepRow(step)
            }

            openShortcutsButton
        }
    }

    // MARK: - Pieces

    private func stepRow(_ step: WalkthroughStep) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
            Text("\(step.id)")
                .font(AppTheme.Typography.captionEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
                .background(AppTheme.Palette.brandPrimary, in: Circle())

            VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                Text(step.title)
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                if let detail = step.detail {
                    Text(detail)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Sits beside its written step, never instead of it — a
                // video-only instruction excludes VoiceOver users and
                // anyone with Reduce Motion on, and Shortcuts' UI will move
                // again long before these words stop being true.
                WalkthroughClipView(clip: step.clip)
                    .frame(maxWidth: AppTheme.Size.proseWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var openShortcutsButton: some View {
        if CaptureTestSession.canRunShortcuts, let url = URL(string: "shortcuts://") {
            Button("Open Shortcuts") { UIApplication.shared.open(url) }
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .frame(maxWidth: .infinity, minHeight: AppTheme.Size.touchTarget)
                .background(AppTheme.Palette.bgSurface, in: Capsule())
        }
    }
}
