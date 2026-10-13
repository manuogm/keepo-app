# Resent writes, plain-English refusals, Sync Conflict redesign — 2026-10-13

Written for the next agent. Started from a real bug on Manu's phone and grew
into a rework of how conflicts are recorded and shown. Two migrations, both
**pushed to hosted 2026-10-13** before their client commits:
`20261017100000_a_change_sent_twice_is_saved_once.sql` (commit `8329ec0`) and
`20261018100000_a_conflict_asks_only_when_there_is_a_choice.sql` (commit
`d9f1285`). `main` == `dev` after each.

---

## A — "Couldn't Save a Change … not a pending capture — use update_transaction"

An Apple Pay capture was confirmed, and the next launch raised that sentence over
the splash.

- **Cause:** the outbox resends any write whose attempt ended without an
  answer, and that attempt can have landed. `review_capture_transaction`
  refused the resend ("not a pending capture"), the outbox treated the P0001
  as a final refusal, and `UserFacingError` showed it verbatim.
- **Trigger:** notification quick actions returned before the delivery `Task`
  finished, so iOS could suspend mid-request. `CaptureQuickActionHandler` now
  awaits `.value`.
- **Server (`20261017…`):** every version-checked transaction write answers its
  own resend with success. `transaction_already_matches(id, attempted jsonb)`
  compares only the keys the attempt names, and is checked before raising or
  logging a conflict. Covers `update/review/confirm/delete_transaction` and
  `update/delete_transfer`. A delete of an already-deleted row succeeds.
  `review_capture_transaction` now reviews a confirmed capture as an ordinary
  edit.
- **Developer guards** ("use update_transfer") raise `22023`, not P0001: final,
  but never shown. A missing transfer says so in words, without its id.
- **Refusal alert:** `OutboxRefusal.reason` is the server's sentence only when
  it is meant for a person (`UserFacingError.genericMessage` otherwise). The
  copy no longer mentions "server".
- Tests: `supabase/tests/59_…`, `OutboxRefusalTests`, `UserFacingErrorTests`.

## B — Conflicts that offered no choice

Every case was reproduced end to end: proved on the local DB, then each sheet
opened in the Simulator. All 5 conflicts ever on hosted were account conflicts
whose account was deleted seconds later.

- **Root cause of those 5:** `set_account_balance` touched
  `accounts.updated_at`, which fired `bump_version`. The phone's write-through
  does not bump, so the phone sat one version behind and its next account
  action conflicted with its own save. The touch is removed; a balance save
  leaves the account's version alone. `21_set_account_balance.sql` was
  rewritten for that.
- **Deleted rows close their conflicts:** an AFTER UPDATE OF `deleted_at`
  trigger on `transactions`/`accounts` (`close_conflicts_of_deleted_row`),
  plus a backfill.
- **Account conflicts keep `attempted_payload`** via `record_account_conflict`,
  for `update_account`, `archive_account`, `set_account_kind`, `delete_account`
  and `set_account_balance`. A write that asks for what is already saved is
  success. `AttemptedAccountWrite.replay` redoes the real change; before, "Keep
  mine" re-sent only the archived flag.
- **Inbox row:** "Sync Conflict / <name> · Choose which version to keep", via
  `sync_conflict_subject`, which the local `needsReviewSyncConflicts` mirrors.
  The swipe action is "Keep Saved".
- Tests: `supabase/tests/60_…`, `KeepoTests/ConflictComparisonTests`.

## C — Sync Conflict sheet (iterated with Manu four times)

`ConflictComparison` builds both sides from the local mirror after a pull.
"Mine" comes from `attempted_payload` via `LocalTransactionRow.preview`
(account/category names, currency and FX by the ledger's own `build`) and
`LocalAccountRow.changing`, never from the device's row, which the pull has
already replaced.

The final design, as approved:
- **Title and header:** the title is "Sync Conflict". The header reads "<Transaction|Transfer|Account> was changed in
  two places", followed by "Choose which version you want to keep. The other one will be
  discarded."
- **"Your change" card:** the *saved* tile (`TransactionRow` / `AccountRowView`)
  with `edits: [Part: String?]`. Each changed value is struck through in
  `statusNegative`, with the requested value after it in `brandPrimary`
  semibold. Amounts stack: new on top, old struck below.
- **Date:** never struck. Each card shows its own date under the tile, teal on
  "Your change" when it differs. The date still counts as a difference: a
  date-only conflict is real, e.g. both sides re-dated, or the other side
  changed tags.
- **Other values the tile can't show** (note, amount paid, archived, counts in
  totals, icon) each get a labelled line, drawn the same struck/new way.
- **Delete:** the tile is faded (`Opacity.muted`), not struck, with a red
  "Deleted on this iPhone" below it. Manu preferred this over strikethrough.
- **Saved card:** plain tile with a `brandPrimary` border
  (`AppTheme.Stroke.emphasis`, a new token).
- **Both cards** show exact figures (`showsExactAmount` /
  `showsExactBalance`).
- **Buttons:** one pair everywhere, `PrimaryActionButton` "Keep Saved Version"
  and `SecondaryActionButton` "Use My Change". `.borderedProminent` drew white
  on white in dark mode. Errors go to `.errorAlert`.
- **Rejected along the way:** a field list under each card (repeats the tile),
  and teal highlights plus chips inside the tile (changes not identifiable
  enough).

## How to reproduce conflicts on the local stack

The app signs in as `dev@keepo.local` (StubAuthProvider). Seed rows for that
user as postgres, relaunch the app so it syncs, then for each case call the RPC
twice as the user (`set local role authenticated` + `request.jwt.claim.sub`):
- first with the current version, playing "elsewhere";
- then with the old version, playing "this phone".

Relaunch the app and the conflicts arrive in Needs Review.

## Open / next

- Ship a TestFlight build: the sheet, the plain refusal copy and the
  quick-action await are client-side. The server half is live.
- "transaction not found or not accessible" and similar P0001 sentences are
  still terse. Manu has been offered a full audit of user-visible messages; not
  started.
