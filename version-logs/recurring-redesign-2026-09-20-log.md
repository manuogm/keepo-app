# Recurring transactions — redesign + recurring transfers — 2026-09-20

Written for the next agent. Two things at once, at the user's request:
rebuild the Recurring list and form on the transaction screens' design, and
add **Transfer** to the form's kind tab bar. The second needed a migration.

Migration `20260927100000_recurring_transfers.sql`, one new pgTAP file
(`43_…`, 18 assertions), no new Swift tests (nothing here is pure logic —
the new code is views, a GRDB read and a write-through).

---

## What it is

### The redesign

`RecurringRuleFormView` was still a `Form` with seven `Section` headers
("Account", "Category", "Amount", "Frequency", "Next due"…) — the exact
shape `TransactionFormView` was rebuilt away from months earlier. Its own
header comment claimed it "mirrors `AccountFormView`/`TransactionFormView`",
which had quietly stopped being true. `RecurringRulesView` was plain `List`
rows of text: no leading icon, no `PrivateText`, no base-currency line, and
an amount drawn **with** its minus sign while the identical transaction in
the ledger drops it (`MoneySignStyle.ledger`).

Both are now built from the real shared pieces, not lookalikes:

- `KindTabBar` — Expense / Income / **Transfer**, the same three words in
  the same order as the transaction form.
- `TransactionDetailContainer` + `CategorySuggestionRow` — composed
  **directly** rather than through `TransactionDetailCard`, because that
  component always draws a tag row and `recurring_rules` has no tags.
  Reaching for it and adding a `showsTags` flag would have been a
  configuration option one caller wanted.
- `TransferLegsView` — extracted from `TransactionDetailCard` during this
  work, because the rule form asks the same question (out of which account,
  into which, how much) and had no business answering it with its own
  layout. It takes an optional `destinationAccounts` for the one caller that
  needs a narrower list on one end.

**Where the two forms genuinely differ is time.** A transaction happened on
a day; a rule happens every so often, starting on a day. So the slot the
transaction form gives its date stepper holds a **frequency track** with the
stepper under it, and the stepper's chevrons move **one period, not one
day** — for a rule, "the next one" is a month away, not a Tuesday away.
The track reuses `WidgetSegment` (the selected-state treatment is the thing
that must never drift between these controls); the track chrome around it is
written out locally, as the second neutral instance of it, which is where
CLAUDE.md still permits duplication.

**Kind stays editable in edit mode**, unlike the transaction form's. There
it is locked because changing it is delete-and-recreate at the schema level;
here it is the sign of `amount_e4` plus which target column is set, and
`RecurringRuleRepository.update` writes both — so switching an expense rule
into a transfer is an ordinary edit.

### Recurring transfers

`recurring_rules` held one `account_id`/`category_id` pair, so
`app-architecture.md` recorded that recurring transfers were out of scope
and the transaction form hid "Make recurring" for the transfer kind. The
migration widens the table to two shapes:

| Shape | `category_id` | `to_account_id` |
|---|---|---|
| expense / income | set | null |
| transfer | null | set |

`recurring_rules_shape_check` states it. `materialize_recurring` mints a
**pair** for a transfer rule, sharing one `transfer_group_id`, so the ledger
folds it into one row exactly like a hand-entered transfer.

---

## The three things most worth knowing

### 1. Each leg needs its own `external_id`

Idempotency is the partial unique index on
`(owner_id, source, external_id)` plus `on conflict do nothing`. A single
`external_id` shared by both legs would let the **second insert be swallowed
by the first's conflict** and leave a transfer with one side — a phantom
expense shrinking net worth every month, forever, with no error anywhere.
The suffixes (`…|from`, `…|to`) are what make the pair safe.

`found` after `insert ... on conflict do nothing` reports whether the *last
statement* touched a row, so the two-leg branch counts its legs separately.

### 2. Two restrictions, both from "a rule fires unattended"

- **Same owner, both legs.** `to_account_id` carries the composite FK to
  `(id, owner_id)` that `account_id` and `category_id` already carry.
  Materialization stamps `recurring_rule_id` on **both** legs, and
  `transactions_recurring_rule_owner_fk` is itself composite — so a
  destination leg owned by someone else could not point back at the rule
  that created it. The alternative (leaving that leg unstamped) would make
  the ledger's recurring glyph and "edit all future occurrences" work from
  one leg and not the other.
