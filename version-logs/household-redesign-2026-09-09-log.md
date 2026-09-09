# Household redesign — 2026-09-09

Written for the next agent, not for a human reader. Read this before touching
anything under `App/Features/Profile/Household/`, `App/Services/Pairing/`, or
`supabase/migrations/20260913100000_household_setup_and_report.sql`.

User-driven, delivered in one pass. The user supplied a full screen-by-screen
spec; two decisions were confirmed before building (MultipeerConnectivity
alone rather than adding a NearbyInteraction UWB distance gate; build it all in
one pass rather than staged).

---

## What the feature now is

Creating or joining a household used to be: press a button, get a code, text
the code to somebody. It is now a thing two people do standing next to each
other.

1. **Blank state** — Create / Join.
2. **Setup** (identical for both roles, `role` changes the words): what a
   household means → which accounts → which categories.
3. **Discovery** — MultipeerConnectivity. Owner advertises, guest browses.
   Each side sees the other's face and name before anything is created. A QR
   fallback appears after 12s.
4. **Ceremony** — ten narrated steps, a house filling with the household
   colour, particles crossing the gap in the direction the data is moving,
   one haptic per step. Owner narrates, guest mirrors.
5. **Report** (owner only, guest holds at 90%) — five screens: net worth +
   currency shares, accounts, categories with merge/unmerge, tags with
   delete-and-retag, summary.
6. **Household screen** — the report's summary card, permanently, plus the
   info popover, the member sheet, and Leave.

---

## Two live bugs found on the way in

### 1. Leaving a household trapped you in it, permanently

`my_household_id()` has read `household_members` without a `deleted_at` filter
since `20260806090000_households.sql`, when the column did not exist. But
`20260912100000_household_category_sharing.sql` changed `leave_household()`
and `erase_own_account()` to **soft**-delete the caller's membership row — the
sync layer needs a tombstone to push, and a hard `DELETE` never reaches the
other device.

So the row that said "you left" still answered "you are a member":

- `create_household()` → `you already belong to a household`
- `accept_invite()` → `already a member of a household`
- `households_select` kept returning the household you walked out of

Forever, with no error naming the cause. **The blank state this whole redesign
is built on was unreachable for anyone who had ever left a household.**

Every other reader of that table already filtered (`share_category`,
`accept_invite`, `leave_household` itself, `sync_domain_id`). This one was
missed when the column arrived and is the one the others sit on top of. Fixed
in the new migration; three pgTAP assertions at the end of
`31_household_setup_and_report.sql` are the regression test.

### 2. The other member had no face

`avatars_select` was `lower((storage.foldername(name))[1]) = auth.uid()::text`
— own folder only. The Household screen could fetch the other member's *name*
(via the new `household_member_profile()` RPC) and then draw an initial where
their photo should be, which reads as a broken image rather than as a privacy
boundary.

Widened to admit a household member's folder through a `SECURITY DEFINER`
helper, `can_read_household_avatar(text)`. **Not** by inlining the join into
the policy: inside a policy on `storage.objects` the subquery has to
re-reference the outer `name` column, and that qualified form is exactly the
kind of expression that silently matches nothing.

---

## Architecture decisions worth not re-litigating

### The peer link carries a handshake, never the ledger

`HouseholdPairingMessage` carries three things: who you are (name, email,
avatar JPEG ≤ 24 KB), one `create_invite` token, and phase announcements.

Every account, category and tag still crosses through `accept_invite` on the
server, under RLS. A design where one phone hands another phone its balances
directly puts money outside the entire access model — and the access model is
the product.

The avatar bytes are the one exception and they earn it: before the household
exists the two users are strangers to the server, so `avatars_select`
correctly refuses, and the bytes are the only way the discovery card can show
a real face at the moment that matters most.

### The ceremony never runs ahead of the truth

Ten narrated steps sit in front of **four** real pieces of work: minting the
invite, the guest's `accept_invite` (one transaction that applies *both*
members' accounts and categories), the category merge, and two sync pulls.

