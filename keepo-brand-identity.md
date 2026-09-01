# Keepo Brand Identity (iOS Native)

**App Concept:** A young, playful, and intuitive cross-account personal finance aggregator and multi-currency data tracker. Focuses on total financial clarity and visibility without holding user funds.

> **§1–§4 are implemented as `AppTheme`.** Everything below is a decision; `App/Common/Theme/` is where that decision lives as code, and a view never restates it. If this document and `AppTheme` ever disagree, **fix one of them** — do not add a third value at a call site.
>
> | Section | Owns | File |
> |---|---|---|
> | §1 | `AppTheme.Palette` | `AppTheme+Palette.swift` + `Assets.xcassets/Colors/` |
> | §2 | `AppTheme.Typography`, `.Typography.Number` | `AppTheme+Typography.swift` |
> | §4 | `AppTheme.Spacing`, `.Radius`, `.Size`, `.Opacity`, `.Elevation` | `AppTheme.swift` |
> | §4 | `AppTheme.Motion` | `AppTheme+Motion.swift` |
> | §7 | `AppTheme.Feedback` | `AppTheme+Feedback.swift` |
>
> A view file should contain **no** raw hex, no `.system(size:)`, no numeric padding or corner radius, and no bare animation duration. That is enforceable, and worth re-running after any large change — it should return only the four motion exemptions §4 names:
>
> ```
> grep -rnE 'Color\(hex: "#|\.system\(size: [0-9]|\.padding\((\.[a-zA-Z]+, )?[0-9]+\)|cornerRadius:? ?[0-9]|\.(snappy|easeInOut|easeOut)\(duration:|\.spring\(response:' \
>   --include='*.swift' App | grep -v 'App/Common/Theme'
> ```

---

## 1. Color Palette Tokens — Asset Catalog Color Sets

Decision: colors are **Color Sets in `Assets.xcassets/Colors/`**, each carrying its Any / Dark / **High Contrast** / Dark+High Contrast values on the *same* asset. No manual `colorScheme` branching anywhere in the view layer — the system switches, including for Increase Contrast, which a literal can never do.

Referenced only through `AppTheme.Palette`, which names each set exactly once. A view writes `AppTheme.Palette.textSecondary`, never `Color("TextSecondary")` and never `Color.secondary`.

### Brand Accents (single value — no dark variant)
*   **`BrandPrimary`** (Electric Coral): `#FF5A5F` → `Palette.brandPrimary`
    *   *Usage:* Main data lines/curves, analytics progress rings, interactive buttons, primary microcopy keywords.
*   **`BrandSecondary`** (Mango Fizz): `#FF9F1C` → `Palette.brandSecondary`
    *   *Usage:* Budget limit reminders, currency categorization chips, goal benchmarks, the Needs Review inbox. A reminder should catch the eye **without reading as an error** — that is what separates it from `StatusNegative`.

### Surface & Text
*   **`BGCanvas`** — `#FAF9F6` (Warm Clean Cream) / Dark `#0B0F19` (Deep Velvet Night) — overall app canvas
*   **`BGSurface`** — `#FFFFFF` (Pure White) / Dark `#1E293B` (Slate Gray) — cards, transaction rows, floating asset blocks
*   **`BGSurfaceRaised`** — `#F1F0EC` / Dark `#334155` — a surface sitting *on* `BGSurface`: a well inside a card, a selected row
*   **`TextPrimary`** — `#0B0F19` (Deep Velvet Charcoal) / Dark `#FAF9F6` (Warm Off-White) — balance values, core typography
*   **`TextSecondary`** — `#64748B` (Slate Steel) / Dark `#94A3B8` (Muted Steel) — metadata, timestamps, subtext
*   **`TextOnAccent`** — `#FFFFFF` — text and glyphs drawn on a saturated fill (a scope banner, a tinted circle)

### Neutral fills
Prefer these over `.opacity()` on a neutral: an asset gets a high-contrast variant, an alpha never can.
*   **`FillSubtle`** — `#64748B` @ 12% / Dark `#94A3B8` @ 16% — a wash behind a chip or an icon well
*   **`FillStrong`** — `#64748B` @ 22% / Dark `#94A3B8` @ 28% — its selected or pressed state

### Status
*   **`StatusPositive`** — `#1E8E3E` / Dark `#4CD97B` — a trend up, a toggle on, a finished sync
*   **`StatusNegative`** — `#D92D20` / Dark `#FF6B66` — an error, a destructive action, a trend down

Deliberately **not** the system `.green`/`.red`: both are too light to read as text on either canvas. Warnings have no token of their own — they use `BrandSecondary`, per the mango rule above.

### Money
*   **`CashflowIncome`** — `#2A78D6` / Dark `#3987E5`
*   **`CashflowExpense`** — `#FF5A5F` / Dark `#F04A50`
*   **`ChartNeutral`** — `#262626` / Dark `#D9D9D9` — the default series colour, for anything that is neither a verdict nor a user-chosen identity

