# Keepo — Security Remediation Plan

**Date:** 2026-08-18 · **Scope:** Supabase Advisor findings (1 ERROR, 24 WARN, 3 INFO), cross-checked against the live app's data flow
**Status:** Waves 1–4 executed, verified locally, pushed to the hosted project, and re-verified directly against it. Wave 5 (dashboard auth settings) is still outstanding — that one is yours. See §12 and §13.

---

## 12. Execution record

Waves 1–4 are written as three migrations and one test-file edit, applied in order against the local stack and verified after each one — not just read back, actually run:

| File | Closes |
|---|---|
| `supabase/migrations/20260830100000_close_fork_and_view_holes.sql` | Wave 1 — `fork_one_account` revoke, `accounts_with_balances` `security_invoker` |
| `supabase/migrations/20260830110000_p1_authz_hardening.sql` | Wave 2 — `fork_one_account` ownership guard, `restamp_account_for_sync`/`next_ticket`/`sync_domain_id` revokes, `resolve_category_for_merchant` guard |
| `supabase/migrations/20260830120000_p2_hardening.sql` | Wave 3 — 21 PUBLIC-executable functions locked down, 7 `search_path` pins |
| `supabase/tests/01_grants_rls.sql` | Wave 4 — two new schema-wide assertions (§7), now 9 total |

**What verification actually means here** — every one of these was executed, not inspected:

- Both proven exploits (§2.1 `fork_one_account`, and the definer-view mechanism behind §2.2) were re-run **after** the fix and confirmed to fail: `permission denied for function fork_one_account`, and `accounts_with_balances` now the sole zero-row result in the "which views bypass RLS" query.
- Every legitimate call path that touches a changed function was exercised end-to-end as the actual calling role, not just read: `unshare_account` (real fork, real archive), the household CSV-import cross-owner case that a first draft of the `resolve_category_for_merchant` guard would have silently broken, an ordinary account write (exercises `bump_version`/`set_updated_at`/`stamp_sync_seq_account`/`next_ticket`/`sync_domain_id` in one insert), `update_account`, category rename, `normalize_budget_period_month`'s date truncation, and `enforce_household_member_cap` rejecting a third member.
- `supabase db reset` was run from a clean slate — all 47 migrations apply in order with no errors — followed by `supabase test db`: **all 23 test files, 317 tests, pass**, including the two new invariants.

This record originally stopped here, deliberately short of the hosted project — pushing was a separate, explicit step. It has since been taken and re-verified directly against hosted; see §13.

---

## 0. How to read this document

Every finding below has four parts:

- **What it is** — in plain language, no jargon.
- **Why it's a problem** — with a concrete example of what someone could actually do.
- **The fix** — the specific change.
- **Why it won't break the app** — the call sites I checked to prove the fix is safe.

That last part matters most. A security fix that breaks sync or capture is worse than the hole
it closed, so every proposed change below was traced to every caller before it was written down.
Where a fix *would* have broken something, I changed the fix — that happened once, in §3.4, where
the obvious lockdown would have broken CSV import.

Two claims in my first draft were also wrong, and testing rather than re-reading is what caught
them. Both corrections are marked in place: §2.2 is **less** severe than I first said, and §2.1 is
**more**. Nothing in this document rests on reasoning I didn't check.

---

## 1. Summary

The Supabase Advisor reported 1 ERROR and 24 WARNINGs. After reading the schema **and testing the
findings against a running database**, they collapse into **one confirmed, unauthenticated,
exploitable hole, one latent defect that is currently contained by luck, four moderate issues, and
about twenty items that are cosmetic or outright false positives.**

Everything in §2 below was **executed against the local database**, not reasoned about. That
changed two conclusions I had drawn from reading the code alone — one for the worse, one for the
better. Both corrections are stated plainly where they occur.

