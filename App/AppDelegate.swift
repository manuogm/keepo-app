import UIKit
import UserNotifications

/// Exists for one reason: `UNUserNotificationCenterDelegate` needs an
/// object to own it, and SwiftUI's `App` protocol has no hook for that —
/// `KeepoApp` wires this in via `@UIApplicationDelegateAdaptor`. Owns
/// nothing else; every other launch-time concern (`MetricKitSubscriber`,
/// `RootView`'s own state) stays exactly where it already was.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // A fresh process starts with nothing registered in
        // `UNUserNotificationCenter` at all, even for a capture notification
        // still sitting in Notification Center from before the last
        // terminate — this re-registers its quick-action buttons and drops
        // any entry for a notification the user already cleared meanwhile.
        Task { await CaptureQuickActionRegistry.reconcileWithDelivered() }
        return true
    }

    /// Without this, a capture notification never shows a banner while
    /// Keepo is already foregrounded (iOS suppresses foreground banners by
    /// default) — a real case here, since the app can be open to some other
    /// tab when a background capture completes.
    ///
    /// The completion-handler overload, not the `async` one — real crash
    /// this replaced, root-caused via a symbolicated crash report (device
    /// logs alone only showed raw addresses; reproduced in the Simulator to
    /// get the full trace): `NSInternalInconsistencyException: 'Call must
    /// be made on main thread'`, thrown from inside `UIApplication`'s own
    /// `_updateStateRestorationArchiveForBackgroundEvent:...` — UIKit's
    /// state-restoration snapshot, which it runs automatically the instant
    /// an `async` `UNUserNotificationCenterDelegate` method completes. That
    /// completion is signaled through a Swift-generated async-to-ObjC
    /// bridging thunk (visible in the trace as `@objc closure #1 in
    /// AppDelegate.userNotificationCenter(_:didReceive:)`), and UIKit's own
    /// bookkeeping doesn't reliably recognize that as having happened on
    /// the main thread — an `async`/UIKit interop gap, not something fixable
    /// by hopping to main *inside* the method (tried both `await MainActor
    /// .run` and `DispatchQueue.main.async`; both still crashed, since the
    /// crash happens in UIKit code that runs *after* our function already
    /// returned). The old-style `withCompletionHandler:` overload never
    /// routes through that bridge at all.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// The default tap and the quick-action "More options" button both mean
    /// the same thing — deep-link into the full review form — and read the
    /// transaction id `CaptureIntent` attached the same way
    /// (`NotificationRouter.transactionIdKey`). Absent for every
    /// notification kind that doesn't set it (the balance reminder, a
    /// queued/fallback capture), which just opens the app normally,
    /// unchanged from before this file existed. `DispatchQueue.main.async`
    /// for the state mutation itself — this delegate callback isn't
    /// guaranteed to arrive on the main thread.
    ///
    /// Every other action identifier (Confirm, a category/account pick,
    /// Delete) never opens the app at all — `CaptureQuickActionHandler`
    /// does the write in the background, and `completionHandler` is only
    /// called once that finishes, not immediately, so iOS doesn't suspend
    /// the process mid-write.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let isDeepLink = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == CaptureQuickActions.moreActionId
        if isDeepLink {
            if let idString = userInfo[NotificationRouter.transactionIdKey] as? String,
               let id = UUID(uuidString: idString) {
                DispatchQueue.main.async {
                    NotificationRouter.shared.pendingCaptureId = id
                }
            }
            completionHandler()
            return
        }

        // `UNNotificationResponse` isn't `Sendable`, so every plain value
        // `CaptureQuickActionHandler` needs is pulled out here, before
        // crossing into the `Task` — only the resulting `Request` value
        // (and `completionHandler`) gets captured across that boundary.
        guard let idString = userInfo[NotificationRouter.transactionIdKey] as? String,
              let transactionId = UUID(uuidString: idString)
        else {
            completionHandler()
            return
        }
        let request = CaptureQuickActionHandler.Request(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            transactionId: transactionId, pickKind: userInfo[CaptureQuickActions.pickKindKey] as? String,
            pickIds: userInfo[CaptureQuickActions.pickIdsKey] as? [String]
        )
        // `completionHandler`'s declared type (`@escaping () -> Void`, from
        // the `UNUserNotificationCenterDelegate` protocol) isn't marked
        // `@Sendable`, so the strict-concurrency checker can't verify a
        // capture into `Task` is safe on its own — it is safe here (called
        // exactly once, after the write above finishes, never touched
        // concurrently), the same class of case `Outbox.swift`'s own
        // `retryTask` already documents this project's use of
        // `nonisolated(unsafe)` for.
        nonisolated(unsafe) let completion = completionHandler
        Task {
            await CaptureQuickActionHandler.handle(request)
            completion()
        }
    }
}
