import KeepoCore
import SwiftUI

/// How a scope looks and reads, in one place — the banner card, the title
/// badge, the page dots and every blank state all draw from here, so a
/// scope can never be coral on one screen and teal on the next.
///
/// One flat colour each, never a gradient (the user's call — the app stays
/// minimal). They are literals rather than `Assets.xcassets` colour sets and
/// deliberately so: brand accents with no light/dark variant, saturated
/// enough to carry white text in both appearances, exactly like
/// `keepo-brand-identity.md` §1's `BrandPrimary`/`BrandSecondary`. Total *is*
/// `BrandPrimary`; the other two are the cool and green counterparts that
/// keep the three cards distinguishable at a glance for a colour-vision-
/// deficient user — the same test `app-architecture.md` §5 applies to the
/// chart palette.
extension PublicSchema.AccountScope {
    /// Left to right in the banner's carousel, and the order the page dots
    /// are drawn in. Total sits in the middle of nothing — it is the
    /// default, so it leads.
    static let carousel: [PublicSchema.AccountScope] = [.total, .me, .household]

    /// The user's own word for this scope. `.me` is **"Private"**, not the
    /// "Personal" the old scope menu used: the badge beside a screen title
    /// has to say what is being excluded, and "Private" says it.
    var title: String {
        switch self {
        case .total: return "Total"
        case .me: return "Private"
        case .household: return "Household"
        }
    }

    /// One line under the screen title saying what the scope actually
    /// filters. The carousel teaches the model; this is where it says so.
    var caption: String {
        switch self {
        case .total: return "Everything you can see"
        case .me: return "Only your unshared accounts"
        case .household: return "Only accounts you share"
        }
    }

    var icon: String {
        switch self {
        case .total: return "globe.europe.africa.fill"
        case .me: return "lock.fill"
        case .household: return "person.2.fill"
        }
    }

    /// `nil` for Total — a badge exists to flag that the figures on screen
    /// are a *subset*, and Total is the one scope that hides nothing.
    var badgeTitle: String? {
        self == .total ? nil : title
    }

    /// One step darker than `tint`, for a panel that hangs off the banner
    /// and needs to read as a second surface rather than a continuation of
    /// the first — the Transactions filter drawer. Derived rather than
    /// listed, so a scope can never gain a panel colour that has drifted
    /// away from its own.
    var panelTint: Color { tint.shifted(saturation: 0.02, brightness: -0.1) }

    /// The scope's colour — the banner card's fill, and the accent anywhere
    /// else the scope needs naming (an empty-state icon, a badge).
    var tint: Color {
        switch self {
        case .total: return Color(hex: "#FF5A5F")
        case .me: return Color(hex: "#5B5BD6")
        case .household: return Color(hex: "#0F9B8E")
        }
    }
}

// MARK: - Top safe area

/// The window's top safe-area inset, published by the app shell.
///
/// The scope banner needs it to paint its own colour up behind the status
/// bar, and it cannot measure it itself: by the time the banner is laid out
/// it is already *inside* the safe area, so its own geometry reports zero.
/// The shell is the last view that still sees the real number.
private struct TopSafeAreaInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var topSafeAreaInset: CGFloat {
        get { self[TopSafeAreaInsetKey.self] }
        set { self[TopSafeAreaInsetKey.self] = newValue }
    }
}
