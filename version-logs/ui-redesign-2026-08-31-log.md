# UI redesign (2026-08-31) — three-tab shell, scope banner, blank states

User-driven, not a numbered phase. Written for the next agent.

## What changed

**Shell (`MainTabView`, `KeepoTabBar`, `AppNavigation`)**
- Four tabs → **three, icon-only**: Dashboard, Accounts, Transactions. The system tab bar is hidden per tab (`.toolbar(.hidden, for: .tabBar)`); `KeepoTabBar` is our own capsule, mounted as a **bottom `safeAreaInset`** so lists stop above it instead of scrolling under it.
- **Add is not a tab.** A separate circular button beside the capsule; what it adds is the current screen's business, routed as `AppNavigation.pendingAdd` (set-then-consume, the same shape `transactionsRequest` already used, because all three tabs are mounted at once and an untargeted request would be answered by every one of them). Dashboard → widget catalogue, Accounts → new account, Transactions → new transaction.
- **Profile stopped being a tab.** It is a sheet presented from the shell, opened by the avatar on any scope banner. `openProfile(_:)` still works (the FX widget's base-currency link, the new "Create Household" blank state) — it sets `profilePath` and raises the sheet.
- Needs Review's count is now a dot on the **Transactions** icon, drawn *outside* the selected capsule: on it, a coral dot on the coral selection fill was invisible exactly when the user was looking at that tab.

**Scope banner (`App/Common/Components/Scope/`)** — replaces both the top-left "…" scope menu (`ScopeSwitcherButton`, deleted) and `ScreenTitleBar`.
- A full-bleed colour card per scope, swiped horizontally, on all three screens. `session.scope` is still the single source of truth, so the choice persists across tabs exactly as before.
- `.me` is labelled **"Private"**, not "Personal" — the badge beside the title has to say what is being excluded.
- Flat colours, no gradients (user's call). Total `#FF5A5F`, Private `#5B5BD6`, Household `#0F9B8E`.
- Swipe affordance is a **chevron at each side**, not page dots — it says both that the card swipes and which way there is something to swipe to. The chevron keeps its space when invisible, or the title would jump sideways between cards.
- The card paints up behind the **status bar**. The *scroll view* is pulled up by the top safe-area inset (each card adds it back as top padding), rather than a band drawn behind it: a scroll view clips its content, and a band that is not part of the card cannot slide with it — it leaves a seam of the outgoing colour across the status bar for the whole length of a swipe. The inset arrives via `EnvironmentValues.topSafeAreaInset`, measured in `MainTabView`, because by the time the banner lays out it is already inside the safe area and its own geometry reports zero.

**Blank states (`ScopeContext`, `ScopeEmptyStateView`)**
- One `ScopeContext` owned by the shell answers "does this scope have anything behind it" for all three screens, from one `LocalTableQueries.scopeAvailability` read plus `myHousehold`.
- Four cases: `noAccounts` (button → add account), `noHousehold` (→ Household), `noPrivateAccounts` (no button, by the user's rule), `noSharedAccounts` (→ Household; the mirror of the private case, added for symmetry — flagged to the user, not asked for).
- `noAccounts` outranks every scope-specific case: "share an account" is not advice for someone who has none.
- The decision is a pure `ScopeEmptiness.resolve(...)` so the table is pinned by a test without a session, a database or a view.

**Needs Review moved to Transactions (`App/Features/NeedsReview/`, was `Features/Home/NeedsReview/`)**
- `NeedsReviewView` (a screen behind a bell popover) → `NeedsReviewPanel`, a **drawer that drops from the banner**: exactly the banner's width, pulled up behind it by its own corner radius so only its rounded bottom shows, `zIndex` 0 against the banner's 1. Collapsed it is one row ("5 items need review"); tapping expands the list in place.
- Swipe actions became a visible trailing pill (Confirm / Resolve / Accept) plus a context menu for the destructive ones (Dismiss / Reject) — there is no `List` here to hang a swipe on.
- The expanded list is capped at 300pt with its own scroll, measured via `onGeometryChange`: a `ScrollView` takes every point offered, so "as tall as the rows need, up to a limit" cannot be expressed with `maxHeight` alone, and without the cap a dozen items push the ledger off the screen.

**Scope now actually filters** (behaviour change, not cosmetic)
- The old scope switcher sat in the Accounts and Transactions toolbars and filtered *nothing* — only Home's widgets honoured it. With the scope now named on the banner over the list, that was a contradiction, and blank state 3.7 ("no private accounts") is unimplementable without it.
- `LocalTransactionRow.fetchFiltered` takes a `scope:` and applies the shared `LocalMoneyQueries.scopeFilterSQL` — a separate parameter rather than a field on `TransactionFilter`, because that type also builds the PostgREST query and no server-side scope term exists there to match.
- `AccountsListView` filters its rows on `isShared`, the same predicate.
- **Drag-to-reorder is disabled outside Total.** `reorder_accounts` writes each account's `sort_order` from its index in the array it is handed, so a filtered subset would renumber those rows 1…n and leave every hidden account on the positions they just took. The gesture is not disabled because a subset is awkward to drag; it is disabled because a subset cannot express the write.

## Bugs found while building, and where they were actually fixed

1. **The banner showed the wrong scope on every tab switch.** `scrollPosition(id:)` bound to a computed `session.scope` binding only obeys a *change*; a scroll view entered while the scope was already Household starts at offset zero, drawing the Total card over Household's data. Fixed by giving the carousel its own `@State` position, seeded the moment `onGeometryChange` first reports a non-zero width — the first moment a scroll target exists at all.
2. **The Needs Review panel never loaded.** `Group { if items.isEmpty { EmptyView() } else { panel } }.task { load() }` — the task that fills `items` was attached to a view that resolved to `EmptyView` while empty, so it never ran and the panel could never stop being empty. A `VStack` container that always exists fixes it. Watch for this shape anywhere else.
3. **The widget catalogue's last entries sat under the floating tab bar.** It carried `.ignoresSafeArea(edges: .bottom)` from when the system bar existed. Now the panel's *layout* stops at the safe area and only its **background** paints through to the screen edge.
4. `.ignoresSafeArea` **repositions a rigid view, it does not stretch it** — a `Color.frame(height: 1)` expanded into the top safe area rendered as a 1pt line at the screen top, not a filled band. This is why the status-bar treatment moved into the scroll view's own frame.

## Second pass (same day, user feedback)

- **No gradients anywhere.** Scope colours are flat; the tab bar and Add button lost their coral entirely.
- **Banner cards are full-bleed** with a subtle bottom shadow, no subtitle, and **page dots inside the card** (an `.overlay` on the carousel, not a row below it — the dots report position, so they must not travel with the cards).
- **The carousel is hand-rolled, not a paging `ScrollView`.** The requested feel — heavy at first, then past a point of no return the card leaves on its own — is not expressible with paging. `resisted(_:)` moves the card as the **1.6th power** of the finger's travel; at 30% of the width the gesture stops being consulted and a spring finishes the trip. At the ends the exponent is 3.2 and nothing commits, so "there is nothing that way" is felt.
- **Soft top edge** (`FadingTopEdge`) on all three screens: a **mask**, not a gradient overlay — the content scrolls over cards, separators and charts, so removing pixels is the only way the real background comes through.
- **Tab bar carries titles and is fully neutral.** Selection is weight and contrast. The one colour left is the mango needs-review dot, which reports a fact rather than a location.
- **Transactions' filters moved into the header** behind a funnel button, drawn on a panel a shade darker than the card (`AccountScope.panelTint`, derived from `tint` so it can never drift). Account **and category** menus, search, and a period control shaped like the dashboard's own `TimeframeFilterView` — a bordered track around all five options, since the border is what says they are one control. The panel is tucked up behind the card by the corner radius, the same trick the inbox drawer uses.
- **The inbox expands to a full view** and, when the last item clears, holds an "All caught up" state for two seconds before collapsing back to the ledger. `isExpanded` is owned by the screen, not the panel: expanding hides the ledger, and the drawer cannot hide a sibling it does not own.

Two things worth knowing before touching this again: `.ignoresSafeArea` **repositions a rigid view rather than stretching it**, which is why the status-bar treatment lives in the carousel's own frame (negative top padding, each card adding the inset back) rather than a band behind it; and a band that is not part of the card cannot travel with a swipe, so it would leave a seam of the outgoing colour across the status bar for the whole gesture.

## Third pass (same day, user feedback)

- **The banner is a deck.** A 14pt gap between cards so the page shows through mid-swipe, and each card tilts (±2.5°) and shrinks (to 0.965) in proportion to `travel(at:)` — its distance from home as a fraction of one step, 0 at rest and ±1 at the neighbour. `.clipped()` was **removed**: every neighbour is already off the screen's own edge, and the clip was the only thing that would have flattened the tilt back into a rectangle. The banner therefore needs `.zIndex(1)` on all three screens so a tilted corner draws over the content beneath it.
- Commit thresholds and the resistance curve now measure against `step` (card + gap), not the card alone, so the feel is unchanged by the gap.
- **The current page indicator is a pill**, the others dots — length reads as "you are here" at a glance, where two circles of different sizes have to be compared.
- **A subtle top-to-bottom gradient on the header card** (7% darker at the top). This is the one deliberate exception to the no-gradients rule from pass two; it is depth on a single surface, not two colours.
- **Filter panel**: 10pt more room under the card's edge, and a third pill — Expense / Income / Transfers — writing `TransactionFilter.kind` with the same three strings the query's `CASE` derives, so nothing translates. The three pills live in a horizontal `ScrollView` for the long-account-name case; their unset labels are the axis ("Accounts", not "All Accounts") so all three fit a phone's width without the last being sliced by the scroll edge. **A pill that is doing something goes solid white** with the panel's colour, matching the selected period segment — a filter must not be able to be on invisibly while the panel is shut. The funnel keeps its own dot for the same reason.
- **The tab bar and Add button are Liquid Glass** (`glassEffect(.regular, in:)`), not the `.regularMaterial` blur they were — gated on `#available(iOS 26.0, *)` since the deployment target is still 18.0, with the material as the fallback. Both treatments draw their own edge, so the hand-drawn hairline border went.
- **Tab labels sat on three different baselines** because `list.bullet.rectangle.portrait` is taller than `creditcard`. The icon now gets a fixed 20pt box.

## Fourth pass (same day, user feedback)

- **The tab bar floats; it no longer reserves a strip.** A bottom `safeAreaInset` was drawing a band of page background under every screen that read as part of the design rather than as the edge of the content. It is an `.overlay` now, content runs to the screen edge and passes under the glass, and every scrolling surface leaves `KeepoTabBarMetrics.clearance` below its last row instead.
- **Bar and Add button are concentric with the display.** Same height (54), same 30pt margin from left, right and bottom, so the inner radius (27) is the outer one minus the gap — which is the only way a rounded corner nested in another looks right. There is no public API for the display's radius (only a private `UIScreen` key), so 30 is calibrated for the 55–62pt family, and `margin` is the single number to move if a new device needs it. The bar is positioned from the **screen** edge via a measured `bottomSafeAreaInset`, not from the safe area: `.ignoresSafeArea` cannot do this from inside an overlay, which is laid out in the parent's already-inset space.
- **The dashboard's first widget cleared the header's fade** — at 4pt of top padding its own top edge was already half dissolved before anything had scrolled.
- **Scope order is Total → Household → Private.** Household is the one a user reaches for next, so it should be one swipe away rather than two.
- Tints pulled back 9% in saturation from the brand values (a full screen of `BrandPrimary` shouted at everything on it), and the gradient's top stop went from 7% to 16% darker.
- **Cards reach 20pt above the screen.** A tilted card's dipping top corner drops by about half its width times the sine of the angle — ~9pt — plus a couple more from the scale, which showed as a hairline of page across the very top for the length of every swipe. The card now simply starts higher than the screen does.
- **Haptics on the swipe**, fired from `commit(to:)` via a local counter rather than a trigger on `session.scope`: all three tabs' banners are mounted at once and a shared trigger would have fired three taps for one swipe.

## Fifth pass (same day, user feedback)

- **The home indicator's inset is gone from all three screens** (`dropsBottomSafeArea`). Floating the tab bar in pass four removed the reserved strip but not the inset behind it: every screen still stopped 34pt short of the display, and the page background filling that gap read as a grey band pinned across the bottom of the app — a list row was visibly sliced off against it. Content now runs to the physical edge and passes under the glass, which is what the clearance below every last row was always for.
- **It has to be applied to the screen's own root view.** Neither the `TabView` nor the `NavigationStack` will pass `.ignoresSafeArea` down — both host their content separately, so on either of them it is inert: the strip stays and the only visible effect is that the shell's overlays move. Both were tried before the third. Hence three call sites, behind one modifier so they cannot drift.
- The shell's overlays — the bar, the offline and pending-sync notices — are **not** covered by that, since an overlay is laid out in the parent's still-inset space. Each carries `− bottomSafeAreaInset` so it is positioned from the true screen edge like the bar already was; the status notices now sit 10pt above the bar rather than 44.
- **Content fades out under the tab bar.** `FadingTopEdge` became `FadingEdges`: the same mask, now with a second ramp at the bottom running the full `KeepoTabBarMetrics.topEdge` (84pt — the bar's top edge above the display). The two ends are different lengths on purpose. The top is a short hand-off to a banner sitting on the content; the bottom has no edge to hand off to now that content runs past the bar to the physical bottom, so the fade is the only thing that ends it. `clearance` is derived from `topEdge` so the fade and the room every last row leaves can't disagree.
- The Needs Review drawer's item list gets the bottom ramp too (`fadingEdges(top: 0)`) — expanded it reaches the display's bottom like the ledger it replaces. On the **rows only**: masking the whole drawer would dissolve its own surface with them.
- **Tab bar icons went from 17pt to 20pt** (and their fixed box from 20 to 23). The plus was tried thinner and put back at 21pt semibold on the user's call.

## Tests

`KeepoTests/ScopeFilteringTests.swift` — scope filtering on the transactions read path (total/private/household), `scopeAvailability` counts (including that an archived account counts towards no scope), and the whole `ScopeEmptiness` decision table. 147 unit tests in 33 suites pass; SwiftLint clean.

## Open

- The **status bar's own text colour** is not managed. It reads acceptably on all three scope colours in both appearances, but nothing forces light content — if a future scope colour is lighter, this needs a real fix (a hosting-controller override; `preferredColorScheme` would flip the whole app).
- The banner's card width comes from `onGeometryChange`, so the first layout pass uses a 1pt placeholder. Invisible in practice; worth knowing if a card ever animates in oddly on launch.