| Priority | Count | What it means |
|---|---|---|
| **P0 — Critical, proven** | 1 | `fork_one_account`: anyone, not even logged in, can steal an account. |
| **P0 — Latent** | 1 | `accounts_with_balances`: not leaking today, one edit away from leaking. |
| **P1 — Moderate** | 4 | Cross-user tampering / information disclosure. |
| **P2 — Hardening** | ~20 | Locks on doors already inside a locked building. |
| **P3 — Not a bug** | 3 | Advisor is wrong. Document, don't "fix". |

The schema is, on the whole, carefully built: every table has RLS, every table has explicit grants,
every `SECURITY DEFINER` function pins `search_path`, and the recent audit wave
(`20260827100000`, `20260828100000`) closed the direct-write and rate-limit gaps properly. These
are two specific slips, not systemic rot.

---

## 2. P0 — The critical findings

> **Everything in this section was verified by running it.** Where my first read of the code was
> wrong, the test is what caught it — which is the whole argument for §7.

### 2.1 `fork_one_account` — CONFIRMED: a stranger can steal an account

**Where:** `supabase/migrations/20260819100000_remove_fi_add_account_appearance.sql:250`

**What it is.** When two people share a household and one leaves, Keepo splits the shared account
in two — one copy each, with the full history. `fork_one_account` does that splitting.

It's a **helper**. It was written to be called only by `leave_household` and `unshare_account`,
which *do* verify who you are. The helper skips those checks itself, trusting its callers.

Two things go wrong. First, Supabase automatically publishes every function in the `public` schema
as a web address — so the helper is reachable directly at `/rest/v1/rpc/fork_one_account`, without
going through the callers that do the checking. Second, Postgres grants "anybody may run this" to
every new function **by default**; you have to explicitly take it away, and this function never
did. So the door is open to the entire internet.

**Why it's a problem.** It accepts any account ID and any two user IDs:

```sql
fork_one_account(p_old_account_id uuid, p_member_a uuid, p_member_b uuid)
```

and then copies the account, **every transaction on it**, every balance snapshot and recurring
rule into new accounts owned by whoever you named — then **archives the original**.

**This is not theoretical. I ran it.** I created a user "Alice" with a checking account holding one
transaction (merchant: `THERAPIST`, −45.00), then dropped to the `anon` role — *not signed in at
all*, no password, no account, no token beyond the public API key that ships inside the app — and
called the function. Result:

```
     name     | owned_by_mallory | archived | merchant_raw | amount_e4
--------------+------------------+----------+--------------+-----------
 ALICE SALARY | f                | t        | THERAPIST    |    -45000   ← Alice's, now archived
 ALICE SALARY | t                | f        | THERAPIST    |    -45000   ← Mallory's copy
 ALICE SALARY | t                | f        | THERAPIST    |    -45000   ← Mallory's copy
```

Alice's account is archived — from inside her app, it has vanished. Mallory now owns two complete
copies of it, including the merchant name and amount of a transaction Alice would very reasonably
consider private. Mallory was never logged in.