- **Same currency, both legs.** Enforced in
  `validate_recurring_rule_sign`, which needs to read two accounts (hence a
  trigger, not a CHECK). A cross-currency transfer needs a destination
  amount and **there is no honest value to store**: money rule 6 permits a
  stored conversion precisely *because* a user is present to correct it with
  what their bank actually charged, and nobody is present at 2am. Converting
  at materialization time would leave the cron deciding what to do when no
  rate resolves, which money rule 5 answers with `—` — not something a row
  can hold.

The form filters the destination picker to what the server will actually
accept and prints one grey line saying why, but **only when something was
actually hidden** (`hasHiddenDestinations`). The transaction form's
"Make recurring" pill is hidden for a transfer failing either test — that
line has room for a label, not an explanation.

### 3. `RecurringRuleRepository` never had a local write-through

This is the one that will bite again elsewhere. The repository writes
straight to PostgREST — deliberately, it is not an outbox path — while
`RecurringRulesView` reads the **local GRDB mirror**, and
`RefreshCoordinator.bump()` only invalidates screens; **it does not pull**.
So a rule created, edited or paused was invisible until the next sync pull
happened to land. That has been true since Phase 14; the new per-row switch
is what made it unmissable, springing back under the finger while the server
quietly held the new value.

`RecurringRuleLocalWrite` closes it, following `AccountLocalWrite.delete`'s
precedent: server write, then mirror write, then bump.

**If you add a screen that reads the mirror and writes through a plain
repository, check this.** The pattern is silent when the pull happens to be
quick and infuriating when it is not.

---

## Defects found while building, none by inspection

1. **The amount prefilled signed.** `apply(_:)` wrote `amountText` from the
   signed column, so editing an expense showed `-45.00` under a tab already
   saying Expense — the minus said twice, and `AmountField` renders one
   specially, in front of the currency symbol. It round-tripped correctly
   (`save` takes `abs`), so nothing was ever wrong in the database.
2. **The generated Update type cannot clear a column.** Swift's synthesized
   `Encodable` uses `encodeIfPresent`, so a nil field is **omitted**, not
   sent as JSON null. Changing a rule's shape has to clear the other shape's
   column, so `update` hand-encodes its patch (`RecurringRuleShapePatch`) —
   the same fix and the same reason as `ProfileRepository`'s
   onboarding-reset patch. `setActive` keeps relying on the omit behaviour,
   deliberately, so its patch carries `active` alone.
3. **`adoptContext()` no-opped on first appear.** It is a `.task(id:)`
   observer guarded on `!isLoading`, and for a fresh Expense with no account
   chosen the key never changes afterwards — so the form opened with no
   category selected and a row showing nothing but "More". `load()` calls it
   explicitly now, which is what `TransactionFormView.load` already did and
   says why.

---

## A wrong diagnosis, recorded because the reasoning was plausible

The row's switch appeared completely dead in the Simulator: no write, no
network request, not even the edit sheet the label beside it would have
opened. I attributed it to `List` making a row's `Button` claim the whole
cell — which is a **real** SwiftUI behaviour, and is exactly why
`ArchiveAccountsView` puts `.buttonStyle(.borderless)` on each of its two
buttons — and moved the screen off `List`.

The actual cause was the test harness: **a zero-duration injected tap is too
short for `UISwitch`**. A 0.15s tap worked immediately, on both versions.

The move off `List` was kept, on its own merits — the screen has no list
affordance left, since a rule cannot be deleted and pause/resume both live
on the switch — but the comment asserting the false cause was corrected
rather than left standing. Two lessons: **verify a UI diagnosis by changing
one thing**, and **an injected tap is not a finger**.

---

## Layout note: the row is over-subscribed, and the conversion yields

The list row has four columns where `TransactionRow` has three — the switch
costs about 60pt the ledger never spends. Two attempts failed on the
foreign-currency row, which is the only one carrying a conversion at all:
`layoutPriority` on the schedule wrapped the conversion to "$536.6 / 6" and
made the row taller than its neighbour; making the conversion
incompressible truncated the schedule to "Euro Pot · Monthly · Sep…".

