import KeepoCore
import SwiftUI
import UIKit
import UserNotifications

/// Step 4a — why notifications, then an explicit ask.
///
/// **The explanation is not marketing, it is the feature's actual shape.**
/// A captured purchase never opens Keepo: the notification *is* the review
/// surface, carrying the amount, the category and quick actions to confirm
/// or fix it without launching anything. Without permission, capture still
/// works and the user simply never finds out a purchase was recorded until
/// they open the app — which is a materially worse product, and worth one
/// screen to say so.
///
/// The ask goes through `NotificationPermission`, the one place in the app
/// that calls `requestAuthorization` — iOS answers once, ever, so a second
/// call site is a call that looks like it did something and did not.
struct SetupNotificationsSubStep: View {
    let store: OnboardingDraftStore
    let onNext: () -> Void
    let onBack: () -> Void

    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var isAsking = false

    var body: some View {
        OnboardingScaffold(
            title: "Stay on top of your spending",
            subtitle: "A captured purchase arrives as a notification you can confirm or fix "
                + "without opening the app.",
            step: .capture,
            onBack: onBack,
            // **No Skip, and no second button.** This screen used to carry
            // "Turn on notifications" in the content *and* Next in the bar
            // *and* Skip in the chrome — three controls for one decision,
            // two of which did the same thing. Next is now the ask: it
            // raises the system prompt and moves on whatever the answer is,
            // so the screen has exactly one forward action and declining
            // costs nobody an extra tap.
            isPrimaryEnabled: !isAsking,
            onPrimary: askThenAdvance,
            content: {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                    NotificationShowcase(currency: store.draft.baseCurrency)
                    deniedNote
                }
            }
        )
        .task {
            status = await NotificationPermission.status()
        }
    }

    /// The one state no app can fix from the inside, and the only one that
    /// still needs words on this screen.
    @ViewBuilder
    private var deniedNote: some View {
        switch status {
        case .denied:
            // The one state no app can fix from the inside: once "Don't
            // Allow" has been answered, `requestAuthorization` silently
            // replays it forever. So this offers the only thing that works
            // — a direct jump to Keepo's own Settings page — instead of a
            // button that would do nothing.
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                Text("Notifications are turned off for Keepo.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.brandPrimary)
            }
        case .authorized, .provisional, .ephemeral:
            Label("Notifications are on", systemImage: "checkmark.circle.fill")
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.statusPositive)
        default:
            // `.notDetermined` — nothing has been asked yet, and a line
            // saying so would be narrating the absence of an event.
            EmptyView()
        }
    }

    /// Ask, then move on **whatever the answer was**.
    ///
    /// The permission is not a gate: Keepo works without notifications, the
    /// capture still lands, and Needs Review still shows it. So a decline
    /// must not strand anyone on this screen, and the advance is sequenced
    /// after the prompt rather than behind a second tap on it.
    ///
    /// `requestIfNeeded` returns immediately when the answer already exists
    /// — iOS replays a previous "Don't Allow" silently and forever — so
    /// coming back to this screen is Next behaving like Next.
    private func askThenAdvance() {
        Task { await requestThenAdvance() }
    }

    private func requestThenAdvance() async {
        isAsking = true
        status = await NotificationPermission.requestIfNeeded()
        store.update { $0.notificationAsked = true }
        isAsking = false
        onNext()
    }
}