**Income is blue, not green.** Coral-vs-green is the canonical red-green colour-vision failure (ΔE 7.6); coral-vs-blue clears it (ΔE 19.5). Validated against CVD tooling rather than picked by eye — see `app-architecture.md` §5. This overrides the several places the widget spec asks for green income.

### Scope
*   **`ScopeTotal`** `#FF7175` · **`ScopePrivate`** `#6E6ED6` · **`ScopeHousehold`** `#1D9B8F`

`BrandPrimary` pulled back, plus its cool and green counterparts — a whole screen of full-saturation coral shouted at everything on it. The three stay distinguishable to a colour-vision-deficient user, the same test the chart palette passes. The softening is baked into the asset, not recomputed per render.

---

## 2. Typography — System Font (SF Pro)

Decision: no bundled custom fonts. The system font (SF Pro) via **Dynamic Type text styles**, never fixed point sizes.

Tokens are named by the **role** a piece of text plays, not by the SF style behind it, so the mapping is a decision that can be revisited in one place. `AppTheme.Typography`:

| Role | Style | Use |
|---|---|---|
| `screenTitle` | `.largeTitle.bold` | the one big title on a screen that has one |
| `sectionTitle` | `.title2.semibold` | a section heading in a screen or sheet |
| `cardTitle` | `.title3.semibold` | a card's or widget's own title |
| `rowTitle` | `.headline` | the bold line atop a list row or alert |
| `body` / `bodyEmphasis` | `.body` | running text |
| `label` / `labelEmphasis` | `.subheadline` | a row's primary label — the workhorse |
| `caption` / `captionEmphasis` | `.footnote` | supporting text, error messages |
| `micro` / `microEmphasis` | `.caption` | metadata, chips, axis labels |
| `nano` / `nanoEmphasis` | `.caption2` | badges, tab labels — nothing smaller is legible |

`.callout` merged into `body`, and every `.medium` weight into its `.semibold` neighbour: a one-step weight difference nobody could name the reason for.

### Numeric values

**Currency figures, tables and chart axis labels take `AppTheme.Typography.Number`** — `.inline`, `.caption`, `.micro`. Each already carries `.monospacedDigit()`, SwiftUI's native equivalent of CSS `font-variant-numeric: tabular-nums`, so digit widths stay fixed as balances update and layout doesn't jitter. Numbers get their own tokens for exactly this reason: remembering `.monospacedDigit()` per call site is what gets forgotten on the forty-first screen.

Figures larger than any text style go through `Number.display(_:weight:scale:)` at one of four sizes — `hero` 48, `balance` 40, `metric` 32, `metricCompact` 28 — or the `.numberFont(_:)` modifier, which applies the `@ScaledMetric` for you. **Never `.system(size:)` directly**; that is text that does not grow (see §3).

