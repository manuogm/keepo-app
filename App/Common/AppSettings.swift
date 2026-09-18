import Foundation
import SwiftUI

/// Device-local UI preferences — the first use of this pattern in the app.
/// Everything else in Keepo is either Supabase-backed or session-lifetime
/// state in `SessionStore`; these are genuinely device preferences
/// (appearance, notification level, whether Face ID/hide-balance are even
/// offered), not financial data, and deliberately don't sync across a
/// household's two devices. Views read/write them via `@AppStorage` for
/// automatic re-rendering; non-view code (`SessionStore`, `CaptureIntent`,
/// `BalanceReminderScheduler`) reads the same underlying `UserDefaults` keys
/// through the plain accessors below — both paths hit the same storage, so
/// there is nothing to keep in sync between them.
enum AppSettingsKeys {
    static let appearanceMode = "appearanceMode"
    static let notificationLevel = "notificationLevel"
    static let isFaceIDEnabled = "isFaceIDEnabled"
    static let isHideBalanceEnabled = "isHideBalanceEnabled"
    /// Comma-separated "#RRGGBB" values the user mixed in the icon
    /// catalogue's custom-colour picker, most recent first. Device-local
    /// for the same reason the four above are: it is a convenience palette,
    /// not data about their money.
    static let customIconColors = "customIconColors"
    /// The setup flow's in-progress draft, as JSON (see
    /// `OnboardingDraftStore`). Device-local like the rest of this list, and
    /// for the documented reason rather than by omission: **none of it has
    /// reached the server yet** — it is a name, a photo and an account the
    /// user has described but not committed — and it is deleted the moment
    /// the commit succeeds. It exists at all because setup step 4 sends the
    /// user to the Shortcuts app for minutes at a time, which iOS is free
    /// to treat as grounds for terminating Keepo.
    static let onboardingDraft = "onboardingDraft"
    /// The same ticks for the Profile → My Automations setup flow, kept
    /// under their own key: a user setting capture up from Profile is not
    /// resuming onboarding, and one key would let either flow open with the
    /// other's progress already applied.
    static let captureSetupChecklist = "captureSetupChecklist"
    /// Which Shortcuts-walkthrough steps have been ticked, as a sorted
    /// comma-joined list of ids.
    ///
    /// **Not a field on `OnboardingDraft`**, deliberately. That type has no
    /// custom decoder, so a new non-optional key would make every draft
    /// already on disk fail to decode — and `OnboardingDraftStore` decodes
    /// with `try?`, which turns that failure into a silent reset to step
    /// one. A separate key cannot break a draft that predates it. Cleared
    /// with the draft in `OnboardingDraftStore.clear()`.
    static let walkthroughCompleted = "walkthroughCompleted"
    /// Whether the intro screens have been shown on this device. They sit
    /// **before** sign-in — there is no account to hang the flag off yet —
    /// so a returning signed-out user is not marketed to a second time.
    static let hasSeenIntro = "hasSeenIntro"
    /// The Home dashboard's own widget arrangement, as JSON (see
    /// `DashboardStore`). Device-local by decision, not by omission: a grid
    /// laid out for one screen size is not obviously the right grid for
    /// another, and nothing in it is data about the user's money — every
    /// widget renders from the synced local mirror. Promoting it to a synced
    /// table later means changing `DashboardStore` and nothing above it.
    static let dashboardArrangement = "dashboardArrangement"
    /// The household this device last saw itself in.
    ///
    /// Device-local on purpose, and it is how the **remaining** member learns
    /// the household was dissolved. Since 20260915100000 one member leaving
    /// ends the household for both — and the one who stayed cannot be told by
    /// `household_events`, because dissolving retires their membership and
    /// that table's policy is scoped to membership (pinned by
    /// `18_household_lifecycle.sql`'s own assertion). So the signal is the
    /// absence itself: a household this device was holding is gone from the
    /// mirror after a pull. Nothing to read, nothing to grant.
    static let lastKnownHouseholdId = "lastKnownHouseholdId"
    /// When the first real Apple Pay capture arrived on this device.
    ///
    /// It is the only evidence Keepo can ever have that the **Wallet
    /// automation** exists and is bound to the right cards — the one half
    /// of capture setup no in-app test can check, because iOS exposes no
    /// API to enumerate or inspect a personal automation. So it is set by
    /// the write itself (`CaptureIntent`), not by a screen observing one,
    /// and Profile → My Automations reads it to say "Working" rather than
    /// "Waiting for your first purchase".
    ///
    /// Device-local because the automation is: it lives in this phone's
    /// Shortcuts app, and a household's second device has its own.
    static let captureVerifiedAt = "captureVerifiedAt"
    /// When the connection test last passed — i.e. the user has actually
    /// been through the setup, whether during onboarding or from Profile.
    ///
    /// **Distinct from `captureVerifiedAt`**, and the difference matters.
    /// That one means a *real* Apple Pay purchase arrived, which is the only
    /// proof the Wallet automation exists; this one means the shortcut is
    /// installed and reachable, which is all the test can ever prove. The
    /// automations screen needs the weaker signal: it decides whether to
    /// show setup instructions or the thing the user set up, and waiting
    /// for a real purchase would keep showing setup instructions to someone
    /// who had just finished setting up.
    static let captureSetupCompletedAt = "captureSetupCompletedAt"
    /// How many captured purchases this user has reviewed, ever —
    /// onboarding's own test capture excluded. The bar the rating ask sits
    /// behind (`ReviewPolicy.lifetimeCapturesBar`).
    static let capturesReviewed = "capturesReviewed"
    /// Set by the write that left the pending inbox clear, read on the next
    /// clean foreground beat. The two are separate events on purpose: a
    /// capture resolved from a notification clears the inbox while the app
    /// is backgrounded, where a prompt would be fired at nobody — and a
    /// rule that watched the count instead would never see that clear at
    /// all. See `ReviewPolicy.shouldArm`.
    static let reviewPromptArmed = "reviewPromptArmed"
    /// When `requestReview` was last called — not when a prompt was last
    /// *shown*, which iOS never tells anyone.
    static let lastReviewRequestAt = "lastReviewRequestAt"
    /// Prefix for "this coach mark has been shown on this device", one key
    /// per lesson — `spotlightSeen.scope`, `.accounts`, `.add`.
    ///
    /// Device-local, and one-shot each: a coach mark teaches a gesture, and
    /// a gesture only needs teaching once. Keyed by `FTUXLesson.id` rather
    /// than listed here so adding a coach mark is adding a lesson, not
    /// remembering to add a constant beside it — see
    /// `FTUXCoordinator.seenKey`.
    static let spotlightSeenPrefix = "spotlightSeen."
}

