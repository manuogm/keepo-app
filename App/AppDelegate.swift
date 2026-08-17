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

    /// Reads the transaction id `CaptureIntent` attached (see
    /// `NotificationRouter.transactionIdKey`) and hands it to `RootView` via
    /// `NotificationRouter` — absent for every notification kind that
    /// doesn't set it (the balance reminder, a queued/fallback capture),
    /// which just opens the app normally, unchanged from before this file
    /// existed. `DispatchQueue.main.async` for the state mutation itself —
    /// this delegate callback isn't guaranteed to arrive on the main thread.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let idString = userInfo[NotificationRouter.transactionIdKey] as? String,
           let id = UUID(uuidString: idString) {
            DispatchQueue.main.async {
                NotificationRouter.shared.pendingCaptureId = id
            }
        }
        completionHandler()
    }
}
