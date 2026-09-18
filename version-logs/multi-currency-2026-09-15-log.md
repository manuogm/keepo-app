# Multi-currency transactions — 2026-09-15

Written for the next agent. Read `CLAUDE.md` money rule 6 **first** — it was
amended for this work and the amendment is the whole design.

Workstream 2 of the three in `keepo-v1-master-plan.md`. Migration
`20260923100000_transaction_original_currency.sql`, one new pgTAP file
(`39_…`, 31 assertions), and its mirror image in `KeepoTests`
(`CaptureCurrencyLocalWriteTests`, same cases, same numbers).

---

## What it is

A purchase made in a currency other than its account's. Two real cases,
neither expressible before: entering a euro purchase on a dollar account
while travelling, and Wallet reporting `€50.00` on a card mapped to a USD
account — which the pipeline silently recorded as **$50**.

`transactions` gains `original_amount_e4` + `original_currency`. The
account-currency figure stays in `amount_e4`, because
`balance = opening_balance + SUM(amount)` requires every row to be in its
account's currency. The pair is **provenance only: never summed, never
re-converted, never a balance.**

## The one invariant to hold on to

> `account_id`/`currency` are set only when `amount_e4` is genuinely in that
> account's currency.

`account_currency_together` already said "both or neither"; this says *why*,
and it is what makes the whole design fall out. **An unknown card and an
unresolvable rate are the same problem** — no amount can be expressed in an
account's currency yet — so both land the same way: `account_id` and
`currency` null, the original recorded, the review form supplying the rest.
Neither is allowed to invent a figure.

## The property that makes storing a conversion honest

The converted figure is **prefilled and always editable**. Keepo's ECB rate
is not the rate the bank used — Visa, Amex and Revolut each add a spread —
and the balance is a running sum, so a silently stored reference conversion
would drift the account away from reality permanently with a number that was
never true. **Everything else follows from this:**

- `capture_transaction` is the **only** thing that converts, because it is
  the only point where no human has seen the number yet.
- `review_capture_transaction` and `update_transaction` **store what they
  are given and never recompute**. The pgTAP proves it with a figure
  (`$58.00`) that `fx_convert` would never produce for €50.
- `link_card_to_account` was deliberately **not** changed to resolve held
  captures when a card is mapped from the Needs Review sheet. It looks like
  an obvious convenience and it is the one thing that would break this
  property: that sheet shows no amount, so it would commit an ECB-rate
  conversion the user never saw. Held captures resolve in the review form,
  where the number is on screen.

## capture_transaction's five arms

Nothing detected, or detected == the account's → **unchanged**, originals
null. This is the regression guard for every ordinary capture.
Detected ≠ the account's, rate resolves → convert at
**`fx_rate_on(occurred_at)`, never today's**, keep the original.
Rate does not resolve, or the card is unmapped → **hold**: account and
currency null, original recorded.
A currency not in `currencies` → treated as none detected. The server
re-checks rather than trusting the client's detector, and so does
`CaptureLocalWrite`.

## The half that is easy to miss

**`sync-fx-rates` had to change too, and without it the feature does not
work at all.** Currencies-in-use was `accounts.currency ∪
profiles.base_currency` — and a currency you are *travelling* in is by
definition one you hold no account in. So a euro-account user paying in baht
had no THB rate and never would have: **the missing-rate case is the common
case for exactly the user this exists for.** Two halves, both required:

1. `trigger_fx_backfill_on_new_original_currency` on `transactions` — same
   shape as the existing `accounts` trigger, because "a currency newly in
   use needs rates" is a property of the data, not of one RPC.
2. `currenciesInUse` in the edge function now unions
   `transactions.original_currency`.

So a held capture usually has its rate by the time the user opens the
review. If it still does not, the form shows `—` and asks (money rule 5).

## Currency detection carries no symbol table

`CurrencyDetector` inverts **Foundation's own** symbol table over the
supported set, so a symbol resolves only when exactly one supported currency
could have produced it. The ambiguity rule is therefore **derived, not
asserted** — and the honest answer changes by device:

- British, German, Spanish phone: `$` is unambiguously USD (they write
  `CA$`, `A$`, `MX$`).
- Australian, Canadian, Singaporean, Kiwi, Mexican phone: `$` is the local
  dollar **and** could be a US one → resolves to nothing, falls back to
  today's behaviour.
- `¥` is JPY nearly everywhere and CNY on a Chinese phone → nothing there.

The device's table is unioned with `en_US`'s because the string was not
necessarily formatted by this device, and **a disagreement between the two
is itself a reason not to act**. All of this is measured in
`CurrencyDetectorTests`, not assumed.

## The form (the user chose this shape)

One big field with a **currency chip** on it, defaulting to the account's
currency — so an ordinary entry looks exactly as it always has. Pick another
currency and a smaller labelled field appears beneath: *"Charged to A
Dollars"*, prefilled from the rate, **editable**, with the rate's date
beside it. Same mental model on all three surfaces: **big = what was paid,
small = what the account was charged.**

- **`chargedAmountEdited` is load-bearing.** It is set the moment the user
  types in the charge *and by the edit-mode prefill*. Without the second,
  reopening a foreign transaction would quietly swap the bank's real charge
  for Keepo's estimate every time the sheet opened — the exact drift rule 6
  exists to prevent. A *held* capture has no charge to protect and is left
  to derive.