**Decided:** no `.rounded` design variant — the default SF Pro design everywhere. (SF Pro's `.rounded` could preserve some of the "young, playful" character the original bespoke fonts were chosen for, but it is explicitly not in use.)

---

## 3. Accessibility — Dynamic Type

*   All text uses Dynamic Type–aware sizing. **Every `AppTheme.Typography` token is a text style**, and the four display sizes scale through `@ScaledMetric(relativeTo: .largeTitle)`. `BalanceHeaderView` is the funnel every money figure in the app passes through, so one `@ScaledMetric` there scales every balance, widget headline and metric.
*   Colour tokens carry **High Contrast** variants, so Increase Contrast is honoured without a code path.
*   **One capped surface, deliberately:** the tab bar is a fixed-height capsule sized to the display's corner radius and cannot grow, so it clamps at `.xxLarge`. Everything it navigates *to* is uncapped. Any future fixed-height chrome should do the same and say so at the call site — a cap that isn't explained reads as an oversight.
*   Layouts (cards, list rows, balance headers) must tolerate reflow/wrapping at larger accessibility sizes. A financial figure must never silently truncate — if a layout can't accommodate the largest supported size, it should wrap or shrink-to-fit, not clip.

**Open, verified on device sizes (2026-09-01):** two layouts still fail that last rule. Account row balances wrap *mid-number* (`$8,827.` / `30`), and dashboard widgets overflow their tiles because the grid sizes tiles by geometry rather than by content. Both predate the token system and neither is a token problem; they are layout work.

---

## 4. Geometric UI Foundations & Motion

### Spacing — `AppTheme.Spacing`

A **4pt grid** with exactly one half-step. A value not on this scale is a value nobody should be reaching for.

`xxs` 2 · `xs` 4 · `s` 8 · `m` 12 · `l` 16 · `xl` 24 · `xxl` 32

`xxs` (2) survives the grid on purpose: the leading between a row's title and its subtitle is genuinely 2pt work. **`l` (16) is the screen edge** — and also a card's inner inset and the dashboard's own step, so a sheet's edge lines up with a widget's.

Square dimensions (`AppTheme.Size`) run `dot` 8 · `glyph` 24 · `icon` 32 · `touchTarget` 44 · `avatar` 56 · `illustration` 80. `touchTarget` is HIG's minimum, applied as a **hit area** via `hitTarget(_:)` rather than as layout — a 44pt capsule around every widget-header segment would swamp the header.

### Corner radii — `AppTheme.Radius`

Three, because the app only ever meant three things:

*   **`surface` = 20** — top-level surfaces: data cards, sheets, dashboard widgets, drawers, a card face
*   **`card` = 16** — a surface nested *inside* another surface: a row inside a card
*   **`control` = 12** — control toggles, category chips, small buttons, keypad keys

`surface` and `control` are the original spec's values, unchanged. `card` is the third, which this document predates.

### Elevation — `AppTheme.Elevation`

Three shadows — `resting`, `floating`, `lifted` — applied through `.elevation(_:isActive:)`, never a raw `.shadow`.

**Open:** the original spec called for a dark-mode-only brand glow (`BrandPrimary` @ 45%, radius 12). It has never been implemented; all three elevations are black in both appearances. Left open rather than dropped — it would need to be a fourth elevation gated on `colorScheme`, and nobody has asked for it on a real screen yet.

### Motion — `AppTheme.Motion`

**Superseded.** This section previously specified `Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.2)` as an exact port of the original CSS easing. That curve was never implemented, and it should not be: its third control point (1.56) is an **overshoot**, and overshoot is the thing the app had to remove.

`.snappy` is a spring, springs overshoot, and an overshoot on an *interpolated colour* has nowhere to go — it clamps at the end of the ramp and comes back, which reads as the mark flashing rather than as bounce. That cost two visible defects (the chart highlight flickering, the Cashflow toggle double-blinking) before anyone traced it.

Five tokens:

*   **`quick`** `.snappy(0.20)` — a small state flip that moves nothing: a selected segment, a tab, a chip
*   **`standard`** `.snappy(0.25)` — **the default.** A view arriving, leaving, expanding or collapsing. If you are unsure, it wants this one
*   **`layout`** `.snappy(0.32)` — the dashboard grid settling into a new arrangement. The slowest thing in the app, on purpose: several tiles move at once and the eye is tracking one of them
*   **`colorSafe`** `.easeInOut(0.20)` — **anything whose animation is mostly a colour or opacity change.** Not a taste call; see above. The type checker cannot enforce this, so the name has to
*   **`press(isPressed:)`** `.easeOut(0.08)` in / `(0.18)` out — asymmetric on purpose: the press must register on the first frame of the touch, but a snap back on release looks twitchy

Three values stay outside the scale and are documented as exemptions in `AppTheme+Motion.swift`: the scope carousel's two springs (a rejected drag damps harder than a committed one — that pairing *is* the gesture), the edit-mode jiggle's randomised 0.13–0.17 period (no two tiles may stay in sync, so it must not be one number), and `AmountField`'s `.animation(nil,)`, which is suppression rather than motion.

---

## 5. App Icon & Launch Screen

### App icon: `AppIcon-1024.png`

### Launch Screen: Not yet produced — still an open item.

---

## 6. Logo

Use `keepo-logo.png` for in-app branding (nav bar, empty states, etc.) — unchanged. It is **not** the App Icon source (see §5).

**Status:** not currently referenced by any view. The intent stands; nothing has claimed it yet.

---

## 7. Haptics — `AppTheme.Feedback`

Two layers, so intensity is a knob you turn once rather than a number you retype.

**`Feedback.Level`** is the strength ramp — move a step and every intent on it moves: `whisper` 0.4 (a keystroke) · `light` 0.6 (a deliberate tap) · `firm` 0.8 (a landmark inside a gesture) · `full` 1.0 (a change you can't undo by letting go). Non-linear on purpose: below ~0.3 the Taptic Engine stops being felt reliably through a case, and 0.8→1.0 is the gap a user actually reads as "that was different".

**`Feedback`'s members are the intents**, and a call site only ever names one of those — a keypad says `.typing`, never `0.4`:

| Group | Tokens |
|---|---|
| Typing | `typing` — softest, because it is the only one that fires in a burst |
| Choices | `selection` · `toggle` |
| Buttons | `buttonPress` |
| Modes | `modeChange` |
| Drag & drop | `lift` · `pickUp` · `snap` · `drop` · `boundary` |
| Swipe | `swipeCommit` |
| Outcomes | `success` · `warning` · `failure` |

`boundary` is **rigid** where the rest of the vocabulary is soft: it should feel like hitting something, not settling onto it.

**The governing rule: an app that vibrates at everything says nothing.** `buttonPress` is deliberately *not* on every button — a row that opens a sheet already reports itself visually through `PressableRowButtonStyle`, and a list where every row buzzed would drown out the ones that matter. Adding a haptic to a new surface is a design decision, not a default.

**Open:** `success` / `warning` / `failure` are defined but unused — no write in the app currently confirms itself haptically.