**Who can realistically do this.** The attack needs the account's UUID, which is random and not
guessable — and, per §2.2, **cannot** be harvested from `accounts_with_balances` (I checked; it
doesn't leak). So this is not "anyone can rob everyone". The realistic attacker is
**someone who already knows an account ID legitimately** — above all a **current or former
household member**, who has seen the shared account's ID on their own device.

That makes the concrete scenario: *you remove someone from your household. `can_read_account`
correctly cuts off their live access. They then call this function, from a signed-out app, using
the ID their phone already cached — and walk away with a full copy of the shared account's entire
transaction history, while your copy gets archived.* The household lifecycle's central security
promise is defeated by the very function that implements it.

**The fix — two layers, both needed:**

1. **Shut the public door.** This helper is internal; nothing outside the database should reach it.

   ```sql
   revoke all on function public.fork_one_account(uuid, uuid, uuid) from public, anon, authenticated;
   ```

2. **Add the missing check anyway.** A helper should not depend on its callers' diligence. Before
   doing anything, assert the account exists, that the caller is a member of the household that
   owns it, and that `p_member_a` / `p_member_b` really are that household's members rather than
   arbitrary user IDs the caller chose.

**Why it won't break the app.** Both call sites run as the database owner, so revoking the
*public's* access leaves them untouched:

| Caller | File | Runs as | Still works? |
|---|---|---|---|
| `fork_household_accounts` | `20260816100000_sync_primitives.sql:637` | `SECURITY DEFINER` | ✅ |
| `unshare_account` | `20260816100000_sync_primitives.sql:777` | `SECURITY DEFINER` | ✅ |

And I grepped every `.rpc("…")` in `App/` and `Packages/` — **the app never calls it directly.**
Leaving a household and un-sharing go through `leave_household` / `unshare_account`, unaffected.

---

### 2.2 `accounts_with_balances` ignores the privacy rules (the ERROR) — real, but **not currently leaking**

**Where:** `supabase/migrations/20260819100000_remove_fi_add_account_appearance.sql:229`

**What it is.** A *view* is a saved question — "show me every account with its balance". Keepo's
privacy model (Row Level Security, RLS) is a rule on each table saying *"you may only see rows you
own."* A view runs in one of two modes:

- **`security_invoker`** — the view answers **as you**, so your RLS applies. Like a librarian
  looking things up with *your* library card.
- **`security_definer`** (the default) — the view answers **as whoever created it**, i.e. the
  database owner, who is exempt from RLS. Like the librarian using their own master key and handing
  you the whole archive.

Keepo has ten views. **Nine say `security_invoker`. This one doesn't** — and its own previous
version at `20260815100000_money_as_integers.sql:171` did. The migration's comment explains how it
was lost: `counts_toward_fi` had to be removed from the middle of the column list, which Postgres
can't do with `CREATE OR REPLACE`, so the view was dropped and rewritten from scratch — and the
`with (security_invoker = true)` line didn't come along.

I confirmed it's the only one, straight from the database:

```
       leaky_view       | reloptions
------------------------+------------
 accounts_with_balances |            ← no options set; nine other views all carry security_invoker
```

**⚠️ Correction to my first assessment.** Reading the code, I concluded this was leaking every
user's balances to every signed-in user, and that it could be used to harvest the account IDs that
§2.1 needs. **I tested it, and that is wrong.** Signed in as Alice, the view returns only Alice's
row:

```
            source             | rows_alice_sees
-------------------------------+-----------------
 accounts (base table, RLS)    |               1
 accounts_with_balances (view) |               1   ← correctly filtered
```

**Why it doesn't leak — and why that's not reassuring.** The mechanism is real; the view genuinely
does bypass RLS. I proved that separately by building a plain definer view over `accounts` alone:

```
              probe               | rows_alice_sees
----------------------------------+-----------------
 DEFINER view over accounts alone |               6   ← every account in the database
 accounts base table              |               1
```

Six rows, including another user's. So the danger is exactly as described — **but
`accounts_with_balances` never reaches it**, because it inner-joins `account_balances` and
`account_balances_base`, and *those* two views **are** `security_invoker`. They apply Alice's RLS,
and the join shrinks the result to her accounts before the leak can happen.

In other words: **the view is protected by an accident of its join list, not by its own
permissions.** Anyone who rewrites it into a `LEFT JOIN`, drops one of those sub-views, or reads
directly from `accounts` inside it turns a working query into a full database dump — with no error,
no warning, and nothing in the app looking any different. Given this view has already been rewritten
six times across the migration history, that is a matter of when.

**Revised severity: not a live breach — a latent one.** It stays in P0 because the fix is one line
with zero risk, and because leaving a known trap armed in a finance app is not a defensible
position. But **no user data is exposed through it today**, and this does not need to be treated as
an incident.

**The fix.** Restore the missing clause:

```sql
create or replace view public.accounts_with_balances
with (security_invoker = true) as
select ... ;  -- column list byte-identical to today's
```

**Why it won't break the app.** `CREATE OR REPLACE VIEW` preserves the column list and the existing
`GRANT`, so nothing downstream changes shape. The app already assumes RLS filters this view
(`Packages/KeepoCore/Sources/KeepoCore/Repositories.swift:56` selects it with no `WHERE` clause) —
that assumption simply stops being load-bearing on a coincidence. Because the view already returns
correctly-filtered rows, **users will see no change at all.**

---

## 3. P1 — Moderate: doors that shouldn't be open

All four have the same root cause, so I'll explain it once.

**The root cause: a Postgres default that surprises people.** When you create a function in
Postgres, it automatically grants "anyone may run this" (`PUBLIC`). To lock a function down you
have to *explicitly take that away*:

```sql
revoke all on function foo() from public;
grant execute on function foo() to authenticated;   -- ← this line alone does nothing useful
```

Keepo does this correctly in most places. But **25 functions never got the `revoke` line**. For
those, writing `grant execute ... to postgres` was decorative — the public already had access, and
still does. That's why the advisor reports functions as anon-callable even though the migration
looks like it locked them down.

### 3.1 `restamp_account_for_sync(uuid)` — cross-user tampering

Takes any account ID, no permission check, callable by anyone including signed-out visitors. It
touches every row of an account to force devices to re-sync it.

**Example:** I call it in a loop against your account. Your phone is told, over and over, that
your data changed. Battery drain, wasted bandwidth, and pointless load on your database bill.

**Fix:** `revoke all ... from public`; grant to `postgres` only.
**Safe because:** the app never calls it (verified against every `.rpc()` in the codebase).

### 3.2 `next_ticket(uuid)` — sync ordering corruption

Hands out the sequence numbers that keep sync in order. Callable by anyone.

**Example:** I inflate your counter by a million. Your device's "what's new since number N?"
question now silently skips real changes — a transaction you added never shows up on your other
phone.

**Fix:** `revoke all ... from public`; grant to `postgres` only.
**Safe because:** this is the one I checked hardest, because getting it wrong breaks **every write
in the app**. It's called from six places, all of them `stamp_sync_seq_*` trigger functions — and I
confirmed **all six are `SECURITY DEFINER`**, meaning they run as the database owner, not as you.
So removing the public's access doesn't affect them. `pull_changes` (which *does* run as you) does
not call it at all.

### 3.3 `sync_domain_id(uuid)` — leaks who lives with whom

Takes any user ID and tells you their household ID. Callable by signed-out visitors.

**Example:** given two user IDs, I can tell whether those two people share a household — i.e.
whether they live together. That's personal information Keepo shouldn't hand to strangers.

**Fix:** `revoke all ... from public`; grant to `postgres` only.
**Safe because:** same as §3.2 — only the `SECURITY DEFINER` trigger functions call it at runtime.
The other references are inside a one-time backfill in the migration itself, which runs as the
database owner.

### 3.4 `resolve_category_for_merchant(p_owner, …)` — ⚠️ the fix I had to change

Takes an **arbitrary owner ID** and returns which category that person files a given merchant
under. No check that the owner is you.

**Example:** I can probe whether you have a category rule for a particular shop — a small but real
leak of your spending habits.

**My first instinct was to revoke it from `authenticated`, like the three above. That would have
broken CSV import.**

Here's what the cross-check turned up. It has two callers:

| Caller | Runs as | Effect of revoking from `authenticated` |
|---|---|---|
| `capture_transaction` | `SECURITY DEFINER` (database owner) | Fine |
| `accept_import_candidate` | **`SECURITY INVOKER` (runs as you)** | ❌ **Breaks** |

`accept_import_candidate` **is** called by the app, and it runs as the signed-in user. Revoking the
function from `authenticated` would make "accept this row from my CSV import" fail outright.

**Revised fix — keep the grant, add the guard.** Leave the signature and the grant exactly as they
are, and gate the lookup so it only answers for the caller themselves:

```sql
where m.owner_id = p_owner and p_owner = (select auth.uid()) and ...
```

**Safe because:** in both legitimate call sites `p_owner` *is* the current user —
`capture_transaction` passes `auth.uid()` directly, and `accept_import_candidate` passes the
candidate's owner, which RLS already guarantees is the caller. So behaviour is byte-identical for
every real call, and probing someone else's data returns nothing.

---

## 4. P2 — Hardening (low urgency, low risk)

### 4.1 Nineteen trigger functions are technically public

`stamp_sync_seq_*`, `handle_new_user`, `check_transfer_integrity`, `set_csv_import_batch_owner`,
`trigger_fx_backfill_*`, and friends.

**Why it's mostly noise.** These are *trigger* functions — they run automatically when a row
changes. Postgres **refuses to run a trigger function when you call it directly**, so even though
the advisor is right that the permission exists, there's nothing an attacker can do with it. The
one exception is `ensure_user_bootstrap`, which is a normal function and *is* callable — but with
no logged-in user it just fails on a not-null constraint.

**Fix:** revoke them all from `PUBLIC` anyway. It costs nothing and clears ~19 of the 24 warnings.

**Safe because:** Postgres checks permission on a trigger function **when the trigger is created**,
not each time it fires. Existing triggers keep working. *This is the one assumption in this plan
that I want to confirm empirically with a local `supabase db reset` before pushing to hosted —
if it were wrong, every write in the app would fail, so it deserves a real test rather than my
word for it.*

### 4.2 Seven functions don't pin `search_path`

`set_updated_at`, `bump_version`, `prevent_owner_id_change`, `prevent_default_category_deletion`,
`enforce_household_member_cap`, `next_occurrence_date`, `normalize_budget_period_month`.

**What it is.** `search_path` is the list of places Postgres looks when you write a bare name like
`accounts` instead of `public.accounts`. Pinning it to `''` forces every name to be spelled out in
full, so nobody can slip a decoy table in front of the real one.

**Why it's low risk here.** This is genuinely dangerous for `SECURITY DEFINER` functions (which run
with elevated rights) — and Keepo already pins it on **every single one** of those, with a test
asserting it. All seven of these are ordinary functions that run as you, so there's no elevation to
steal. It's tidiness, and consistency with the rule the codebase already follows everywhere else.