Every phase in `HouseholdSetupCoordinator` is one of two things and never a
third:

- **Gated** — does not finish until a call returns.
- **Already true** — the state it describes was made true by an earlier gate
  in the same run, and the step is naming it.

`phaseFloor` (560 ms) turns four events into a paced sequence. It can slow a
step down; it can never let one through early. Ten × 560 ms ≈ 6s minimum.

The **owner is the single narrator**; the guest renders `announced.mirrored`
(the owner's "Sharing Accounts" is the guest's "Receiving Accounts"). Two
independently-timed animations drift within a second or two, and two people
watching their phones side by side is precisely when that shows.

Gotcha already fixed: the owner announces the first phase *before* it mints
the token, so `waitForToken()` must handle `.phase` rather than dropping it —
the obvious `default: continue` left the guest sitting on the discovery screen
until the token landed, so the two phones visibly started at different moments.
Second gotcha: the owner's early announcements arrive while `accept_invite` is
in flight and nobody is reading the inbox, so they buffer and then land at
once — `renderPhase` applies the same floor on the way out of the buffer.

### `HouseholdPairingSession` uses a single-consumer inbox, not `AsyncStream`

`AsyncStream` supports exactly one iterator for its whole life, and the
ceremony reads its inbox in two shapes (the owner awaits one specific message
mid-sequence; the guest then loops). Taking a second iterator is undefined
behaviour whose failure mode is a message going to the iterator nobody reads.
Replaced with `pending: [Message]` + a `CheckedContinuation`; `stop()` resumes
any waiter with `nil` so a ceremony can never hang on a peer that has gone.

### The two roles are not symmetrical

Owner **advertises**, guest **browses**, and only the guest sends an
invitation. Both doing both was the first sketch, and it races: two phones
discover each other simultaneously, both invite, and `MCSession` ends up with
two half-open connections to the same peer. The asymmetry costs nothing and
removes the race.

### `categories.merge_origin` — why a new column was unavoidable

The report's headline split is **Merged** ("we both track Groceries") vs
**Extra** ("I track Nightlife and now you can too"). Under 20260912100000 both
are the same shape: a `shared_group_id` with one row per member, because
`ensure_category_twin` creates the other member's row whenever they had no
exact name match.

Every derivation from what the schema already held is a guess:

- **Names** are equal in both cases (a twin copies the name; a merge writes the
  resultant onto both).
- **`created_at`** cannot separate them — a category created *after* the
  household exists and then shared produces two recent rows, exactly like a
  merge of two recent ones.
- **"Has transactions"** is wrong for every brand-new category.

So it is recorded at the one moment anybody knows it. An enum
(`category_merge_origin`), not `text` + CHECK, per CLAUDE.md rule 4 — a CHECK
generates as a plain `String` in codegen.

This meant hand-editing `Generated/SupabaseSchema.swift` at first, because
Docker was down and `supabase gen types swift` could not run. **That hand-edit
was wrong**, in a way that compiled: see the verification section below. Real
codegen has since replaced it. The lesson stands on its own — *never* pattern-
replace inside a generated file on an anchor that is a prefix of a longer
valid token, and never trust a hand-edit to one that you have not diffed.

Also wired: `SyncApply`'s categories column whitelist, `LocalStore`'s
`categories` table, and a `v13_rebuild_syncable_tables` local migration.

### Fuzzy matching: edit distance alone cannot do this job

`CategoryNameMatcher` lives in `KeepoCore` (pure string logic, pinnable by a
test). Applying a match is `apply_category_merges` in SQL (ownership and the
one-row-per-member invariant are enforced there).

**The finding worth remembering:** `Health`/`Wealth` is one substitution across
six letters and scores **0.83** — *higher* than `Dine Out`/`Dining Out` at
**0.75**. No threshold separates them, because edit distance has no notion of
*where* a difference falls.

