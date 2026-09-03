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

### The neutral ramp

Every non-semantic colour comes off one zero-chroma ramp:

`#FFFFFF · #FAFAFA · #F5F5F5 · #EBEBEB · #E0E0E0 · #CCCCCC · #A3A3A3 · #8A8A8A · #737373 · #6B6B6B · #525252 · #3B3B3B · #333333 · #303030 · #262626`

**`#262626` is the floor: nothing in the app is darker, and nothing is pure black** — not primary text, not the dark canvas, not a shadow. The previous palette's warm cream (`#FAF9F6`) and blue-slate dark (`#0B0F19` / `#1E293B` / `#334155`) are both gone. The app is neutral so that its one accent has the screen to itself.

### Brand accent — one colour

*   **`BrandPrimary`** (Mango) — `#A05C00` / Dark `#FF9F1C` / HC `#8A5200` / Dark+HC `#FFB347` → `Palette.brandPrimary`
    *   *Usage:* the Needs Review inbox, the Pending badge, budget and goal benchmarks, the offline bar, the tab bar's unreviewed-count dot. Anything that should catch the eye **without reading as an error** — that is what separates it from `StatusNegative`.

**There is no `BrandSecondary`.** The Electric Coral `#FF5A5F` that used to be the primary is gone from the app: mango is the whole accent.

**Why the accent is not one value.** Mango is a light hue. `#FF9F1C` measures **2.05:1 on white** — it fails as text at any size — and **7.37:1 on `#262626`**. Nearly every use of the accent is ink at caption sizes, so the light value has to be a deep amber and the dark value the true mango. That is one accent at the two lightnesses its two grounds require, not two accents. `ScopeTotal` is the same hue on the fill side, where dark ink would sit on it instead.

### Surface & Text

| Token | Light | Dark | HC Light | HC Dark |
|---|---|---|---|---|
| `BGCanvas` | `#F5F5F5` | `#262626` | `#EDEDED` | `#262626` |
| `BGSurface` | `#FFFFFF` | `#303030` | `#FFFFFF` | `#333333` |
| `BGSurfaceRaised` | `#EBEBEB` | `#3B3B3B` | `#DCDCDC` | `#424242` |
| `TextPrimary` | `#262626` | `#F5F5F5` | `#262626` | `#FFFFFF` |
| `TextSecondary` | `#6B6B6B` | `#A3A3A3` | `#525252` | `#CCCCCC` |
| `TextOnAccent` | `#FFFFFF` — single value, all appearances | | | |

`BGSurfaceRaised` is a surface sitting *on* `BGSurface`: a well inside a card, a selected row. It recesses in light and lifts in dark.

`TextSecondary` clears 4.5:1 on canvas, surface **and** raised in all four appearances (worst case 4.51). `TextPrimary` runs 12.9–15.1:1. **High Contrast light keeps canvas and surface visibly apart** rather than flattening both to white as it used to — this app separates cards with shadow, not hairlines, so collapsing that step removed the only edge a card had.

### Neutral fills
Prefer these over `.opacity()` on a neutral: an asset gets a high-contrast variant, an alpha never can.
*   **`FillSubtle`** — `#737373` @12% / Dark `#A3A3A3` @16% / HC @22% / Dark+HC @28% — a wash behind a chip or an icon well
*   **`FillStrong`** — `#737373` @22% / Dark `#A3A3A3` @28% / HC @34% / Dark+HC @42% — its selected or pressed state

### Status

| Token | Light | Dark | HC Light | HC Dark |
|---|---|---|---|---|
| `StatusPositive` | `#177A33` | `#4CD97B` | `#116326` | `#7BE8A2` |
| `StatusNegative` | `#C4271B` | `#FF6B66` | `#A81E15` | `#FF9C99` |

Deliberately **not** the system `.green`/`.red`. Both were deepened when the canvas went neutral: the previous `#1E8E3E` measures 3.86:1 on `#F5F5F5` and failed. Warnings have no token of their own — they use `BrandPrimary`, per the mango rule above.

### Money

| Token | Light | Dark | HC Light | HC Dark |
|---|---|---|---|---|
| `CashflowIncome` | `#1F6BC7` | `#5B9FEF` | `#155FB5` | `#7CB4F2` |
| `CashflowExpense` | `#CC2E28` | `#FF7A75` | `#AD2119` | `#FFA9A4` |
| `ChartNeutral` | `#262626` | `#D4D4D4` | `#262626` | `#FFFFFF` |

**Income is blue, not green.** Warm-vs-green is the canonical red-green colour-vision failure (ΔE 7.6 for the original coral pair); warm-vs-blue clears it (ΔE 19.5). Validated against CVD tooling rather than picked by eye — see `app-architecture.md` §5. This overrides the several places the widget spec asks for green income.

Expense is a **deep red**, not the old coral: coral *was* `BrandPrimary`, and removing the one meant retiring the other. It stays warm rather than folding into `ChartNeutral` so a cashflow chart still reads as two opposed quantities; it is deliberately a shade off `StatusNegative`, which is a verdict rather than a direction. Re-checked on the new values: income and expense separate by ΔE 120 in CIELAB under simulated deuteranopia, against a working floor of 30.

### Scope

| Token | Light | Dark | HC Light | HC Dark |
|---|---|---|---|---|
| `ScopeTotal` | `#FF9F1C` | `#F0940F` | `#AA6000` | `#A25C00` |
| `ScopePrivate` | `#5B5BC7` | `#5252BE` | `#4A4AB5` | `#4A4AB5` |
| `ScopeHousehold` | `#148075` | `#127268` | `#0E6F66` | `#0E6F66` |

Total is **mango** — `BrandPrimary`'s hue on the fill side — with the cool and green counterparts that keep the three banner cards distinguishable to a colour-vision-deficient user (worst pair ΔE 53 under deuteranopia, against the same floor of 30). **Dark mode deepens every card one step** to cut glare on a `#262626` ground.

All three carry `TextOnAccent` (white), and **Total does not clear AA in its default appearances: white on `#FF9F1C` is 2.05:1.** That is a deliberate call — the mango card is to be judged on a real device before the ink question is reopened — and it is recorded here, in `Palette.scopeTotal` and in `ScopeStyle` so nobody later reads it as an oversight. **High Contrast is where it is made good:** each card deepens until white clears 4.5:1 (Total 4.79, Private 7.15, Household 6.03), Total furthest of the three because it starts furthest away. If the card turns out to read badly on device, the fix is a per-scope foreground (`scope.onTint` returning `#262626` for Total), not a darker mango — a mango dark enough for white text is brown.

### Elevation tint
*   **`ShadowTint`** — `#262626` / Dark `#4A4A4A` / HC `#262626` / Dark+HC `#5C5C5C` — the colour every `AppTheme.Elevation` shadow is drawn in

Not `.black`, which the palette no longer contains and which was in any case appearance-blind. On a `#262626` dark canvas a black shadow is invisible, so every surface in dark mode floated on nothing; the asset inverts to a grey **lighter** than the canvas — the only direction left once `#262626` is the floor — and elevation reads there as ambient lift rather than a void beneath.

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

**Closed.** All three used to be `.black` in both appearances, and the original spec asked for a dark-mode-only brand glow (`BrandPrimary` @ 45%, radius 12) to compensate. Neither survives. The colour is now `Palette.shadowTint`, a colour *set* — so the appearance switch happens in the asset, not in a `colorScheme` branch here, and no fourth elevation was needed. The glow is grey rather than mango: a brand-tinted halo on every card is exactly the noise a neutral palette exists to remove. See §1's Elevation tint.

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
