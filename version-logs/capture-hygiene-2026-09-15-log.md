# Capture hygiene — 2026-09-15

Written for the next agent. Read this before touching
`Packages/KeepoCore/Sources/KeepoCore/AmountParser.swift`,
`MerchantNormalizer.swift` or `MerchantTokens.swift`.

Workstream 1 of the three agreed in `keepo-v1-master-plan.md` ("Shipping
order for the three open workstreams"). Pure `KeepoCore` string handling,
**no migration**, no schema or RPC change. Both defects were found by
probing the real Wallet automation on the user's own iPhone for the
onboarding redesign — neither would have been found by reading the code,
and both had been shipped since Phase 12.

---

## 1. `parseFormattedCurrency` was a live 100× money bug

It took its decimal separator from `Locale.current` and stripped everything
else. But **the Wallet `Amount` string is machine-formatted, not typed** —
nobody chose its convention on the device's behalf, so the device was the
wrong authority. Measured before the fix:

| device locale | input   | captured as |
| ------------- | ------- | ----------- |
| `en_US`       | `$1.06` | 1.06        |
| `es_ES`       | `$1.06` | **106**     |
| `es_ES`       | `1,06 €`| 1,06        |
| `en_US`       | `1,06 €`| **106**     |

**The function no longer takes a locale at all** — that parameter's removal
is the fix, not a side effect of it. The convention is read out of the
string:

1. Keep ASCII digits, `.` and `,`. Everything else is noise: the symbol or
   code, the sign (read separately, `-` and U+2212 both), and every grouping
   mark that is never a decimal point — the Swiss apostrophe in `1'234.56`,
   and the plain/no-break/narrow spaces France, Sweden and Hungary use.
2. Both `.` and `,` present → the **rightmost** is the decimal point.
3. One of them, more than once → grouping. Once, with **exactly three**
   digits behind it → grouping. Once, with one or two → decimal point.
4. Normalize to `.`, parse with `en_US_POSIX` through the existing
   `parse(_:locale:)`, so the e4 scaling and the half-away-from-zero
   rounding contract are unchanged.

**Rule 3's three-digit case is only a judgement call because the currency is
unknown.** It is safe because **no supported currency has 1 or 3 minor
digits** — every row in `currencies` is 0 or 2
(`20260804184433_init_schema.sql:76`). When the multi-currency workstream
lands symbol detection, this stops being a heuristic at all: with the
currency known it becomes a `currencies.minor_unit` lookup.

**`AmountParser.parse(_:locale:)` is deliberately untouched and still
locale-aware.** A person types what the decimalPad shows them; reading it
back any other way is the Phase 1 bug that type was created to fix. The
distinction to keep: **a typed amount and a formatted one have different
authorities.**

**Known, deliberate boundary:** non-Latin digit shapes (Arabic-Indic and the
rest) return `nil` rather than parsing to something wrong. The capture then
says "couldn't read the amount", which is a loud failure instead of a silent
wrong number. Revisit only if a real device produces one.

**Not done here, on purpose:** the symbol is still discarded. Detecting the
currency and acting on a mismatch is workstream 2, which is where the
`original_amount`/`original_currency` columns that give a detected currency
somewhere to live get added. Building the richer return type now would have
been a value with no consumer.

## 2. `MerchantNormalizer` split one shop into three learning keys

Real Square output is `SQ * Equity Park,Llc`. Every entry in
`corporateSuffixes` carried a **literal leading space** and matching was
plain `hasSuffix`, so the three spellings one shop emits produced three
`merchant_category_map` keys — `EQUITY PARK,LLC`, `EQUITY PARK`,
`EQUITY PARK,` — and a category learned under one never matched the next.
That is the exact thing normalization exists to prevent.

**The rule the fix turns on: punctuation *inside* a name is identity;
punctuation at a *boundary* is a separator.** Blanket stripping cannot tell
them apart, and both blanket options were measured and rejected before this
approach was adopted — removing the `*` stops the aggregator prefix matching
at all (`SQ` survives as noise in every result), replacing punctuation with
nothing glues the suffix on (`EQUITY PARKLLC`), and it collides distinct
payees (`M&S` with `MS`, `H&M` with `HM`) while *still* failing `AT&T`
against `AT AND T`. So the punctuation stays and the matchers became
boundary-aware:

- Suffixes match behind `[\s,]+` instead of a literal space. **This is the
  actual defect**: `,LLC` matches where `" LLC"` could not.
- Boundary characters are trimmed after **every** strip, not once at the
  end, so the next pass sees a clean edge.
- The aggregator prefix is one regex — `^(?:SQ|TST|SUMUP|…)\s*\*\s*` —
  replacing the `SQ *` / `SQ*` literal pairs and tolerating stray spacing.
- A fourth category the code did not have: **company forms that lead the
  name** (`PT`/`CV` in Indonesia) and CJK forms that sit on either side with
  no separator (`株式会社ローソン`, `ローソン株式会社`).

**Longest-first ordering is load-bearing**, and it is done at pattern
assembly rather than by hand-ordering the lists — so a list can be appended
to in any order without reopening the hazard. `LTD` ahead of `PTY LTD`
normalizes a Sydney café to `BONDI CAFE PTY`.

**Two-letter suffixes are the risk class.** A US card descriptor routinely
ends in a two-letter state code, so bare `AB` `AG` `AS` `NV` `KG` `OY` `SA`
`SL` `ME` are out — `ME` is both a Brazilian company form and Maine. They
are admitted only punctuated (`A.S.`, `B.V.`, `S.A.`, `A/S`), which no state
code imitates. **`CO` is the one deliberate exception, at the user's
instruction**, cost accepted and asserted in a test: `LUCKY CO` collapses
onto `LUCKY`. Bare `SPA` is excluded for the mirror-image reason — a nail
salon is not an Italian S.p.A.

Lists live in `MerchantTokens.swift` as reviewable data, scoped to the
countries behind the 31 supported currencies.

**Also fixed, quietly broken before:** the documented "never empty for
non-empty input" contract. `SQ *` used to normalize to `""`, which would
have been stored as a merchant key. It now falls back to its own cleaned
self, and that is a test.

**What this still does not fix, and is fine:** `AT&T` vs `AT AND T`,
`MCDONALDS` vs `MC DONALDS`, truncated descriptors, forms outside the list.
That is a fuzzy layer's remit if one is ever wanted — explicitly **not** the
mechanism, because several rows per shop is what normalization exists to
prevent.

---

## Consequences the next agent must know

**Both changes move `CaptureIdentity.externalId`.** It hashes the parsed
amount and the normalized merchant, so the same purchase now mints a
different id than it would have before this pass. That only matters for a
Shortcuts re-fire straddling the app update — a minute-bucketed window — so
it is accepted, not mitigated.

**`merchant_category_map` is a synced table** (`SyncApply.swift:56`).
Reinstalling the app clears only the local mirror; the next pull restores
the server rows. Changing normalization changes the key, so the reset is
`delete from merchant_category_map` against **hosted**, letting it re-learn.
No backfill was done — the user is still the only account.

**Carry forward: any post-launch change to normalization needs a real
backfill.** `merchant_raw` is retained precisely to make that possible.

**One implementation, one language.** `capture_transaction` takes
`p_merchant_normalized` as a *parameter* — the client computes it, the
server only stores it. There is no Postgres normalizer to keep in step, and
that is the reason this fix cost roughly a tenth of what the fuzzy-matching
design would have (which would have needed a Postgres implementation *and* a
SQLite one, refereed).

## Verification

`swift test` 213/213 (24 in the two rewritten suites, including a 24-case
suffix matrix across the supported currencies' countries and an explicit
idempotency test — which was a comment before and is now an assertion) ·
`xcodebuild -scheme Keepo build` clean · `swiftlint` 0 violations. No pgTAP
run: nothing in this pass touches SQL.

**Still owed: a real tap-to-pay purchase on device.** Both defects were only
visible against real Wallet output, and the exit gate deliberately batches
this with nothing else so one testing session covers both. Until that
happens, the evidence is unit tests over strings the user captured by hand,
not over strings iOS produced live.