The fix is a **two-character common-prefix gate** (`gatedEditRatio`): a
difference at the end of a word is an inflection (Rent/Rental,
Transport/Transportation), a difference at the start is a different word
(Food/Fuel, Salary/Solar, Gifts/Gas).

Its cost is that a true synonym pair sharing no opening — `Eating Out` /
`Dining Out` — no longer matches automatically. That is the **correct**
outcome: nothing in those two strings says they are the same category, and the
pass they used to get came from the same arithmetic that passed Health/Wealth.
It is pinned as a *non*-match with the reasoning attached, so nobody
"fixes" it back.

Second-highest-value piece: **singularization**. The commonest real collision
between two people's books is a plural disagreement — Groceries/Grocery,
Salaries/Salary, Holidays/Holiday, Utilities/Utility. All four become *exact*
matches (1.0) rather than fuzzy ones near the threshold.

Threshold 0.72, tuned to over-suggest: a miss is two duplicate categories
forever; a false positive is one row in the report, flagged with the robot
glyph, one tap from unmerged.

### Merging cleans up its own twins — but only twins

`apply_category_merges` releases every row in either old group that is not one
of the two being merged, and **soft-deletes** the ones that are plain twins:
`merge_origin is null`, no transactions, no recurring rules, no
`merchant_category_map` row. Without the delete, merging "Dine Out" with
"Dining Out" leaves each member holding a private copy of the other's original
spelling — the exact duplication the merge removed, wearing a different label.

The `merge_origin is null` guard is load-bearing: re-pointing an existing merge
at a different partner must *release* the old partner (a real category of
theirs), not delete it.

---

## Where things live

```
App/Services/Pairing/
  HouseholdPairingMessage.swift     wire protocol + the 10 phases
  HouseholdPairingSession.swift     MultipeerConnectivity, single-consumer inbox
  HouseholdSetupCoordinator.swift   the ceremony; gates, floors, auto-merge
  HouseholdLinkError.swift
  UncheckedSendable.swift           the one place the @unchecked claim is made

App/Features/Profile/Household/
  HouseholdView.swift               blank state or the live household
  HouseholdBlankState.swift         + info popover, member sheet, peer avatar
  HouseholdKit.swift                container, cards, rows, disclosure, flow bar
  HouseholdData.swift               one snapshot, read once, used by both
  HouseholdSummaryCard.swift        report screen 5 AND the Household screen
  Setup/                            flow, intro, pickers, discovery, QR, ceremony
  Report/                           flow+banner, 4 screens, merge sheet+tiles

App/Features/Profile/ProfileMetricCard.swift   the two cards + BaseCurrencySheet
```

Deleted: `InviteFlowView`, `JoinFlowView(+Preview)`, `HouseholdView+Categories`,
`HouseholdSharePicker`, `HouseholdViewLoader`.

`HouseholdSummaryCard` being **one view in two places** is deliberate: the spec
asks for identical content in the report's last screen and on the Household
screen, and they are genuinely the same question. Two copies would drift on
what "shared" means.

---

## Descoped, deliberately

- **The QR fallback skips the ceremony.** Reaching it means the peer link could
  not be established; performing the two-phones-talking choreography over a
  channel that is one scan and then nothing would have the phones drift apart
  within a second. Same household, same report, no theatre.
- **Tags are never merged automatically.** The "Merging Tags" step does no
  server work and its comment says so. Deciding two tags are one is a
  judgement about somebody's history; the report is where it is made by hand.
- **No `NearbyInteraction`.** It would give a real distance in metres but needs
  U1 on both phones; a pairing flow that silently fails on an iPhone SE is
  worse than one that trusts MultipeerConnectivity's own few-metre reach.
- **`previewInvite` / `InvitePreviewRow` now have no caller.** The RPC and its
  pgTAP coverage are live, so the seam was kept rather than deleted — but it is
  dead client code and deserves a decision.

---

## Verification status

All green as of 2026-09-09, after Docker came back.