**Fix:** add `set search_path = ''` to each.
**Safe because:** all seven bodies already use fully-qualified names (`public.household_members`) or
built-ins (`now()`, `date_trunc`), so pinning changes nothing. One caveat: `next_occurrence_date`
is `immutable` — recreating it needs a check for dependent indexes first.

### 4.3 `pg_net` lives in the `public` schema

**Recommendation: leave it, and write down why.** `20260812110000_pg_net_schema_fix.sql` already
documents that moving it fails outright (`the extension contains the schema`). The advisor is
flagging a real convention, but the convention can't be satisfied here. Fighting it risks the FX
sync for a cosmetic win.

### 4.4 Authentication settings

Currently: minimum password length **6**, no complexity requirements, no leaked-password checking,
no MFA, `secure_password_change = false`.

**Why it matters for this app specifically.** Everything above is about the database. This is about
the front door. A six-character password with no breach checking means the most likely way someone
sees your financial data isn't a clever attack — it's that you reused a password that leaked from
somewhere else years ago.

**Fix (in the Supabase dashboard, not in code):**
- Minimum password length → **10+**
- Enable **leaked password protection** (checks against HaveIBeenPwned)
- Enable **TOTP MFA** (authenticator app)
- Enable `secure_password_change` (re-authenticate before changing password)