The fix is structural plus a `ViewThatFits`. The row pairs **across** (title
with amount, detail with conversion) rather than as two stacked columns,
which gives the detail line the whole label width minus one short figure;
and where even that is not enough, the conversion — the only thing on the
row that is a *restatement* rather than a fact — is dropped whole rather
than either of them shrinking.

---

## Not done / still owed

- ~~Not deployed.~~ **Deployed 2026-09-21.** Hosted was current through `20260926100000`; this was the only pending migration. Post-push `supabase db diff --linked --schema public` shows no `recurring_rules` drift (only Supabase's own `pg_net` / `ensure_rls` / sequence-privilege objects, which are on every hosted project and in no migration).

  **The deploy gate caught a real defect in this migration**, after everything above was already green: `fork_one_account` was restated from `20260909100000`'s body, one revision stale, and `20260914100000` had since fixed its household lookup — so the push would have silently reverted that fix, with 531 tests still passing, because nothing exercises a user in two households. Rebased onto the live body with only the recurring insert changed. **Before restating any function, `grep -l` it across `supabase/migrations/` and take the last hit.**
- ~~Pre-existing, noticed here, not fixed: UTC-midnight materialization.~~
  **Fixed the next day** by `20260928100000_recurring_lands_on_the_users_own_day.sql`
  — `profiles.time_zone` plus materialization at the owner's local midnight,
  and `realign_recurring_occurrences()` for rows already stored. The wider
  question it named ("what does a `date` mean in the user's zone") turned out
  to have only one answer that does not break somebody: ask the user, because
  real offsets span twenty-six hours and no fixed instant is the right
  calendar date everywhere. See that migration's header and
  `lessons-learned.md`.
- **`upcoming_transactions` excludes transfer rules**, and now says so
  explicitly rather than relying on an inner join to do it by accident. That
  query projects one row per rule — the outflow — while a transfer's pair
  nets to zero, so including them would have made the Next-2-Weeks headline
  read as money leaving that never left. Showing them there needs **both
  legs**, which is a change to that query's shape, not a filter.
- **A recurring transfer between two household members' accounts** is
  refused by design (see restriction 1). If that is ever wanted, it is a
  different feature — a standing settlement — and it needs
  `transactions_recurring_rule_owner_fk` reconsidered first.

---

## Verification

531 pgTAP (18 new), 302 `swift test`, `KeepoTests` + `KeepoUITests` green,
`xcodebuild` clean, `swiftlint` 0 violations, codegen re-run
(`--swift-access-control public`).

Walked end to end in the Simulator against the local stack: create an
expense rule, create a transfer rule, edit one, pause and resume from the
row switch, `materialize_recurring`, and the resulting pair folding into one
`Transfer / Current → Savings` row in the ledger with the recurring glyph.
Both "Make recurring" branches checked — offered for a same-currency
transfer, withheld for a cross-currency one.

---

## Follow-ups, same workstream (2026-09-21)

Three further migrations, all deployed:

- **`20260928100000`** — an occurrence is stored at the owner's **local
  midnight**, not UTC midnight. `profiles.time_zone` (IANA, trigger-validated,
  defaulting to UTC) plus `realign_recurring_occurrences()` for rows already
  written. No fixed UTC time-of-day could work: offsets span 26 hours, so the
  obvious "shift to noon UTC" fixes the Americas and breaks New Zealand.
- **`20260929100000`** — due-ness decided in the owner's calendar (cron now
  **hourly**), a rule on an archived account goes **dormant** rather than
  minting invisibly forever, a rule's currency must match its account, and
  deleting a category re-points its rules instead of orphaning them.
- **`20260930100000`** — rules carry **tags and a note**, both copied onto
  every occurrence; a transfer is tagged on its outflow leg only.

Read `lessons-learned.md`'s 2026-09-21 section before touching any of this.
The two that will bite again: **"today" is a per-user question** (three of
four client call sites had it wrong, and none of it is reachable from a
machine set to UTC), and **a feature that hides a row must also stop it** —
archival and category deletion both hid a rule while the materializer kept
writing from it.