| | |
|---|---|
| `supabase db reset` | ✅ all 61 migrations apply from scratch |
| `supabase test db --local` | ✅ **403 tests, 27 files, PASS** (23 new) |
| `supabase db push` | ✅ pushed to `fmogwbadhimwfhhibrau`; local/hosted in sync |
| `supabase gen types swift` | ✅ re-run; diff reviewed (see below) |
| `xcodebuild -scheme Keepo build` | ✅ clean |
| `xcodebuild ... test` | ✅ TEST SUCCEEDED |
| `swift test` (KeepoCore, 199) | ✅ green |
| `swiftlint` | ✅ 0 violations, 293 files |
| Simulator walkthrough | ⚠️ not done — the interesting half needs two devices |
| Two-device pairing | ❌ **still the outstanding item** (= human review stop #4) |

### Two things the verification caught

1. **The pgTAP fixture invented `transactions.kind`.** There is no such
   column: direction is the sign of `amount_e4` (money rule 1),
   `category_kind` is set by trigger, and `currency` must travel with
   `account_id` because `account_currency_together` is
   `(account_id IS NULL) = (currency IS NULL)`.
2. **The hand-edit to `SupabaseSchema.swift` had silently corrupted an
   unrelated field.** See the `merge_origin` section above — the anchor
   `public let kind: CategoryKind` also matches the *prefix* of
   `public let kind: CategoryKind?`, so the replace ate the `?`. That is
   where the stray `CategoryMergeOrigin??` came from, and "fixing" the `??`
   moved the optionality onto the wrong field. It compiled because nothing
   constructs `CategoriesUpdate`. Real codegen output replaced it wholesale
   and independently emits `merge_origin` in all six places, which is the
   confirmation that the column landed as intended.

## Gotchas for the next agent

- **`NSBonjourServices` is an array**, so it lives in `App/Info.plist` (the
  partial plist), not as an `INFOPLIST_KEY_*` build setting. It must match
  `HouseholdPairingSession.serviceType` exactly. Get it wrong and **nothing
  errors** — the browser starts and never reports a peer.
- **There is no API that tells you the local-network permission was denied.**
  Denial, Bluetooth off, blocked peer-to-peer Wi-Fi, and an empty room all
  present identically: `foundPeer` is never called. That is the entire reason
  the discovery screen has a timer and a fallback instead of an error state.
- **MultipeerConnectivity needs two physical devices** to test properly. The
  identity exchange also deliberately refuses two phones signed into the same
  account, which is what two simulators on one Mac would be — caught there,
  where it can be explained, rather than four steps later inside
  `accept_invite` as "cannot accept your own invite".
- **Swift 6 strict concurrency**: `MCPeerID`, `MCSession`,
  `MCNearbyServiceBrowser`, `AVCaptureSession` and the invitation handler are
  all non-`Sendable` framework types delivered on a framework queue. They go
  through `UncheckedSendable`, which is the one place that claim is made, with
  the reasoning. Do not reach for it for a type of our own.
- `AVCaptureMetadataOutputObjectsDelegate` must be `nonisolated` — a
  main-actor-isolated conformance is a hard compile error. The callback queue
  is already `.main`, so the explicit hop is free.
- `PublicSchema` types are plain `Codable` structs with **no `Identifiable`**.
  `sheet(item:)` needs one; wrap the selection (`PruningTag`) rather than
  retrofitting an extension onto a generated file.
- `CategoryTile` already existed in `CategoriesView`. The merge sheet's are
  `MergeCategoryTile` / `MergeEmptyTile`.
- `LocalAccountRow` gained `ownerId` — the household screens are the only
  consumer, and it is the only thing that splits "Shared by you" from "Shared
  with you".
- `LocalTableQueries.categories(_:ownerId:)` stays owner-scoped on purpose
  (the composite FK still forbids filing a transaction under the other
  member's row). The household screens take the new
  `householdCategories(_:)`, which is unfiltered.
