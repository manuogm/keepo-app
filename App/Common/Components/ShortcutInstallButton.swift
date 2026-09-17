import KeepoCore
import SwiftUI
import UIKit

/// The one tap that replaces what used to be the whole setup procedure.
///
/// Its own type because three places need it: onboarding's checklist, the
/// full walkthrough in Profile → My Automations, and — the reason it is not
/// simply a method on one of them — a user who deleted the shortcut and is
/// re-adding it later. All three must offer the identical button, including
/// the written fallback behind it.
///
/// `ShortcutsInstaller` tries the direct `shortcuts://import-shortcut` path
/// and drops to the icloud.com share page on its own, so only the case where
/// *neither* opened reaches the alert here.
struct ShortcutInstallButton: View {
    var onInstallFailed: (() -> Void)?

    @State private var isShowingManualFallback = false

    private var configuredURL: URL? { (try? SupabaseConfig.fromInfoPlist())?.url }

    var body: some View {
        Button {
            Task {
                if await ShortcutsInstaller.install(functionsBaseURL: configuredURL) == .failed {
                    isShowingManualFallback = true
                    onInstallFailed?()
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.s) {
                Image(systemName: "square.and.arrow.down")
                Text("Add Shortcut")
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
}
