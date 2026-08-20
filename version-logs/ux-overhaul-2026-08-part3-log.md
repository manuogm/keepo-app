# UX overhaul, part 3 — Accounts drag model, transaction form rebuild, and the real cause of "laggy"

Written for the next agent. Part 1 removed Insights/FI and reshaped Home/Accounts/Transactions;
part 2 was a second feedback pass plus the archived-accounts net-worth fix. This is a third,
larger pass driven by a single user report: *"the app doesn't look appealing and the UI elements
keep being a bit laggy or unresponsive when tapped."*

## The performance problem was not what it looked like

The instinct was to suspect the local SQLite reads (`LocalAccountRow.fetchAll` runs two queries
plus an FX conversion **per account**). That is not where the time was going. Four real causes,
in rough order of impact:

1. **`MoneyFormatter` constructed a fresh `NumberFormatter` on every single call.** So did
   `AmountParser` (per keystroke) and `AmountFormatter` (per prefill). `NumberFormatter()` is one
   of the most expensive objects in Foundation to build. A 50-row transactions list renders two
   money labels per row, and SwiftUI re-evaluates those bodies on every unrelated state change.
   **Fixed** by `KeepoCore/FormatterCache.swift` — formatters cached by everything that can vary
   about them (`NSLock` + `nonisolated(unsafe)`, matching `LocalStore`'s own precedent).
   Formatters are configured exactly once, inside the lock, before ever being returned; concurrent
   `string(from:)` reads on a fully-configured formatter are safe.
2. **Rows were plain views with `.onTapGesture`, not `Button`s.** A bare tap gesture inside a
   `List` competes with the scroll view's own recogniser — the first tap after a scroll settles is
   routinely swallowed — and it draws no press state, so a row that is working perfectly still
   reads as broken. **Fixed** by `PressableRowButtonStyle` (`.pressableRow` / `.pressableCard`),
   which draws the press on the first frame of the touch, before any `await`.
3. **Real work inside `body`.** `TransactionsListView.groupedByDay` was a computed property doing
   a full `Dictionary(grouping:)` plus a sort over every transaction in the period, re-run on every
   render pass. **Fixed** by computing it once per load into `@State` (`regroup()`), along with a
   `categoriesById` lookup that was previously a linear scan per row per render.
4. **No haptics anywhere.** Added `.sensoryFeedback` on selection-changing controls. Cheap, and it
   does more for perceived responsiveness than anything else on this list.

`Color(hex:)` was also memoised (`HexColorCache`) — small, but it allocated a `Scanner` per row per
render for a value with as many distinct results as there are stored colours.

## Three requested features needed schema work, not just UI

Migration `20260903100000_account_order_kind_and_card_provenance.sql`:

- **`accounts.sort_order`** + `reorder_accounts(uuid[])` — drag-to-reorder. One statement server-side,
  so a drag is one round trip however many rows shifted.
- **`accounts.kind` becomes mutable** via `set_account_kind` — drag between the Everyday and
  Investments groups. `20260902100000` had left kind immutable and said why in its own §7: *not*
  because anything downstream depends on it, but because changing it would be surprising. Dragging
  the row is the user asking for exactly that, so that reason no longer holds.
- **`card_mappings.source`** (`manual` | `automatic`) — the Mapped Card popup distinguishes a card
  the user named from one the capture pipeline linked for them. The distinction already existed
  structurally (`map_card` is only ever a user action; `link_card_to_account` is only ever called
  on the user's behalf), it was just never written down on the row.

`pull_changes` uses `to_jsonb(row)` per table, so new columns reach the client for free — only
`LocalSchemaV1` (plus a `v6_rebuild_syncable_tables` migration) and `SyncApply.tableColumns` needed
updating.

### The one genuinely subtle piece: a reorder must not bump `version`

`accounts_bump_version` fires BEFORE UPDATE on every column, so a pure `sort_order` write would
increment `version` on every dragged row. That is wrong in a way that reaches the user: `version` is
the optimistic-concurrency token, so a drag would invalidate the `expectedVersion` every client
holds for those rows and turn the next genuine edit into a `sync_conflicts` row that conflicted with
nothing. It also matters because dragging across a header is ONE gesture that is TWO writes
(`set_account_kind` + `reorder_accounts`).

Two wrong answers were written and thrown away before the right one, both caught by the pgTAP suite:

1. A dedicated `bump_account_version()` that *inferred* the exemption ("did any column other than
   `sort_order` change?"). Unsound: `set_account_balance` ends with a bare `set updated_at = now()`
   whose only purpose is to bump the version, and `now()` is frozen per transaction — so "nothing
   else changed" and "the bump was the point" are indistinguishable. Broke
   `21_set_account_balance.sql`.
2. The same function, which also silently dropped `bump_version()`'s existing `keepo.restamp_only`
   check. Broke `share_account` (`23_sync_primitives.sql`).

**The right answer needed no new machinery at all**: `keepo.restamp_only` already exists for exactly
this (`restamp_account_for_sync`, migration 20260816100000) and both `bump_version()` and
`set_updated_at()` already honour it. `reorder_accounts` simply opts in. Grep for an existing
mechanism before writing one — this project had already solved this problem once.

## The Accounts drag model

All three requested behaviours are **one mechanism**. The two groups render as a single `ForEach`
over a flat `[Item]` in which the group headers are themselves items (`.moveDisabled(true)`), so a
single `.onMove` sees every drag: an account's kind is the kind of the nearest header above it once
the move lands, and its order is its index within that run.

Mixing `.onMove` (within-group) with `.draggable`/`.dropDestination` (across-group) was the obvious
alternative and is worse — the two gesture systems fight for the same row, and a drop target cannot
express "between these two rows" the way an insertion point does.

Both headers always render, including for an empty group, or the conversion gesture is
undiscoverable exactly when the user most needs it. A collapsed group keeps its header, which is
what still makes it a valid drop target.

**`.onMove` on a plain `List` does enable drag-to-reorder without edit mode on iOS 18** — verified
in the simulator, and the scripted `touch_path` gesture (long press, then drag) triggers it reliably,
unlike the `swipeActions` reveal that `lessons-learned.md` records as unscriptable.

Layout note: this forced `.plain` over `.insetGrouped`. An inset-grouped `List` draws one rounded
card per `Section`, and the headers are inside the single `ForEach` — so the card wrapped them too,
leaving every account row with square corners in the middle of it. Rows now draw their own
backgrounds, which also makes each account read as its own liftable object.

## Bugs found by running it, not by reading it

- **`sort_order` is unique only WITHIN a kind**, so `ORDER BY sort_order, name` interleaved the two
  groups. Harmless on the Accounts list (which filters into two arrays) but every consumer of the
  flat list saw a jumbled order — a new expense defaulted to the brokerage account. Fixed with a
  leading `CASE kind` term in `LocalAccountRow.fetchAll`.
- **New accounts landed at `sort_order = 0`**, ahead of everything already arranged. Fixed with an
  `accounts_set_sort_order` BEFORE INSERT trigger (a property of the column, not of one caller —
  `accounts` is inserted into from `create_account`, `fork_one_account`, and fixtures).
- **`CurrencyConversionLabel` still drew a minus** under a ledger-style amount, so a row read
  `€125.00` over `-$115.00`. `signStyle` is now threaded through, defaulting to `.standard` (a
  balance genuinely needs its sign).
- **The mapped-card popup filled the whole sheet.** `presentationBackground(.clear)` makes the
  background clear but the sheet is still full height. Fixed with an explicit `.aspectRatio(1.586)`
  on the card and the actions moved onto the curtain below it.

## Deliberately not done

- **Category "Share with Household"** — omitted on the user's explicit call. There is no backend for
  it at all: categories are strictly `owner_id`-scoped, there is no `household_categories` table, no
  RLS, no RPCs, no sync branch, and every category read query would have to widen. That is
  Phase-7-sized work, not a toggle.
- **The brand palette** (`keepo-brand-identity.md` §1) is still unimplemented — none of the six
  colour sets exist in `Assets.xcassets` and the app runs entirely on system semantic colours. The
  user chose to keep it that way this round. Worth knowing that doc and the code disagree.

## Test coverage added

- `supabase/tests/26_account_order_kind_card_provenance.sql` — 21 assertions covering ordering,
  the version exemption, kind conflict handling, the per-group `sort_order` trigger, and every
  provenance case including the load-bearing one (a `capture_transaction` placeholder row must not
  poison the provenance of the automatic link that resolves it).
- `MoneyFormattingTests` — ledger sign style, including `Int64.min` (`abs()` traps; the formatter
  must not be the thing that crashes).
- `KeepoTests/AlwaysFailingSender.swift` — five byte-identical `private` copies of this stub existed
  across the test suite and all five broke at once when `OutboxSending` gained two methods.
  Consolidated to one.

---

## Feedback round 2 (same session)

The user reviewed the above on device and sent a screen-by-screen list. Most
of it was straightforward layout work; four items were real defects.

### The two drag edge cases were one root cause

Reported as two separate bugs — dragging Everyday→"first row of Investments"
landed the account at the *bottom of Everyday*, and dragging Investments→"last
row of Everyday" was refused entirely. Both were `.moveDisabled(true)` on the
group headers.

Diagnosed by instrumenting `handleMove` and reading the real `(offsets,
destination)` off the console rather than reasoning about UIKit's drop
targeting: the downward case reported the *header's own index* (so the flat
list resolved it to "still in the previous group"), and the upward case
produced **no `onMove` call at all**. A non-movable row makes its own index a
dead zone. Removing `moveDisabled` and ignoring header drags in `handleMove`
fixed both; UIKit displaces the header as you drag over it, which is also what
makes both sides of the boundary visibly reachable. Verified all three
gestures end-to-end against the server afterwards.

### `.deleteAccountDialog(self)` was a latent crash

`AccountFormView` passed **itself** into two `View` extension modifiers, which
stored it in their closures — inside the view's own `body`. It had worked for
a while; adding one more `@State` property tipped it into a hard
`EXC_BAD_ACCESS` inside `initializeWithCopy`, before the sheet drew anything.
The crash report's top frames pointed straight at
`AccountFormView.formContent.getter` → `ViewBuilder.buildExpression`.

Fixed by giving the modifiers the values they actually read (a `Binding<Bool>`
and closures). **A modifier should never take the whole view.** Worth grepping
for other `self`-passing modifiers if one is ever tempting again.

### An account balance was losing its sign

`AmountFormatter.editableString` is unsigned by design — for a *transaction*
the sign belongs to the kind, and prefilling "-12.50" into an expense field
invites double negation. But the account form's balance field used it too, so
a credit card at -840.00 rendered as "840.00", and because the field
round-trips through `AmountParser`, saving anything else on that form would
have written the balance back **positive**. Added an opt-in `signed:` flag,
used only for balances, with tests covering both directions (including one
that pins the unsigned round-trip as the bug it is). The minus is also drawn
ahead of the currency symbol — `-$840.00`, not `$-840.00`.

### Transfers can carry a note

Migration `20260904100000` adds `p_notes` to `create_transfer` and
`update_transfer`, written to **both** legs. `transactions.notes` always
existed; the RPCs simply never accepted one, so the transfer tab was missing a
field expense and income both had, for no data-model reason.

### Smaller items

- Drag preview: `.contentShape(.dragPreview, RoundedRectangle(...))` — without
  it the lift snapshots the whole row rect as a square-cornered, full-bleed
  slab that looks nothing like the card the user grabbed.
- Toggles in dark mode were a blank white pill: `MainTabView`'s
  `.tint(Color.primary)` propagates to every descendant, and `Color.primary`
  is white there. Every `Toggle` now sets `.tint(.green)` explicitly.
- Credit cards take their face from the account colour (`CreditCardFace`),
  varied by a **stable FNV-1a hash of the card identifier** — not by index,
  or a card would change colour when another is added in front of it.
- Icon catalogue: hero pinned outside the `ScrollView`, colours capped at two
  rows, and the custom-colour sheet deleted in favour of a system
  `ColorPicker` laid transparently over the dashed "+" swatch, so the picker
  opens on the first tap.
- Category kind now comes from the tab the user was on, as a `Mode` parameter,
  rather than a second picker inside the form.
- "Make recurring" is hidden on the transfer tab: `recurring_rules` has a
  single account/category pair, so there is no shape in the schema for a
  recurring transfer.