**Important:** `supabase/config.toml` only controls your *local* development database. The hosted
project's settings live in the dashboard, which is why the advisor still flags these. **These are
changes only you can make** — I can't reach the dashboard.

---

## 5. P3 — The advisor is wrong here; don't change these

`ops_events`, `ops_rate_limits`, and `sync_tickets` are flagged as "RLS enabled but no policies".

**This is correct as-is, and "fixing" it would make things worse.** These three tables are internal
bookkeeping — an error log, a rate-limit counter, and a sync sequence counter. They have RLS on and
**no grants to `authenticated` or `anon` at all**. That's deny-by-default: the strongest possible
posture. Adding policies would mean *opening* them up.

`20260816100000_sync_primitives.sql:46` already explains this in a comment. My only suggestion is
to record the same rationale for `ops_events` / `ops_rate_limits` so nobody "helpfully" adds
policies later.

---

## 6. Data-flow safety — the full cross-check

Every function I propose to lock down, checked against every caller. **A ✅ in the last column
means I traced it, not that I assumed it.**

| Function | Called by the iOS app? | Internal callers | Their security mode | Safe to lock down? |
|---|---|---|---|---|
| `fork_one_account` | No | `fork_household_accounts`, `unshare_account` | DEFINER | ✅ |
| `restamp_account_for_sync` | No | none at runtime | — | ✅ |
| `next_ticket` | No | 6 × `stamp_sync_seq_*` | DEFINER | ✅ |
| `sync_domain_id` | No | 3 × `stamp_sync_seq_*` + migration backfill | DEFINER | ✅ |
| `resolve_category_for_merchant` | No | `capture_transaction` (DEFINER), **`accept_import_candidate` (INVOKER)** | mixed | ⚠️ **Guard, don't revoke** |
| 19 trigger functions | No | Postgres trigger system | n/a | ✅ (verify §4.1 locally) |
| `accounts_with_balances` (view) | **Yes** — `Repositories.swift:56` | — | — | ✅ no signature change |