- "The user typed this" is detected by the **`Binding`'s setter**, not
  `onChange`: a setter runs only when the control writes, while `onChange`
  cannot tell your own assignment from a keystroke.
- The preview converts through `LocalMoneyConversion` — the SQLite port of
  `fx_convert` the referee test holds byte-exact — **not** through an RPC as
  the plan originally said. An RPC would have made offline entry impossible,
  and money rule 3 is satisfied either way: the arithmetic is in SQL, in the
  one refereed implementation.

## Deviations from the plan, recorded rather than silent

1. **Two functions, not one returning a tuple.** `parseFormattedCurrency`
   stayed amount-only (shipped in workstream 1) and `CurrencyDetector` is
   separate. Same seam built once; no tuple-returning API.
2. **Preview via `LocalMoneyConversion`, not an RPC** — see above.
3. **The paid field is editable on a capture**, where the plan said
   read-only. Wallet is a report, not an authority, and a wrong detection
   has to be recoverable; one less mode, too.
4. **`link_card_to_account` unchanged** — see the honesty argument above.

## Two near-misses worth knowing about

**I almost restated both views from the wrong ancestor.** The copies in
`20260815100000` are *older* than the live ones: that
`transactions_with_details` INNER JOINs `accounts` — which would have hidden
every unresolved capture, including the ones this migration creates — and
omits `notes`; that `needs_review` still carries the deleted CSV branch and
none of `ambiguous_card`'s guards. **Find the authoritative definition by
sorting every migration that defines it and taking the last, every time.**

**A second `CurrencyPickerSheet` already existed.** The app had a searchable
list (account form) and a wheel (`BaseCurrencySheet`, My Profile) with
directly contradictory rationales in their own doc comments. Renaming the
wheel collided with the list; the fix was to revert and reuse the list,
which is the better fit here anyway — you know the code you paid in, so you
type it. **Grep for the type name before introducing one.**

## Verification

`supabase test db` 496/496 (31 new, no regressions) · `swift test` 223/223
(10 new, `CurrencyDetectorTests`) · `xcodebuild test -only-testing:KeepoTests`
171/171 (7 new) · build clean · `swiftlint --strict` 0 violations.

**Deployed 2026-09-16.** `supabase db push` applied `20260923100000` and
nothing else — hosted was already current through `20260922100000`, verified
with `migration list` both before and after. `supabase functions deploy
sync-fx-rates` went with it: **that half is not optional**, since without the
widened currencies-in-use query no travel currency ever gets a rate. The
migration is backward compatible with the build already on the phone — every
new RPC parameter carries `default null`, so PostgREST still resolves that
client's named-argument calls, and the two new columns are dropped by its
`SyncApply` whitelist.

**One hosted dependency to confirm on the first foreign capture:** the
backfill goes through `request_fx_backfill` → `ops_http_post`, which reads
`fx_sync_url` and `fx_sync_secret` from the vault and, if either is missing,
**writes an `ops_events` row and returns silently** (deliberately — a capture
must never fail because a rate fetch could not be dispatched). So a first
purchase in a brand-new currency that never gets a rate means those secrets,
not this code: look for `code = 'missing_vault_secret'` in `ops_events`.

**Still not done:**

- **A real foreign tap-to-pay purchase.** The Debug "Simulate Capture"
  screen now runs detection on whatever is typed, so `€50,00` there
  exercises detection → conversion → the two-amount form without needing a
  foreign card in Wallet.

## Amended 2026-09-18 — the notification was never converted with the row

This workstream got `capture_transaction`, `CaptureLocalWrite` and the form
right and then handed the **notification** the wrong pair, which nothing
caught because no test in either suite built a resolution whose currency
differed from the currency its amount was in. Two defects, both shipped
here, both fixed on 2026-09-18:

- `Resolution` carried a single collapsed `currency` — "the currency
  `amount_e4` is in", which was the account's after a conversion — while
  `CaptureIntent` handed `CaptureNotificationCopy` the *paid* figure as a
  separate argument. A $1,234.56 purchase on a EUR account announced itself
  as **"€1,234.56"**. The fix is the seam, not the arithmetic: `Resolution`
  now carries `paidAmountE4`/`paidCurrency` and
  `chargedAmountE4`/`accountCurrency` as separate fields, and the copy
  takes **no amount parameter at all**, so no caller can pair them wrongly
  again. The notification leads with what was paid; the account figure
  follows in the body.
- An unmapped card in a currency `CurrencyDetector` refuses to name has
  neither an account currency nor a detected one, and rendered a bare
  `1,234.56`. `CurrencyDetector.symbol(in:)` now echoes the mark Wallet
  printed, **verbatim and mapped to nothing** — the distinction that makes
  it safe where `detect` is not is that showing the input back has no wrong
  answer, while acting on it does. Display only; it reaches no payload, no
  column, and no `fx_convert` call.

**The lesson for the next agent:** a currency conversion has *two* figures,
and every surface that shows money after one has to say which of the two it
is showing. Grep for call sites that take an amount and a currency as
separate arguments — that shape is the bug.
