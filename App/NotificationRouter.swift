import Foundation
import Observation

/// The seam between `AppDelegate`'s notification-tap handling and
/// `RootView`'s presentation layer — a tapped capture notification sets
/// `pendingCaptureId`, `RootView` observes it and opens `TransactionFormView`
/// prefilled on that row. A plain `@Observable` singleton, not passed through
/// the view hierarchy, because `AppDelegate` (a `UIApplicationDelegateAdaptor`,
/// constructed before any `View`) has no view-hierarchy path to `RootView`
/// to hand it through otherwise.
@MainActor
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()

    /// The key `CaptureIntent` writes into a notification's `userInfo` and
    /// `AppDelegate` reads back out — one shared constant so the two never
    /// drift apart. `nonisolated` — it's an immutable string literal, not
    /// state, and `CaptureIntent` (an App Intent, not main-actor-isolated)
    /// needs to read it too.
    nonisolated static let transactionIdKey = "transactionId"

    var pendingCaptureId: UUID?

    private init() {}
}