**Left alone deliberately**, because the app depends on them and they already check permissions
correctly:

- `refresh_net_worth_daily` — app calls it; already raises on another user's ID
  (`20260806140000_home_net_worth.sql:144`)
- `log_export`, `map_card`, `unmap_card`, `rename_card_mapping`, `share_account`,
  `unshare_account`, `leave_household`, `accept_invite`, `create_invite` — all app-called, all
  already deriving the user from `auth.uid()`
- `pull_changes` — `SECURITY INVOKER`, so RLS filters the sync delta for free. Correct as designed.
- `capture_transaction`, `review_capture_transaction`, `confirm_capture_transaction` — the capture
  path from the recent audit wave. All derive the owner from `auth.uid()`. Untouched.

**Net client-side impact of this entire plan: zero.** No Swift changes, no RPC signature changes,
no behaviour changes on any path the app actually uses. Every fix is either a permission revoke on
something the app never calls, or a one-line addition to a view/function that keeps its shape.

---

## 7. Stopping this from happening again

Both P0s are **invariant violations**, and `supabase/tests/01_grants_rls.sql` was one assertion
short of catching each of them. That file already checks things like "every table has RLS" and
"every `SECURITY DEFINER` function pins `search_path`" schema-wide, so a new table or function is
covered automatically without anyone remembering.

Two assertions in the same style would have caught both findings the day they were written:

```sql
-- Would have caught §2.2 immediately
select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v'
     and not coalesce(c.reloptions::text like '%security_invoker=true%', false)),
  0::bigint, 'every view in public runs as the invoker, not the definer');

-- Would have caught every §3 finding.
-- Note the `proacl is null` arm: that is the actual trap. A function nobody
-- ever ran `revoke` against has NULL permissions, and NULL means "Postgres
-- defaults apply" — which for functions means PUBLIC can execute. So the
-- dangerous state is the one that looks like no state at all.
select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and (p.proacl is null
          or exists (select 1 from unnest(p.proacl) a where a::text like '=%'))),
  0::bigint, 'no function in public is executable by PUBLIC');
```

