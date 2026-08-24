import UserNotifications

/// Builds the swipe-reveal action buttons for a capture notification from
/// its `CaptureLocalWrite.Resolution` — pure logic, no `UNUserNotification
/// Center` calls, so it's unit-testable the same way `CaptureNotificationCopy`
/// is. `CaptureIntent` uses the result to build the notification content and
/// register it with `CaptureQuickActionRegistry`; `AppDelegate` reads the
/// `userInfo` back out to route a tap.
///
/// Action *identifiers* are fixed and shared by every capture notification —
/// only their *titles* vary per notification (real category/account names).
/// That's why a notification's actual pick targets travel in `userInfo`
/// rather than the identifier itself: `AppDelegate` never needs to know
/// which category/account a button meant, only which numbered slot was
/// tapped, then looks the real id up positionally.
enum CaptureQuickActions {
    static let confirmActionId = "capture.confirm"
    static let moreActionId = "capture.more"
    static let deleteActionId = "capture.delete"
    static func pickActionId(_ index: Int) -> String { "capture.pick.\(index)" }

    /// `userInfo` keys — `"category"`/`"account"`, telling `AppDelegate`
    /// which field a tapped pick slot writes.
    static let pickKindKey = "pickKind"
    static let pickIdsKey = "pickIds"

    struct ActionSet {
        let actions: [UNNotificationAction]
        let userInfo: [String: Any]
    }

    /// Mirrors `CaptureNotificationCopy.appliedLocally`'s own four-way split
    /// on `(accountKnown, categoryKnown)`, plus the duplicate override that
    /// applies across all four. Manu's design (see plan): both known gets
    /// Confirm + up to 3 category alternates (2 if a duplicate is
    /// suspected, to make room for Delete); category/account unknown gets
    /// up to 3 picks + "More options" (2 + Delete if a duplicate); both
    /// unknown gets no buttons at all, unless a duplicate is suspected, in
    /// which case it gets a bare Delete — the one case where the duplicate
    /// flag adds a button set where there normally wouldn't be one.
    static func build(for resolution: CaptureLocalWrite.Resolution) -> ActionSet {
        let accountKnown = resolution.accountId != nil
        let categoryKnown = !resolution.categoryIsDefault
        let isDuplicate = resolution.isPossibleDuplicate

        switch (accountKnown, categoryKnown) {
        case (true, true):
            return bothKnown(resolution.suggestedCategories, isDuplicate: isDuplicate)
        case (true, false):
            return picks(resolution.suggestedCategories, kind: "category", isDuplicate: isDuplicate)
        case (false, true):
            return picks(resolution.suggestedAccounts, kind: "account", isDuplicate: isDuplicate)
        case (false, false):
            let actions = isDuplicate ? [deleteAction()] : []
            return ActionSet(actions: actions, userInfo: [:])
        }
    }

    private static func bothKnown(_ suggestions: [CaptureLocalWrite.Suggestion], isDuplicate: Bool) -> ActionSet {
        let chosen = Array(suggestions.prefix(isDuplicate ? 2 : 3))
        var actions = [confirmAction()] + pickActions(chosen)
        if isDuplicate { actions.append(deleteAction()) }
        return ActionSet(actions: actions, userInfo: pickUserInfo(chosen, kind: "category"))
    }

    private static func picks(
        _ suggestions: [CaptureLocalWrite.Suggestion], kind: String, isDuplicate: Bool
    ) -> ActionSet {
        let chosen = Array(suggestions.prefix(isDuplicate ? 2 : 3))
        var actions = pickActions(chosen) + [moreAction()]
        if isDuplicate { actions.append(deleteAction()) }
        return ActionSet(actions: actions, userInfo: pickUserInfo(chosen, kind: kind))
    }

    private static func pickUserInfo(_ suggestions: [CaptureLocalWrite.Suggestion], kind: String) -> [String: Any] {
        guard !suggestions.isEmpty else { return [:] }
        return [pickKindKey: kind, pickIdsKey: suggestions.map(\.id)]
    }

    private static func pickActions(_ suggestions: [CaptureLocalWrite.Suggestion]) -> [UNNotificationAction] {
        suggestions.enumerated().map { index, suggestion in
            UNNotificationAction(identifier: pickActionId(index), title: suggestion.name, options: [])
        }
    }

    private static func confirmAction() -> UNNotificationAction {
        UNNotificationAction(identifier: confirmActionId, title: "✅ Confirm", options: [])
    }

    private static func moreAction() -> UNNotificationAction {
        UNNotificationAction(identifier: moreActionId, title: "More options", options: [])
    }

    private static func deleteAction() -> UNNotificationAction {
        UNNotificationAction(identifier: deleteActionId, title: "🗑️ Delete", options: [.destructive])
    }
}
