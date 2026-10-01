# Transfers & household sharing — history choice, fork rewrite — 2026-09-23/24

Written for the next agent. The decision record is the "Transfers & household
sharing" section of `keepo-v1-master-plan.md` (findings, agreed design, each
phase "as built", the review). This log is the short version plus what to
check before shipping.

**Status: done and deployed, 2026-09-24.** Committed on `dev` and pushed.
Migrations `20261006100000`–`20261016100000` were pushed to hosted with the
user's approval, all eleven at once from `20261005100000`, before any
TestFlight build of this client (it calls `share_full_history`,
`create_invite`/`accept_invite` with a third array, and decodes
`preview_invite.full_history`). Before the push, a scan found no scheduled
job, client call or edge function using anything the migrations drop. After
it, `supabase db diff --linked --schema public` shows only Supabase's own
platform objects (`pg_net`, `ensure_rls`, sequence permissions).

---

## What changed

**Transfer findings (#1–#16 + outbox).** Client-supplied transfer group ids;
`update_transfer` takes accounts; a deleted account's transfer halves stay as
anchors; the local transfer write-through resolves halves by sign; the form
loads both halves itself; the outbox treats a deterministic refusal as final
(dequeue, restore from the server, pop-up); "Keep mine" replays
`sync_conflicts.attempted_payload` for any kind.

**Sharing from a date.** `household_accounts.history_from` (null = full
history). One boundary (`transaction_shared_into` / `transaction_visible_to`)
behind RLS, derived visibility, every write and the fork. The partner gets
the same balance formula over an adjusted opening from `pull_changes`
(`account_opening_as_seen`), re-stamped when a row before the start moves; the
phone purges someone else's rows before a start after every pull.
"Include past transactions" is off by default, set per account at setup and
when sharing later; `share_full_history` widens, nothing narrows.

**Fork rewrite.** The owner keeps the original untouched; only the member
losing access gets a copy of what they could see (`fork_accounts`), with
tags, notes, titles, originals, paused rules and transfer pairs rebuilt per
person. `accounts.copied_from` records provenance; sharing an account again
retires the partner's old copy (user's decision). `net_worth_daily` and its
two functions are gone.

**Guards (user's decisions).** The owner cannot move a shared row out of the
household's view (option B, a trigger). A partner cannot date anything before
the start; a cross-member transfer needs both halves in view.

**After the two-device review.**
- The share switch is the owner's only.
- Five texts updated for the new fork.
- The back-a-day arrow dims at the limit.
- **Pre-existing, fixed:** a partner could not log a transaction on the owner's account, because the app sent the partner as owner.
  - The row is now the owner's (`CreateTransactionPayload.createdBy`).
  - The picker offers shared categories plus Other only (`AccountCategories`, user's decision).
  - `owners_category` (20261015100000) swaps them for the owner's counterpart on `transactions` and `recurring_rules`.
- **Pre-existing, fixed at the user's request:** a household emptied by a leave, discard or erase stayed open, with its pending invites still valid.
  - A trigger on `household_members` now closes it and revokes the invites (20261016100000).
- **The Household summary's counts, fixed at the user's request** (client only). The phones showed 4/2/0 and 4/1/2 against a true 2/1/0.
  - The account and category badges counted the viewer's unshared rows too, because the "Nothing here." check shared their number. `HouseholdDisclosure(hasRows:)` separates the two.
  - Tags: "All tags" became "Shared tags", read by `LocalTableQueries.householdTags` (the second half of `can_read_tag`), so both phones get the same set. The report's tag headline uses it too; its prune list keeps every tag.

## Migrations (all local)

| Migration | What |
|---|---|
| 20261006100000 | a transfer is found where the phone left it (client group id) |
| 20261007100000 | deleting an account keeps its transfers whole |
| 20261008100000 | a conflict remembers what was attempted |
| 20261009100000 | a share can begin on a date (Phase 1) |
| 20261010100000 | a partner is handed what they can see (Phase 2) |
| 20261011100000 | a shared transaction stays where the household sees it (option B) |
| 20261012100000 | the owner keeps the account (Phase 3, fork) |
| 20261013100000 | the owner chooses how much history to share (Phase 4) |
| 20261014100000 | sharing again replaces the old copy |
| 20261015100000 | a partner files under the owner's categories |
| 20261016100000 | a household closes when its last member goes (and its pending invites are revoked) |

## Verification

- pgTAP 799 in 54 files (new: 51–58), KeepoCore 377, KeepoTests 275, `swiftlint --strict` clean.
- Two Simulators on the local stack (dev users A and B): all seven review steps, then each fix re-checked on screen and in both phones' `Local.sqlite`.

## Open items carried forward

- The transaction form's account menu can show two accounts with the same name (the user's and the partner's).
- KeepoCore's unused `fetchSharedAccountIds` still reads ended shares.
- Test data left in the local database from the review: Travel Fund, Wallet, Lunch, Market, the $50 transfer, and the copies from the first leave. The household has been re-formed with Checking and Savings shared from today, and Groceries shared. B's Savings carries two tag links added for the summary check: "Holiday" after the start (shared) and "Rent" before it (not).
