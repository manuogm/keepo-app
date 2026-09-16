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

    @State private var isShowingManualFallback = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            installButton

            ForEach(ShortcutsWalkthrough.steps) { step in
                stepRow(step)
            }

            openShortcutsButton
        }
        .alert("Add it by hand", isPresented: $isShowingManualFallback) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "In Shortcuts, tap + and add the Keepo action “\(ShortcutsWalkthrough.actionName)”, then map "
                    + "Merchant, Amount and Card or Pass to the Wallet trigger's matching fields. "
                    + "Name the shortcut “\(ShortcutsWalkthrough.shortcutName)” exactly."
            )
        }
    }

    // MARK: - Pieces

    /// Where the install button points: the `capture-shortcut` Edge
    /// Function's 302, falling back to the published iCloud link when there
    /// is no project configured to redirect through.
    ///
    /// **Read from `SupabaseConfig` rather than hardcoded**, because the
    /// function's URL contains the project ref — which this repo keeps out
    /// of git and injects through the xcconfig. `try?` because a build with
    /// no configuration should still show a working button, not a dead one:
    /// that is exactly what the fallback is for.
    private var installURL: URL? {
        ShortcutsWalkthrough.installURL(functionsBaseURL: (try? SupabaseConfig.fromInfoPlist())?.url)
    }

    /// The one tap that replaces what used to be the whole procedure. A
    /// failure to open drops straight to written instructions rather than
    /// leaving the user on a dead button — the redirect removed the *stale
    /// link* failure, not every failure.
    private var installButton: some View {
        Button {
            guard let url = installURL, UIApplication.shared.canOpenURL(url) else {
                isShowingManualFallback = true
                onInstallFailed?()
                return
            }
            UIApplication.shared.open(url) { opened in
                if !opened {
                    isShowingManualFallback = true
                    onInstallFailed?()
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.s) {
                Image(systemName: "square.and.arrow.down")
                Text("Get the Keepo Capture shortcut")
            }
            .font(AppTheme.Typography.labelEmphasis)
            .foregroundStyle(AppTheme.Palette.textOnAccent)
            .padding(.horizontal, AppTheme.Spacing.l)
            .frame(maxWidth: .infinity)
            .frame(height: AppTheme.Size.touchTarget)
            .background(AppTheme.Palette.brandPrimary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pressableCard)
        .sensoryFeedback(AppTheme.Feedback.buttonPress, trigger: isShowingManualFallback)
    }

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
                Text(step.detail)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