Per CLAUDE.md's "root-cause fixes, not patches" — **this is the actual fix.** Everything in §2–§4
is treating symptoms; these two assertions treat the cause, which is that nothing was watching.

---

## 8. Proposed sequencing

Reordered after testing: the **proven** hole is `fork_one_account`, so it leads. The view fix rides
along with it because it is one line and cannot break anything.

| Wave | What | Size | Deploy |
|---|---|---|---|
| **1** | `revoke` on `fork_one_account` **+** restore `security_invoker` on the view | 1 migration, 2 real statements | **Immediately.** Closes the proven exploit; zero client impact. |
| **2** | `fork_one_account` internal ownership guard, P1 revokes (§3.1–3.3), `resolve_category_for_merchant` guard (§3.4) | 1 migration | This week, after Wave 1 is verified on hosted |
| **3** | Trigger-function revokes + 7 × `search_path` | 1 migration | Routine — after a local `db reset` confirms §4.1 |
| **4** | Two new schema invariants | `supabase/tests/01_grants_rls.sql` | With Wave 3 |
| **5** | Auth settings: password length, leaked-password protection, MFA | Supabase dashboard | **Manual — you** |

Waves 1–4 are three migrations plus one test file. All backend-only, no Swift changes.

Wave 1 is deliberately tiny so it can go out without a long review: two statements, both of which
only *remove* access that nothing legitimate uses.

---

## 9. Two things to check before Wave 1

1. **Has anyone besides you ever signed up?** `select count(*) from auth.users;`

   `fork_one_account` has been callable by the public since the schema was first built, and the
   §2.1 exploit is confirmed working. Whether that matters in practice depends entirely on whether
   anyone other than you has ever had an account ID on a device. If it's just you and your test
   accounts, this is a fix and nothing more. If there are real TestFlight users — particularly any
   who have shared a household and then left one — it's worth a moment's thought about whether
   anything actually happened, which `ops_events` and the Postgres logs can help answer.

   Note this is *not* the case for the view (§2.2): it is not leaking and never was, so it carries
   no disclosure question at all.

2. **`rls_auto_enable` exists on the hosted database but in no migration in this repo.** It's most
   likely a Supabase-managed event trigger, but since I can't find it in the repo I can't confirm
   that. Worth a look before Wave 3 touches function permissions — an object in production that
   isn't in the migrations is worth knowing about either way.

   **Resolved, post-push (§13).** It's a DDL event trigger named `ensure_rls`, wired to
   `rls_auto_enable()`, that fires on every `CREATE TABLE` in `public` and auto-runs `ALTER TABLE
   ... ENABLE ROW LEVEL SECURITY` on it — a defensive safety net against a future migration that
   forgets to turn RLS on. It returns `event_trigger`, a pseudo-type Postgres only allows inside
   the event-trigger system: calling it directly fails with the identical "trigger functions can
   only be called as triggers" error the §4.1 test used for `bump_version`, confirmed against the
   hosted project itself — even as `postgres`. PostgREST can't publish `event_trigger` as an RPC at
   all, so despite showing up as PUBLIC-executable in the pg_proc query, it was never reachable.
   Not part of any migration, owned by `postgres`, and not ours to add to version control without
   knowing who set it up or why — left untouched.

---

## 13. Hosted deployment — pushed and verified

`supabase db push` applied all three migrations to the hosted project; `supabase migration list`
confirms local and remote now agree on every one of the 47 migrations. Wave 4 (the test-file edit)
has no hosted equivalent to push — pgTAP tests run against a database, not schema state, and the
new assertions already passed against a from-scratch local reset in §12.

Everything in §12 was re-run against the **hosted** database directly
(`supabase db query --linked`), not assumed from the push succeeding — the first attempt actually
used the CLI's default local-database target by mistake, caught by checking its own "Connecting to
local database" output rather than trusting a clean exit code:

- **§2.2's view leak** — `accounts_with_balances` is the only view flagged locally; the same query
  against hosted returns zero rows. No view in `public` bypasses RLS.
- **§2.1's exploit and the three P1 functions** — `has_function_privilege('anon', ..., 'execute')`
  returns `false` on hosted for `fork_one_account`, `next_ticket`, `sync_domain_id`, and
  `restamp_account_for_sync`. The same call that worked against a fresh local database before
  Wave 1 now fails identically on hosted: `permission denied for function fork_one_account`.
- **PUBLIC-executable count** — 0 locally, 1 on hosted. The one is `rls_auto_enable`, investigated
  and closed out in §9 above: unreachable by anyone, benign, not part of this schema's migration
  history.

**Status: complete.** Waves 1–4 are live on the hosted project and verified against it directly.
Wave 5 (password length, leaked-password protection, MFA) remains — dashboard-only, yours to do.

---

## 10. Note on the previous audit

The capture-pipeline audit concluded: *"no `SECURITY DEFINER` function is missing its
`revoke`/`grant` pair"* and *"I found no path by which one user's rows reach another user through
the server."*

`fork_one_account` contradicts both claims, and it is proven, not theoretical. This isn't a
criticism of that audit — it was scoped to the capture pipeline, and its findings (S-01 through
S-07) were real and are now fixed. But it's a useful reminder about *method*:

**The audit read the migrations and saw `grant execute on function ... to postgres`, which reads
exactly like a lockdown. The linter read the permissions actually in force in the running database
and saw that PUBLIC still had execute — because nobody had ever run the `revoke` that a `grant`
silently assumes.** Twenty-five functions are in that state; I confirmed the count against the
database, and it matches the migrations exactly.

Reading intent is not the same as reading state. That gap is the entire reason for §7's assertions
— and it cuts both ways, which this document is itself an example of: my own first pass called
§2.2 a live breach and §2.1 merely a warning, and only running them got the severity the right way
round.

---

## 11. Appendix — how to reproduce these results

Everything asserted in §2 came from the local stack (`supabase start`), against the current
migration set. Re-runnable, and every one wraps in a transaction that rolls back:

```bash
docker exec -i supabase_db_keepo-app psql -U postgres -X -q
```

**Which views bypass RLS** — returns exactly one row today, `accounts_with_balances`:

```sql
select c.relname, c.reloptions
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'v'
  and not coalesce(c.reloptions::text like '%security_invoker=true%', false);
```

**How many functions the public can execute** — returns `25`:

```sql
select count(*) from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%'));
```

**Whether a signed-out visitor can reach the dangerous ones** — returns `t` four times:

```sql
select has_function_privilege('anon','public.fork_one_account(uuid,uuid,uuid)','execute'),
       has_function_privilege('anon','public.restamp_account_for_sync(uuid)','execute'),
       has_function_privilege('anon','public.next_ticket(uuid)','execute'),
       has_function_privilege('anon','public.sync_domain_id(uuid)','execute');
```

**The §2.1 exploit itself.** Create a user with an account and one transaction, then `set local
role anon` and call `fork_one_account` with that account's ID and any user ID as both members.
Select the account name back afterwards: the original comes back `archived`, alongside two copies
owned by the ID you supplied. Wrap the whole thing in `begin; … rollback;`.

**Why §2.2 does not leak, and what would make it.** Compare the view against a bare definer view
over the same table, as a signed-in user:

```sql
set local request.jwt.claims to '{"sub":"<a real user id>","role":"authenticated"}';
set local role authenticated;
create view probe as select id, name from accounts;   -- definer by default
select (select count(*) from probe)                  as definer_view_sees,   -- every account
       (select count(*) from accounts_with_balances)  as real_view_sees,     -- only yours
       (select count(*) from accounts)                as base_table_sees;    -- only yours
```

The gap between the first number and the other two is the hazard `accounts_with_balances` is
currently sitting one join-list edit away from.
