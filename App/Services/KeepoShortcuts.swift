import AppIntents

/// Surfaces `CaptureIntent` in Shortcuts, Spotlight and Siri without the
/// user having to hunt for Keepo in the Apps tab.
///
/// It matters more than a discoverability nicety: the whole capture setup
/// depends on the user finding Keepo's action at least once — either
/// through the published shortcut, or by hand if that import ever fails —
/// and an action nobody can find is a setup nobody can repair.
///
/// One phrase, not a list. `AppShortcutsProvider` requires every phrase to
/// contain `\(.applicationName)`, and phrases the user would never say are
/// noise in a Siri suggestion list rather than extra coverage.
struct KeepoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureIntent(),
            phrases: ["Log a purchase in \(.applicationName)"],
            shortTitle: "Log Apple Pay Purchase",
            systemImageName: "creditcard"
        )
    }
}
