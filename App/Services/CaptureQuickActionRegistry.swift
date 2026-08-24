import Foundation
import UserNotifications

/// Keeps `UNUserNotificationCenter`'s registered notification categories in
/// sync across every still-undelivered capture notification. Each capture
/// gets its own unique `categoryIdentifier` (`"capture.<transactionId>"`, set
/// by `CaptureIntent`) so its buttons can show real per-merchant category/
/// account names — but `setNotificationCategories(_:)` REPLACES the whole
/// registered set rather than merging, so this type keeps a small persisted
/// record of every category currently "live" (belonging to a notification
/// that might still be sitting in Notification Center) and always pushes the
/// full union, never just the one just-registered category.
///
/// Persisted to `UserDefaults`, not the SQLite mirror — this is disposable
/// UI plumbing (which buttons a not-yet-actioned notification shows), never
/// synced, never money data. Not `@MainActor` — `UNUserNotificationCenter`'s
/// own APIs are safe off the main actor, and this must be callable from
/// `AppDelegate`'s `nonisolated` background-delivery handler the same way
/// `CaptureIntent` already calls `UNUserNotificationCenter.current()` from a
/// non-main-actor context.
enum CaptureQuickActionRegistry {
    private static let defaultsKey = "app.keepo.captureQuickActionCategories"

    /// `optionsRawValue`, not a hand-picked flag or two: this record is what
    /// every registered action is rebuilt from in `push`, so anything it
    /// fails to carry is silently dropped on the way to
    /// `UNUserNotificationCenter`. It previously stored only `destructive`,
    /// which is exactly how "More options" lost its `.foreground` and
    /// stopped opening the app — the option was set correctly in
    /// `CaptureQuickActions` and then thrown away here (device testing).
    /// Round-tripping the whole `UNNotificationActionOptions` bitmask means
    /// a future option can't regress the same way.
    private struct StoredAction: Codable {
        let identifier: String
        let title: String
        let optionsRawValue: UInt
    }

    /// Registers one notification's category (its identifier + action set)
    /// and pushes the accumulated union of every still-live category to
    /// `UNUserNotificationCenter`. Call once, right before scheduling the
    /// notification that uses `identifier`.
    static func register(identifier: String, actions: [UNNotificationAction], defaults: UserDefaults = .standard) {
        var stored = load(defaults)
        stored[identifier] = actions.map {
            StoredAction(identifier: $0.identifier, title: $0.title, optionsRawValue: $0.options.rawValue)
        }
        save(stored, defaults)
        push(stored)
    }

    /// Drops one notification's category once it's been acted on, and
    /// pushes the remaining set. Safe to call even if `identifier` was never
    /// registered (e.g. a tap on a notification with no quick actions at
    /// all, the "both unknown, not a duplicate" branch).
    static func unregister(identifier: String, defaults: UserDefaults = .standard) {
        var stored = load(defaults)
        guard stored.removeValue(forKey: identifier) != nil else { return }
        save(stored, defaults)
        push(stored)
    }

    /// Drops entries for notifications no longer sitting in Notification
    /// Center — covers a plain swipe-dismiss, which never calls
    /// `AppDelegate`'s delegate method, so `unregister` never fires for it.
    /// Call at launch (a fresh process starts with nothing registered with
    /// `UNUserNotificationCenter` at all, even though `UserDefaults` still
    /// remembers yesterday's captures) and before each new `register`, so a
    /// long-idle device doesn't accumulate categories for notifications the
    /// user already cleared.
    static func reconcileWithDelivered(defaults: UserDefaults = .standard) async {
        var stored = load(defaults)
        if !stored.isEmpty {
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            let liveIdentifiers = Set(delivered.map(\.request.content.categoryIdentifier))
            stored = stored.filter { liveIdentifiers.contains($0.key) }
            save(stored, defaults)
        }
        push(stored)
    }

    private static func push(_ stored: [String: [StoredAction]]) {
        let categories = stored.map { identifier, actions in
            UNNotificationCategory(
                identifier: identifier,
                actions: actions.map {
                    UNNotificationAction(
                        identifier: $0.identifier, title: $0.title,
                        options: UNNotificationActionOptions(rawValue: $0.optionsRawValue)
                    )
                },
                intentIdentifiers: [], options: []
            )
        }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }

    private static func load(_ defaults: UserDefaults) -> [String: [StoredAction]] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: [StoredAction]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ stored: [String: [StoredAction]], _ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
