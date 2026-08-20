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
    /// The Home dashboard's own widget arrangement, as JSON (see
    /// `DashboardStore`). Device-local by decision, not by omission: a grid
    /// laid out for one screen size is not obviously the right grid for
    /// another, and nothing in it is data about the user's money — every
    /// widget renders from the synced local mirror. Promoting it to a synced
    /// table later means changing `DashboardStore` and nothing above it.
    static let dashboardArrangement = "dashboardArrangement"
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
        case .none: return "Never notified, including automatic payment capture."
        case .functional: return "Automatic payment capture and items needing review."
        case .full: return "Functional notifications, plus a monthly balance check-in reminder."
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
