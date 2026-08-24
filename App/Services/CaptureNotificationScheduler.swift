import Foundation
import KeepoCore
import UserNotifications

/// Builds and schedules the notification for a capture that resolved
/// locally — the one case that gets quick-action buttons. Extracted out of
/// `CaptureIntent` so `SimulateCaptureView` (the only way to exercise this
/// on the Simulator, where the real Wallet automation can't fire) schedules
/// through the exact same path production does, rather than a second,
/// drifting copy.
enum CaptureNotificationScheduler {
    /// Capture confirmations are a "functional" notification (spec:
    /// automatic payment capture) — suppressed only at the "No
    /// Notifications" level, unlike the monthly balance reminder which
    /// needs the "Full Experience" level specifically. Also gates on the
    /// live system `authorizationStatus` (C-06) rather than trusting the
    /// stored preference alone — `notificationLevel` defaults to `.full` on
    /// a fresh install regardless of whether iOS has ever actually been
    /// asked, and `UNUserNotificationCenter.add` no-ops silently rather
    /// than erroring when it hasn't. Mirrors `CaptureIntent`'s own
    /// `notify(title:body:transactionId:)` guard exactly, since this
    /// bypasses that method entirely to build its own richer content.
    static func scheduleAppliedLocally(
        resolution: CaptureLocalWrite.Resolution, amountE4: Int64, transactionId: UUID
    ) async {
        guard AppSettings.notificationLevel != .none else { return }
        guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
        else { return }

        let copy = CaptureNotificationCopy.appliedLocally(resolution, amountE4: amountE4)
        let actionSet = CaptureQuickActions.build(for: resolution)

        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        var userInfo: [String: Any] = [NotificationRouter.transactionIdKey: transactionId.uuidString]
        userInfo.merge(actionSet.userInfo) { _, new in new }
        content.userInfo = userInfo

        // Only register a category (and pay for the accumulate/reconcile
        // machinery) when there's actually a button to show — the "both
        // unknown, not a duplicate" branch has none, same as before this
        // feature existed.
        if !actionSet.actions.isEmpty {
            let categoryIdentifier = "capture.\(transactionId.uuidString)"
            content.categoryIdentifier = categoryIdentifier
            CaptureQuickActionRegistry.register(identifier: categoryIdentifier, actions: actionSet.actions)
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
