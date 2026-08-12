import Foundation
import UserNotifications

/// The "Full Experience" notification level's one extra piece over
/// "Functional": a repeating monthly nudge to open Keepo and check in on
/// balances. A fixed, well-known identifier so `cancel()` can always find
/// it — there is only ever at most one of these pending.
enum BalanceReminderScheduler {
    private static let identifier = "keepo.balance-reminder.monthly"

    /// 1st of the month, 10:00 local time — a fixed default rather than a
    /// user-configurable time, since the request is "remind me monthly,"
    /// not "let me tune a schedule."
    static func schedule() async {
        let center = UNUserNotificationCenter.current()
        let granted = try? await center.requestAuthorization(options: [.alert, .sound])
        guard granted == true else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time for a check-in"
        content.body = "Take a minute to review your balances in Keepo."

        var dateComponents = DateComponents()
        dateComponents.day = 1
        dateComponents.hour = 10
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
