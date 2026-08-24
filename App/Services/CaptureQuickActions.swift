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
    /// applies across all four. Every branch that shows buttons at all also
    /// offers "More options" (device-testing feedback: a successful capture
    /// still needs an escape hatch into the full form without hunting for
    /// the notification body's own tap target), which costs one of the four
    /// slots: both known gets Confirm + 2 category alternates + More;
    /// category/account unknown gets up to 3 picks + More; both unknown
    /// gets no buttons at all. A suspected duplicate spends one more slot
    /// on Delete in every case — including both-unknown, the one branch
    /// where the duplicate flag adds a button set where there normally
    /// wouldn't be one (a bare Delete, nothing else being resolved enough
    /// to act on).
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

    /// Confirm always leads (it's the whole point of this branch — nothing
    /// is actually missing), then the alternates, then More. The least-used
    /// alternate is what gives up its slot to More, since the suggestions
    /// arrive already ranked and `prefix` keeps the strongest.
    private static func bothKnown(_ suggestions: [CaptureLocalWrite.Suggestion], isDuplicate: Bool) -> ActionSet {
        let chosen = Array(suggestions.prefix(isDuplicate ? 1 : 2))
        var actions = [confirmAction()] + pickActions(chosen) + [moreAction()]
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

    /// `.foreground` — the only action that opens Keepo. Without it iOS
    /// delivers the tap to a background-launched process and the app never
    /// comes forward, so the prefilled form the user asked for silently
    /// never appeared (device-testing feedback). Every other action here
    /// deliberately stays background-only: they finish their write without
    /// interrupting whatever the user is doing.
    private static func moreAction() -> UNNotificationAction {
        UNNotificationAction(identifier: moreActionId, title: "More options", options: [.foreground])
    }

    private static func deleteAction() -> UNNotificationAction {
        UNNotificationAction(identifier: deleteActionId, title: "🗑️ Delete", options: [.destructive])
    }
}
