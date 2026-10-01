import Foundation
import UserNotifications

/// The one place in Keepo that asks iOS for notification permission.
///
/// **There has to be exactly one, because iOS only ever asks once.** After
/// the first answer, `requestAuthorization` silently replays it forever —
/// so a second call site is not a second chance, it is a call that looks
/// like it did something and did not. Every screen that wants the
/// permission goes through here.
///
/// It used to live as a private method on `OnboardingView`, which was
/// deleted with that flow; setup step 4 asks now, behind an explicit
/// button and after explaining why (HIG, and measurably better for grant
/// rate — a permission sheet that appears because a timer expired reads as
/// an ambush). `NotificationSettingsView` still asks defensively on the
/// deliberate act of picking a level, for a returning user who never saw
/// setup.
enum NotificationPermission {
    /// Asks only when iOS has genuinely never been asked. Returns the
    /// status *after* the attempt, which is the answer the caller can act
    /// on — `.denied` is the one state no app can fix from the inside.
    @discardableResult
    static func requestIfNeeded() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .notDetermined else { return status }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await center.notificationSettings().authorizationStatus
    }

    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
