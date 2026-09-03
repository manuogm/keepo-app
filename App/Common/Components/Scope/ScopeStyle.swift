import KeepoCore
import SwiftUI

/// How a scope looks and reads, in one place — the banner card, the title
/// badge, the page dots and every blank state all draw from here, so a
/// scope can never be mango on one screen and teal on the next.
///
/// One flat colour each, never a gradient (the user's call — the app stays
/// minimal). All three are `Assets.xcassets` colour sets carrying four
/// appearances apiece — light, dark, and both High Contrast variants — so
/// the banner honours Increase Contrast with no `colorScheme` branch here.
/// Total is **mango**, the fill side of `BrandPrimary`; the other two are
/// the cool and green counterparts that keep the three cards
/// distinguishable at a glance for a colour-vision-deficient user — the
/// same test `app-architecture.md` §5 applies to the chart palette.
///
/// All three carry `TextOnAccent` (white), and mango does not clear AA
/// against it: 2.05:1. That is a **deliberate call to judge the mango card
/// on a real device**, recorded in `keepo-brand-identity.md` §1 and in
/// `Palette.scopeTotal` — not a value anybody forgot to check. Increase
/// Contrast is where it is made good: every card deepens until white
/// clears 4.5:1, Total furthest of the three.
extension PublicSchema.AccountScope {
    /// Left to right in the banner's carousel, and the order the page dots
    /// are drawn in. Total leads because it is the default; **Household
    /// comes second** because it is the one a user is more likely to reach
    /// for next, and it should be one swipe away rather than two.
    static let carousel: [PublicSchema.AccountScope] = [.total, .household, .me]

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

    /// The badge glyph — `nil` for Total, which is never badged (see
    /// `badgeTitle`). `.me` and `.household` are asset icons from
    /// `Assets.xcassets/Icons`, the filled variant, since the badge is a
    /// solid statement of which subset you're looking at.
    var icon: String? {
        switch self {
        case .total: return nil
        case .me: return "icon-lock-filled"
        case .household: return "icon-home-filled"
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
    ///
    /// Listed in the colour set, never derived here: the softening used to
    /// be a `.shifted(saturation: -0.09)` recomputed on every render, and
    /// baking it into the asset is the same result without asking `UIColor`
    /// to resolve a dynamic colour mid-body. It is also what lets each scope
    /// carry a High Contrast variant at all, which an arithmetic shift on a
    /// resolved colour never could.
    var tint: Color {
        switch self {
        case .total: return AppTheme.Palette.scopeTotal
        case .me: return AppTheme.Palette.scopePrivate
        case .household: return AppTheme.Palette.scopeHousehold
        }
    }
}

// MARK: - Scope glyph

/// Renders a scope's icon whether it's an `Assets.xcassets/Icons` asset
/// (`icon-…`) or an SF Symbol. Asset icons take `size`; SF Symbols size from
/// the caller's `.font(…)`, exactly like a bare `Image(systemName:)`. The
/// blank state needs the fallback — its "no accounts" case is still the
/// `creditcard` symbol — while the scope badges are all assets now.
struct ScopeGlyph: View {
    let name: String
    var size: CGFloat = AppTheme.Size.glyphSmall

    var body: some View {
        if name.hasPrefix("icon-") {
            KeepoIcon(name: name, size: size)
        } else {
            Image(systemName: name)
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
