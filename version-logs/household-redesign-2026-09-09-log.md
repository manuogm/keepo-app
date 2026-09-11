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
| Simulator walkthrough | ✅ done — and it found two real bugs, below |
| Two-device pairing | ❌ **still the outstanding item** (= human review stop #4) |

### What the simulator walkthrough caught

Worth doing: the flow **looked** finished and was not.

1. **The setup pickers rendered empty over loaded data.** The step was a
   computed property reading the flow's `@State` from inside
   `navigationDestination(for:)`; that closure holds a `self` struct copy
   from an earlier body evaluation, so it read a pre-load snapshot while the
   state itself was correct. Fixed by moving the flow's data into
   `HouseholdSetupModel` (`@Observable`). **Do not move it back onto the
   view.**
2. **The Household summary's disclosures counted the wrong collection** —
   `count:` came from what is *shared* while the body listed shared +
   shareable, so an untouched household drew "Nothing here." over the
   accounts you went there to switch on.

Also hardened: the pickers now take `isLoaded` and show a spinner rather
than asserting "you have none" before the read lands.

### Two things the migration verification caught

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

---

## Second pass, 2026-09-10 — what two physical devices found

Five things, four of them one root cause wearing four faces.

### The merge pipeline (feedback items 1.1 and 1.2)

Reported as "fuzzy matching skips easy wins like Dine Out / Dining Out" and
"manually merging does nothing". Neither was a matching bug: `Dine Out` /
`Dining Out` scores 0.75 against a 0.72 threshold and has been pinned in
`CategoryNameMatcherTests` since the day the matcher was written. Replaying
the whole ceremony in one rolled-back transaction proved the SQL correct too
— `apply_category_merges` links the rows, renames both, and retires the twins
exactly as designed.

Three client-side defects between the server and the screen:

1. **`SyncEngine.pull()` dropped overlapping callers** (`guard !isSyncing else
   { return }`). Every merge is *RPC, pull, re-read* — so a merge that
   overlapped any other pull re-read the mirror from before its own write.
   Now chained: concurrent callers are serialized, never dropped.
   `SyncEngineTests` asserts both halves (`callCount == 2`,
   `maxConcurrent == 1`).
2. **Merge tombstones were unreadable to the member who needed them.**
   `apply_category_merges` retired each redundant twin with
   `deleted_at = now(), shared_group_id = null`, and `can_read_category`
   admits another member's row only while the group link is there. The delete
   was invisible to the other phone, so its mirror kept a phantom category
   inside the merged group. The tombstone now keeps `shared_group_id`
   (migration `20260916100000`); nothing reads a deleted category on either
   side, and the propagate trigger already skipped them.
3. **`pull_changes` was rate-limited at 30/60s** — reachable by the report
   itself — and a tripped limit surfaces only in `OfflineStatusBar`, which
   sits *under* the report's full-screen cover. Raised to 120/60s, and the
   report now renders `lastErrorMessage` itself.

Two hardening changes alongside: the automatic pass re-syncs and looks again
before concluding there is nothing to merge, and `unshare_category` /
`unmerge_category_group` bump both members' `sync_epoch`, because taking a
live row out of a shared group is a revocation and no incremental pull can
express one.

### Better matching, since it was asked for (item 1.1)

`CategoryNameMatcher.concepts` — a curated finance synonym lexicon applied
after singularization, so `Eating Out`/`Dining Out`, `Home`/`House`,
`Gym`/`Fitness`, `Bills`/`Utilities`, `Petrol`/`Fuel`, `Kids`/`Children`
arrive at the scorer already identical. Spelling and meaning stay separate
steps: `normalize` settles spelling, `concepts` settles meaning. Ambiguous
words ("Food", "Gas") are deliberately absent and pinned as absent.

`("Eating Out", "Dining Out")` and `("Home", "House")` moved from the
non-match list to a new "synonyms that share no spelling" suite. The gate and
the threshold are unchanged — they were never the problem.

### Ceremony progress on the guest (item 2)

The guest draws `phase.mirrored`, and `mirrored` swaps two pairs that sit on
either side of an ordinal boundary. Taking `fill` from the mirrored phase made
the guest read 9, 27, 18, 45, 36, 54, 72, 63, 81, 90. Progress now lives on
`HouseholdSetupCoordinator.fill`, taken from the **announced** phase and
clamped monotonic; `mirrored` is documented as wording-only.

### Permission timing (item 3)

`HouseholdPairingSession.primeLocalNetworkPermission()` (own file, for the
length lint) starts the real advertiser and browser on the real `serviceType`
for two seconds, from the intro screen's `.task`. There is no API that
requests this permission — using Bonjour is the request — so the only way to
move the prompt is to move the usage. Nothing is reported back: a denial still
looks exactly like an empty room, and the QR fallback is still the answer.

### Verification

SwiftLint 0/296 · `xcodebuild test` TEST SUCCEEDED · pgTAP **419 tests, 29
files, PASS** (new file `33_merge_tombstones_reach_the_other_phone.sql`).
The four UI-visible changes are **not** visually verified — they need the two
devices.


---

## Third pass, 2026-09-10 — re-testing all three reported failures on two devices

Three features were reported as still broken after the second pass: manual
category merge, automatic category merge, and deleting a tag with re-tagging.
All three were reproduced or refuted against a real two-device run (two
simulators, MultipeerConnectivity, the full ceremony) rather than by
reasoning. **One was a real, previously unfound bug; the other two are
already fixed on this branch and behave correctly.**

### Tag delete with re-tagging (item 3) — a genuine bug, now fixed

Reproduced exactly as reported: the server ends up correct (`Holidays`
tombstoned, both transactions moved onto `Holiday`) and the report goes on
listing two tags, on both the QR road and the paired ceremony.

The cause is the second pass's own rule, applied to the table it was not
applied to. `can_read_tag` admits another member's tag on exactly one ground —
it currently sits on a **live** `transaction_tags` row of a shared account —
and `delete_tag_retagging`'s first job is to empty that set. So the statement
that tombstones the tag is the statement that hides the tombstone from the
member who pressed the button. `pull_changes` is incremental and RLS-scoped;
a row you cannot see is a row you are never told about.

Unlike `categories`, the tombstone cannot simply keep what makes it readable:
a tag's visibility is a *join* the delete necessarily destroys, not a column
it can hold on to. That is the case `sync_epoch` exists for. Migration
`20260918100000`:

* `household_sharing_tag(uuid)` — the second branch of `can_read_tag` asked
  the other way round ("whose household is about to stop seeing this"),
  granted to nobody and called only from the two definer bodies below.
* `delete_tag_retagging` captures it **before** moving any links and bumps
  both members' epochs at the end. Restated from `pg_get_functiondef`; the
  body is otherwise byte-identical.
* `cascade_tag_soft_delete` does the same for the other road to the same
  revocation — a plain `update tags set deleted_at = now()`, which is what
  the Tags screen writes through the outbox. Without it, deleting your own
  shared tag left the *other* member holding it forever.

A tag no other member could see bumps nobody, so the common case still costs
no re-pull.

### Manual and automatic merging (items 1 and 2) — correct on this branch

Both work, verified in the UI on two devices with the exact pairs reported:
`Dine Out`/`Dining Out`, `Utilities`/`Utilities & Bills`, plus
`Transport`/`Transportation`, `Salary`/`Salaries` and the exact-name
`Groceries`. Automatic merged five; the manual sheet moved `Nightlife` /
`Going Out` from Extra to Merged, and the counts updated in place (5 merged /
2 extra → 6 / 0). Server state matched the screen at every step.

`supabase migration list` confirms the hosted project is current through
`20260917100000`, so the server is not the difference. **`35530f5` — the
commit carrying the second pass's *client* half — is on `dev` only; `main`
is 37 commits behind it.** Migrations are pushed from the working tree
regardless of branch, so a device build made from `main` runs the new
server against the old `SyncEngine.pull()`, the one that opened with
`guard !isSyncing else { return }` and dropped any pull that overlapped
another. Every local-first mutation is *call the RPC, pull, re-read the
mirror*; a dropped pull re-reads the mirror from before its own write and
redraws unchanged. That is symptom 1 and 3 exactly, and the automatic pass
reading a stale mirror is symptom 2. **Check which commit the device build
came from before re-testing.**

### The report no longer reports success it cannot see

Whatever the environment turns out to be, the reason three different causes
all arrived as one useless bug report is that every action on the report
treated *the RPC returning* as the end of the operation. It is not: the
report's content comes from the local mirror, so the act is finished when
the mirror reflects it. Between those two moments sat all three failures —
a tombstone RLS hid, a pull that failed, a pull that was dropped — and in
every case the sheet dismissed, the list redrew identically, and nothing
said a word.

`HouseholdWrite` (new) is now the one write path for merge, unmerge and tag
prune: run the RPC, sync, then **confirm against the mirror**. If the write
is not visible it re-syncs once (the epoch bumps behind these writes make
the pull a wipe-and-re-pull, which can still be landing) and then reports
`NotVisible` — the sheet stays open, carrying whatever the sync layer
itself complained about, and the user gets a retry instead of a shrug.

Verified by forcing the failure: with `pull_changes` rate-limited, the merge
lands on the server and the sheet holds with *"Saved, but this phone hasn't
caught up yet. Rate limit exceeded"*; clearing the limit and pressing the
check again completes it (Extra 2 → 0). That is the reported symptom,
reproduced deliberately, now carrying its own diagnosis.

### One hardening change alongside

`HouseholdAutoMerge` skipped any shared group whose partner row had not
landed in the local mirror, and re-synced only when it had found *nothing at
all*. A half-landed pull therefore merged an arbitrary subset of the
near-misses — and a skipped group does not appear under Extra either (the
report's `split` drops it for the same reason), so there was no manual
fallback. It now counts half-groups and treats any of them as a mirror worth
re-reading, which is the precise shape of "some pairs merged and some didn't".

Also removed a never-assigned `errorMessage` from `HouseholdReportTags`.

### Unrelated repair

`06_account_lifecycle.sql` test 9 had been red since `20260917100000` renamed
`delete_account`'s refusal for a human reader; the assertion still pinned the
old sentence. Updated to the new wording and to the explicit `p_cascade =>
false` the refusal now belongs to. The behaviour under test is unchanged.

### Verification

SwiftLint 0/298 · `xcodebuild test` TEST SUCCEEDED · pgTAP **428 tests, 30
files, PASS** (new file `34_tag_deletes_reach_the_other_phone.sql`) ·
`supabase gen types swift` diff clean (the migration adds functions only) ·
**all three features exercised by hand on two simulators**, owner and guest,
through the real pairing ceremony — twice, and once more with the pull
deliberately broken to prove the new failure path.

---

## Fourth pass, 2026-09-10 — the cause underneath all of it

The third pass shipped a real fix for tags and a safety net for the report,
and item 1 and 2 came back from the phones unchanged. The safety net is what
identified the cause: the manual merge failed with **"Saved, but this phone
hasn't caught up yet. Check your connection and try again."** That sentence
is the `reason == nil` branch — the pull had **succeeded and carried
nothing**. Not rate-limited, not offline, not dropped. Empty, and correct to
be empty.

### One cursor, two sequences

`stamp_sync_seq_owner` stamps every row `next_ticket(sync_domain_id(owner_id))`,
and `sync_domain_id` is "your household if you are in one, otherwise
yourself". So joining a household moves every subsequent write onto the
household's sequence — and `next_ticket` starts a brand-new domain at **1**.

`pull_changes` is `sync_seq > p_cursor` across every table, and the cursor it
returns is `max(sync_seq)` over everything the device can see. One scalar,
spanning two sequences, with nothing keeping them monotonic with respect to
each other.

For a user with real history:

* their private domain has issued, say, 5,000 tickets;
* `accept_invite` bumps both epochs, the device wipes and re-pulls from 0,
  and its cursor lands on ~5,000 — their own pre-existing rows, still
  stamped in the private domain, are the high-water mark;
* the household domain starts at 1, so every category twin, every merge,
  every tag prune is stamped 2, 3, 4 …;
* `pull_changes(5000)` matches none of them and returns an empty payload
  with no error at all.

Proven in a rolled-back transaction: `apply_category_merges` returns 1, both
rows are renamed on the server at `sync_seq` 13 and 14, and
`pull_changes(5000, 0)` reports `categories_delivered = 0`. After the fix the
same script delivers 4.

**This is invisible on a seeded account.** Twenty rows of history means the
household's sequence overtakes the cursor inside the ceremony itself, which
is exactly why two full two-device runs passed here and the same build failed
immediately on two real phones. Every fix in the three passes before this one
— the tombstone keeping its group, chaining overlapping pulls, raising the
pull rate limit, bumping epochs on revocation, confirming writes against the
mirror — was downstream of a cursor that could never advance to meet the new
domain. All of them were real bugs. None of them was this one.

### The rule

**A domain a user is moved into must start ahead of any cursor that user's
devices could already hold.** The move is always a `household_members` write
— `create_household` and `accept_invite` insert or revive a row,
`leave_household` and `erase_own_account` retire one — so `20260919100000`
puts the guarantee on that table as a trigger rather than into four function
bodies. Nothing existing is restated, and a fifth call site cannot forget it.

`sync_high_water()` is deliberately the **global** maximum rather than the
user's own rows: a member's cursor is the high-water mark of everything they
can *see*, which includes the other member's shared accounts, transactions
and categories, so a per-owner max would under-read in exactly the case this
exists for. Over-allocating tickets costs nothing — `sync_seq` is bigint and
cursors are compared, never counted.

Leaving strands a cursor in the other direction: the departing member goes
back to their own sequence, which stopped the day they joined while their
rows climbed into the household's. Both directions are raised.

### Repairing the households already stranded

A household built before this migration started at 1 and is very likely still
below its members' cursors — which was the live bug on real phones. Raising
the domain fixes every write from here on, but the writes made *during* the
stalled window carry tickets no cursor will ever reach again, so the members
also re-pull in full. `sync_epoch` is bumped for the domains that actually
moved, and only those: a household already ahead of its members costs nobody
a wipe.

### Verification

pgTAP **435 tests, 31 files, PASS** (new file
`35_sync_domains_stay_ahead_of_cursors.sql`, whose central assertion is the
one that returned 0 before) · SwiftLint 0/298 · `supabase gen types` diff
clean.

End to end in the app **with the failing precondition reproduced**: both dev
identities given private domains that had already issued 5,000 and 3,000
tickets, with every row re-stamped accordingly. The new household domain
opened at **5017** rather than 1; the automatic pass merged Dine Out/Dining
Out, Utilities/Utilities & Bills, Transport/Transportation,
Salary/Salaries and Groceries, all visible in the report (5 Merged / 2
Extra); the manual merge of Nightlife/Going Out completed and dismissed (6 /
0); the tag prune completed and the list fell to one. Driven through the QR
road on a single simulator, which advertises nothing over Bonjour.

### A note for whoever tests next

`supabase gen types swift` (as CLAUDE.md writes it) now errors on CLI 2.110
with "use --lang flag to specify the typegen language". The working form is
`supabase gen types --local --lang swift --swift-access-control public`.
