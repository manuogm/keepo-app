import KeepoCore
import SwiftUI

/// The Wallet-automation setup, outside onboarding: for a user who skipped
/// it, changed phones, or deleted the shortcut.
///
/// **It renders `ShortcutsWalkthroughView`, the same view setup step 4
/// renders**, because these are the same instructions. They were not,
/// until now: this screen still described the old six-step procedure where
/// the user built the action themselves and mapped Card, Merchant and
/// Amount by hand — a procedure that stopped existing when Keepo started
/// publishing the shortcut prebuilt. A screen quietly telling people to do
/// something that no longer works is exactly what one shared model
/// prevents.
struct WalletAutomationGuideView: View {
    let session: SessionStore

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    Text(
                        "Keepo can log Apple Pay purchases automatically, but the automation itself lives in "
                            + "Apple's Shortcuts app — this is a one-time setup."
                    )
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    CaptureStatusCard(session: session)

                    ShortcutsWalkthroughView()

                    footnotes
                }
                .padding(AppTheme.Spacing.l)
            }
        }
        .navigationTitle("Apple Pay Capture")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text(
                "A purchase never opens the app — you'll get a notification with the amount, category, and "
                    + "account to glance at, and can tap it to review or fix anything that looks off."
            )
            Text(
                "Apple Pay only, on this device — closed-loop apps (like Walmart Pay) never touch Wallet "
                    + "and can't trigger this automation."
            )
        }
        .font(AppTheme.Typography.caption)
        .foregroundStyle(AppTheme.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Whether capture has ever actually worked on this phone, and the way to
/// remove onboarding's test purchase if one is still around.
///
/// **"Working" means a real purchase arrived, not that the test passed.**
/// The test proves the shortcut and the intent; only a real Apple Pay tap
/// proves the Wallet automation exists and is bound to the right cards,
/// because iOS exposes no way to inspect a personal automation. So this
/// reads `AppSettings.captureVerifiedAt`, which `CaptureIntent` writes on
/// the first capture that is not the test.
struct CaptureStatusCard: View {
    let session: SessionStore

    @State private var hasTestCapture = false
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            if let verifiedAt = AppSettings.captureVerifiedAt {
                Label("Working", systemImage: "checkmark.circle.fill")
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.statusPositive)
                Text("First purchase captured \(verifiedAt.formatted(.relative(presentation: .named))).")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            } else {
                Label("Waiting for your first purchase", systemImage: "clock")
                    .font(AppTheme.Typography.bodyEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Text("Keepo confirms the automation the moment a real tap-payment lands.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }

            if hasTestCapture {
                Divider()
                // Offered for as long as one exists. The test capture is
                // never auto-deleted — the user made it and the user
                // removes it — so backgrounding the app mid-setup must not
                // be able to strand it with nothing left pointing at it.
                Button {
                    Task { await deleteTestCapture() }
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Text("Delete test purchase")
                            .font(AppTheme.Typography.labelEmphasis)
                            .foregroundStyle(AppTheme.Palette.statusNegative)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.surface))
        .task(id: session.refresh.token) {
            hasTestCapture = (try? await session.dbQueue.read { try TestCaptureQueries.exists($0) }) ?? false
        }
    }

    private func deleteTestCapture() async {
        isDeleting = true
        try? await session.dbQueue.write { try TestCaptureQueries.delete($0) }
        session.refresh.bump()
        hasTestCapture = false
        isDeleting = false
    }
}
