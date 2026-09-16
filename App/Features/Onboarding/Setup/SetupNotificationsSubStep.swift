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
            onSkip: skip,
            onPrimary: onNext
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                NotificationPreviewCard()
                permissionControl
            }
        }
        .task {
            status = await NotificationPermission.status()
        }
    }

    @ViewBuilder
    private var permissionControl: some View {
        switch status {
        case .notDetermined:
            OnboardingPrimaryButton(title: "Turn on notifications", isLoading: isAsking, fillsWidth: true) {
                Task { await ask() }
            }
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
        default:
            Label("Notifications are on", systemImage: "checkmark.circle.fill")
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.statusPositive)
        }
    }

    private func ask() async {
        isAsking = true
        status = await NotificationPermission.requestIfNeeded()
        // Recorded whatever the answer was: iOS will not ask again, so a
        // later screen offering the button a second time would be offering
        // something that cannot work.
        store.update { $0.notificationAsked = true }
        isAsking = false
    }

    private func skip() {
        store.update { $0.notificationAsked = false }
        onNext()
    }
}

/// What a capture actually looks like — an honest still of the
/// notification, not an illustration of one.
///
/// It is drawn from the same copy `CaptureNotificationCopy` produces and
/// the same quick actions `CaptureNotificationScheduler` attaches, so it
/// cannot promise a shape the real thing does not have.
private struct NotificationPreviewCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.s) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control * 0.5)
                    .fill(AppTheme.Palette.brandPrimary)
                    .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
                    .overlay(
                        Text("K")
                            .font(AppTheme.Typography.captionEmphasis)
                            .foregroundStyle(AppTheme.Palette.textOnAccent)
                    )
                Text("KEEPO")
                    .font(AppTheme.Typography.nano)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Spacer(minLength: 0)
                Text("now")
                    .font(AppTheme.Typography.nano)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
            Text("Logged $12.34")
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Text("Groceries · Checking. Tap to change anything.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
        .padding(AppTheme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example notification: Logged 12 dollars 34, Groceries, Checking.")
    }
}