extension AppSettings {
    /// The date the first capture landed, or `nil` while none has.
    static var captureVerifiedAt: Date? {
        UserDefaults.standard.object(forKey: AppSettingsKeys.captureVerifiedAt) as? Date
    }

    /// Written once and never moved. It answers "has this ever worked?",
    /// not "when did it last run" — overwriting it on every capture would
    /// lose the only date that means anything, and cost a `UserDefaults`
    /// write on a path that runs at the register.
    static var captureSetupCompletedAt: Date? {
        UserDefaults.standard.object(forKey: AppSettingsKeys.captureSetupCompletedAt) as? Date
    }

    /// Set every time the test passes, not only the first — re-running it
    /// after changing phones or re-importing the shortcut is exactly when
    /// the freshest date is worth having.
    static func markCaptureSetupCompleted() {
        UserDefaults.standard.set(Date(), forKey: AppSettingsKeys.captureSetupCompletedAt)
    }

    static func markCaptureVerifiedIfNeeded() {
        guard captureVerifiedAt == nil else { return }
        UserDefaults.standard.set(Date(), forKey: AppSettingsKeys.captureVerifiedAt)
    }
}

enum AppearanceMode: String, CaseIterable, Hashable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` means "inherit the system setting" — `.preferredColorScheme`'s
    /// own documented meaning for a `nil` argument.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum NotificationLevel: String, CaseIterable, Hashable {
    case none, functional, full

    var label: String {
        switch self {
        case .none: return "No Notifications"
        case .functional: return "Functional Only"
        case .full: return "Full Experience"
        }
    }

    var detail: String {
        switch self {
        case .none: return "You will be missing out the good stuff"
        case .functional: return "Automatically captured payments and other items needing your review"
        case .full: return "Functional + Monthly reminders to help you stick to good habits"
        }
    }

    var icon: String {
        switch self {
        case .none: return "icon-notification-none"
        case .functional: return "icon-notification-money"
        case .full: return "icon-bell"
        }
    }
}

/// Plain, non-`@AppStorage` accessors for code that isn't a View — reads
/// and writes the exact same `UserDefaults.standard` keys `@AppStorage`
/// uses, so a preference changed from a View is visible here immediately
/// and vice versa. Defaults match `@AppStorage`'s own defaults below
/// (`.full` notifications, Face ID and hide-balance both enabled) so a
/// fresh install behaves identically whichever path reads first.
enum AppSettings {
    static var isFaceIDEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.isFaceIDEnabled) as? Bool ?? true
    }

    static var isHideBalanceEnabled: Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.isHideBalanceEnabled) as? Bool ?? true
    }

    static var notificationLevel: NotificationLevel {
        (UserDefaults.standard.string(forKey: AppSettingsKeys.notificationLevel))
            .flatMap(NotificationLevel.init) ?? .full
    }
}
