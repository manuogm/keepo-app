# Keepo Brand Identity (iOS Native)

**App Concept:** A young, playful, and intuitive cross-account personal finance aggregator and multi-currency data tracker. Focuses on total financial clarity and visibility without holding user funds.

---

## 1. Color Palette Tokens — Asset Catalog Color Sets

Decision: colors are implemented as **Color Sets in `Assets.xcassets`**, each with an "Any Appearance" and a "Dark Appearance" value on the *same* asset, referenced via `Color("TokenName")`. No manual `colorScheme` branching needed — the system switches automatically.

### Brand Accents (single value — no dark variant)
*   **`BrandPrimary`** (Electric Coral): `#FF5A5F`
    *   *Usage:* Main data lines/curves, analytics progress rings, interactive buttons, primary microcopy keywords.
*   **`BrandSecondary`** (Mango Fizz): `#FF9F1C`
    *   *Usage:* Budget limit reminders, currency categorization chips, goal benchmarks.

### Surface & Text (one Color Set per token, both appearances)
*   **`BGCanvas`** — Any `#FAF9F6` (Warm Clean Cream) / Dark `#0B0F19` (Deep Velvet Night) — overall app canvas
*   **`BGSurface`** — Any `#FFFFFF` (Pure White) / Dark `#1E293B` (Slate Gray) — cards, transaction rows, floating asset blocks
*   **`TextPrimary`** — Any `#0B0F19` (Deep Velvet Charcoal) / Dark `#FAF9F6` (Warm Off-White) — balance values, core typography
*   **`TextSecondary`** — Any `#64748B` (Slate Steel) / Dark `#94A3B8` (Muted Steel) — metadata, timestamps, subtext

---

## 2. Typography — System Font (SF Pro)

Decision: no bundled custom fonts. Use the system font (SF Pro) via SwiftUI's Dynamic Type text styles rather than fixed point sizes.

*   **Balance / currency headers:** `.largeTitle` / `.title`, weight `.bold` or `.heavy`.
*   **Body, labels, tabular data:** `.body` / `.callout`, weight `.regular` or `.medium`.
*   **Numeric values (currency figures, tables, chart axis labels):** apply `.monospacedDigit()` — SwiftUI's native equivalent of the old CSS `font-variant-numeric: tabular-nums` — so digit widths stay fixed as balances update and layout doesn't jitter.

**Decided:** no `.rounded` design variant for now — use the default SF Pro design everywhere. (SF Pro does have a `.rounded` variant that could preserve some of the "young, playful" character the original bespoke fonts were chosen for, but it is explicitly not in use.)

---

## 3. Accessibility — Dynamic Type

*   All text must use Dynamic Type–aware sizing — SwiftUI's built-in text styles or `UIFontMetrics`-scaled custom sizes — never a fixed point value.
*   Layouts (cards, list rows, balance headers) need to tolerate reflow/wrapping at larger accessibility text sizes. A financial figure must never silently truncate — if a layout can't accommodate the largest supported size, it should wrap or shrink-to-fit, not clip.

---

## 4. Geometric UI Foundations & Motion Rules — SwiftUI equivalents

Values are unchanged from the original spec; only the implementation mechanism is translated from CSS/Tailwind to SwiftUI.

*   **Corner radii** (same values as before):
    *   Data Cards / Background Sheets: `RoundedRectangle(cornerRadius: 20)` / `.cornerRadius(20)`
    *   Control Toggles / Category Chips: `.cornerRadius(12)`
*   **Visual Glow Effects (Dark Mode only):** `.shadow(color: Color("BrandPrimary").opacity(0.45), radius: 12, x: 0, y: 4)` — a translation, not an exact port: SwiftUI's shadow algorithm isn't pixel-identical to CSS `drop-shadow`, so treat radius/opacity as a starting point to tune by eye.
*   **Micro-interaction motion:** `Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.2)` — SwiftUI's `timingCurve` takes the same four cubic-bezier control points as the original CSS value, so this *is* an exact port.

---

## 5. App Icon & Launch Screen

### App icon: `AppIcon-1024.png` 

### Launch Screen: Not yet produced — still an open item.

---

## 6. Logo

Use `keepo-logo.png` for in-app branding (nav bar, empty states, etc.) — unchanged. It is **not** the App Icon source (see §5).
