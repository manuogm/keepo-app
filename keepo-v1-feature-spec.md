# Keepo v1 — Feature List

## Platform & Auth
- Native iOS (Swift)
- Sign in with Apple, no social login. SIWA is a **one-time grant** — it does not support per-open biometric re-prompting itself, so "logging in with Face ID" is two mechanisms stacked, not one:
  1. SIWA once (first launch, or after explicit sign-out) → exchanged for a Supabase session
  2. **Face ID gates the cached session on every subsequent open** — the refresh token sits in Keychain behind a `SecAccessControl` requiring biometry (`.biometryCurrentSet`, `.whenUnlockedThisDeviceOnly`). No password is ever typed
  - `.biometryCurrentSet` auto-invalidates if a new face is enrolled on the device, forcing a real SIWA re-login — a genuine device-changed-hands signal, not app logic
- Email OTP as a **linked recovery identity** — not a social login, and permitted alongside SIWA. Without it, a user on Private Relay who disables forwarding leaves no contact channel, and a lost Apple ID means lost financial history
- Per-user individual sign-in
- TLS in transit, encrypted-at-rest Postgres, iOS Data Protection, Keychain for secrets

### Local data protection
Threat model stated explicitly: this protects against a **stolen or briefly-unlocked device and forensic extraction tools**, not a live jailbreak with a debugger attached while the device is unlocked — no app-layer control survives a fully compromised kernel, and the spec should not imply otherwise.
- Local DB uses **`NSFileProtectionCompleteUnlessOpen`** — encrypted at rest, but the Shortcuts App Intent can still *write* a pending capture while the device is locked (this class allows write-while-locked, then re-encrypts)
- **Reads require the device to be unlocked** — a pulled sqlite file off the device is ciphertext without the passcode/biometry
- **No biometric gate on the capture write path.** Gating the App Intent's write behind Face ID would break zero-friction tap capture, since Intents can run without the app being foregrounded or unlockable in the moment. The biometric gate belongs on the session (above) and on read/export/sync, never on capture writes
- **Local data only syncs once a valid Supabase session exists.** This falls out of the above rather than needing separate enforcement: the outbox is written encrypted regardless of session state, and the sync engine has no JWT to push with until a session is present. Stated as an explicit rule so a future background-sync feature doesn't skip the check
- **App-switcher snapshot overlay** — `sceneWillResignActive` swaps the visible view for a blank/logo cover before iOS captures the switcher thumbnail; swapped back in `sceneDidBecomeActive`. Balances must never appear in the switcher or backup thumbnails
- **App Intents may only ever create a pending stub.** They must never read or return a balance, a total, or existing transaction data — even for a future "smarter capture" feature — since Intents execute outside the biometric lock and a richer read surface there is a leak waiting to happen

### Step-up authentication for high-value actions
A cached session (item 1 above) is enough for everyday use, but export, account deletion, and household invite accept/leave require a **fresh** biometric check at the moment of the action:
- Implemented by forcing a **re-read of the Keychain refresh-token item** (the same `.biometryCurrentSet`-gated item from login) rather than trusting whatever access token is already cached in memory. The OS/Secure Enclave enforces this — not app code — so it can't be bypassed by patching a boolean flag in-app the way a standalone `LAContext` prompt could be on a compromised device
- **Export is a full financial dump and the highest-value target in the app.** Step-up re-auth is required immediately before generation, and every export writes an audit row (account, timestamp, what was exported) — the export itself can't be undone, but it can be detected afterward
- **v2 hardening, not required for v1:** bind the biometric check to a signed challenge (a Secure Enclave key, also `.biometryCurrentSet`, signs a server-issued nonce; the server verifies the signature) for cryptographic proof rather than a client-side claim. The Keychain re-read already covers the realistic threat (stolen/briefly-unlocked device); the signed-challenge version defends against a live jailbreak-and-debug session, a meaningfully higher engineering cost for a threat not yet in scope
- **Certificate pinning is explicitly rejected**, not merely omitted — Supabase rotates certs on its own schedule and pinning would turn a routine rotation into an outage

## Onboarding
- Base currency → first account → opening balance → optional Wallet automation walkthrough
- Opening balance is required at account creation; without it the first Sync Ritual produces one enormous unlogged adjustment

## Data & Offline
- Postgres (Supabase) as source of truth
- **Every table has RLS enabled and explicit `GRANT`s** — RLS narrows access a `GRANT` has already given, it grants nothing itself; without the `GRANT`, a query fails before RLS is even consulted. Nothing is granted to `anon`. One policy per command, always `(select auth.uid())`, and UPDATE policies carry both `USING` and `WITH CHECK` — `USING` alone lets a user reassign a row's ownership to someone else
- **Rate limiting on every Edge Function and the ingestion path** (capture, and any future email ingestion) — these are unauthenticated-adjacent surfaces (a forged App Intent call, a mail-server retry storm) and are both a cost-abuse vector and a way to force duplicate-detection into cases it wasn't built for
- On-device cache + offline write queue ("outbox"), unsynced writes flagged
- Device loss/change → resync from backend. Writes that reached the server are safe; **unsynced outbox items on a lost device are lost** — sync on foreground and surface items pending beyond a threshold
- **Client-generated UUID row ids** — a retried create hits the same primary key and cannot duplicate
- **Whole-row push, never per-field merge** — per-field merge can post an amount against an account it never belonged to
- **`version` column** bumped by trigger; the client sends the version it read, and a mismatch is rejected into Needs Review. Never compare clocks — device clocks are user-settable, and a skewed device would win every conflict silently
- **Soft deletes** (`deleted_at`) so deletions replicate and a deleted transaction cannot resurrect
- **A transfer's two legs push in one call**, never separately
- Local cache carries its own schema version and migration path

## Accounts & Multi-Currency
- Two account kinds:
  - **`ledger`** — accepts income, expenses, transfers. Balance = `SUM(amount)`. Subtypes: checking, cash, credit card, loan
  - **`valuation`** — accepts transfers only, never income or expenses. Balance = latest valuation + `SUM(transfers dated after it)`. Subtype: investment
- UI labels: "Everyday" and "Investments" — `valuation` never appears in the interface
- Opening balance at creation; for a `valuation` account this is the first snapshot
- Account archival and exclude-from-total
- Separate **`counts_toward_fi`** flag — a primary residence or a car belongs in net worth but not in the FI calculation
- **Base currency is a per-user display preference.** Every household figure converts using the *viewer's* base, so two members with different base currencies each see a coherent total. No converted amount is ever stored, so this costs nothing
- **Currency picker is limited to the supported set, enforced at creation** — an account in a currency Keepo cannot price can never exist
- Cross-currency transfers: user enters both amounts, FX rate derived (never assumed)

## FX Rate History
- Daily rates vs. one anchor currency, any pair derived at query time
- Nightly fetch job; historical backfill when a new currency first appears
- Weekend/holiday gaps carry forward last available rate, via a rate-resolution function returning the most recent rate on or before a date. **This function does not exist yet — it is to be built**
- **Fully automatic. No manual rate entry, ever** — the friction is unacceptable
- **`source` column on `fx_rates` from day one** (v1 writes only `ecb`). This makes adding a second provider later a config change rather than a migration
- **`fetched_at`** so ECB revisions to an existing `(currency, rate_date)` have a defined winner
- **Supported currencies are the ECB/Frankfurter set (~30 + EUR).** Explicitly unsupported: KWD, BHD, JOD, AED, SAR, ARS, COP, CLP, VND, EGP, TWD. Note that the `numeric(20,4)` money rule is justified in `CLAUDE.md` by KWD/BHD/JOD — the scale stays correct (JPY has 0 minor digits, FX intermediates need the headroom) but the stated reason needs restating

## Transaction Entry & Automation
- Manual entry: expense, income, transfer
- Recurring transactions
- Custom categories; auto-suggestion from merchant/transaction history
- CSV import & export
- Offline transaction logging

### Apple Pay capture
User-built Shortcuts automation on the Wallet transaction trigger → **App Intent** (not a URL scheme — a scheme is forgeable by any app or webpage) → pending stub → notification → user review → local write → sync.

- Trigger payload is `Transaction; Card; Merchant; Amount; Name`
- **No date field.** `occurred_at` is the automation's fire time and must survive an offline delay — never the sync time
- **`Amount` is a formatted string** (`$1.06`). Currency comes from the **mapped account**, never inferred from the symbol; the symbol is only a mismatch check
- **Merchant needs normalization** (`SQ *`, `TST*`, trailing store numbers, LLC suffixes). Store the raw string too, so merchant learning can improve without re-capture
- **The payload carries no transaction id.** Synthesize `external_id` = hash(card + amount + normalized merchant + time bucket) behind a unique index. A re-fired automation must be a no-op — a duplicated charge silently doubling spend is the worst failure this app has
- Card→account mapping handles joint cards; ambiguous cards go to Needs Review

**Known limitations, accepted:**
- Apple Pay only — closed-loop apps (Walmart Pay and similar) never touch Wallet and cannot fire this trigger
- That device only; no card-not-present, online purchases, subscriptions, or direct debits
- The automation must be built by the user. The app guides the setup; it cannot install it

**To verify on device:** whether refunds fire the trigger and how their amount is signed; whether an Apple Watch tap fires the paired phone's automation.

### Recurring
- Store the **rule**, not future rows. A scheduled job materializes a transaction only on or after its due date, backfilling any occurrences missed while the job was down
- Balance reads guard on `occurred_at <= today` regardless — future rows must never reach `SUM(amount)`
- Upcoming instances are projected from the rule at read time
- Editing an instance offers **"this one" vs "all future"**

### Guards
- **Cross-currency transfer rate check** — compare the derived rate against `fx_rates` and warn past an N% divergence. Nothing else catches a `320` → `3200` typo, and it corrupts net worth permanently
- **CSV import** goes through a match-and-review step (exact amount + ±3 days + same account) before insert. CSV carries no transaction ids, so a blind insert of an overlapping statement duplicates everything

## Household & Sharing
- Household = **two** individually signed-in members sharing designated accounts
- Private vs. shared accounts — private genuinely invisible to the other member, not just permissioned
- Invite flow; real-time sync across the household
- `created_by` recorded per transaction, so a shared row shows who entered it
- Unified categories (shared + private), one-time 2-way merge at household formation — exact matches auto-suggested, near-matches flagged for manual review, full history/budget/merchant-learning reassignment on merge. The two-member cap removes the later-joiner case entirely

### Access model
- Shared visibility routes through a **membership table**, not a direct `user_id` check on the account: `household_members(household_id, user_id)` joined via `household_accounts(account_id, household_id)`. RLS: an account is visible if it's in `household_accounts` and the requester has a matching row in `household_members`. Both members get equal SELECT/INSERT on shared accounts with no special-casing
- **Private accounts are never joined into any query the other member's session can execute** — RLS forbids the `SELECT` outright, not merely hides it in the UI. This is what makes the home-screen scopes below a provable guarantee rather than a convention to remember correctly
- **Merchant learning is per-user, not per-household.** `merchant_category_map(user_id, merchant_pattern, category_id)` is RLS-scoped to `user_id` alone and never joined into any household-visible view. It's built from *all* of that user's transactions, private and shared — but the mapping itself never reaches the other member. A shared transaction's resulting *category* is visible per normal sharing rules; the learning behind the suggestion is not

### Leaving
- Either member may leave; the other is **notified and cannot revoke** the decision
- Leaving **forks a full replica** of every shared account and transaction to each side under new ids. The link is cut, no further synchronization, and each member maintains their own balances from that point
- The fork is one transactional, retry-safe server call — a network drop mid-fork must never leave a half-copy
- A leaver's pending offline writes land on their own replica: fork first, then drain the queue
- **This is the app's first push-notification requirement** — APNs plus a server-side trigger
- **Dissolution is just deleting the `household_members` row after the fork completes.** Because RLS keys off membership rather than a per-account grant that must be separately revoked, the old shared account becomes invisible to both members the instant the row is gone — there is no second "revoke access" step to forget

## Sync Ritual
- Dedicated Sync Ritual screen: per-account freshness label ("verified X ago," neutral → muted amber)
- On-demand "Sync now"
- Per-account flow: enter balance, review pending transactions, one-tap "unlogged adjustment" if a gap remains (always visible, never silently absorbed)
- **The adjustment is a real transaction** — `source='adjustment'`, its own system category, never auto-recategorized, always visible in insights. The ritual does **not** store a balance; a stored balance would compete with `SUM(amount)` as a second source of truth
- A **`reconciliations`** row (account, date, entered balance, computed balance, adjustment id) records the event and is what renders "verified X ago"
- Reconciliation is against the **last reconciliation point**. A stale one rebases or is refused — otherwise two members reconciling the same shared account hours apart each write an adjustment and double-count the same gap
- **Valuation accounts:** direct balance update writing a snapshot, no transaction review step, no adjustment
- **Staleness thresholds are per subtype** — cash drifts in a day, a mortgage does not move in a month. One global threshold is either always amber or never useful
- Factual banner above net worth if a feeding balance is meaningfully stale

## Needs Review
One inbox, one badge, one interaction pattern for everything awaiting a judgment call:
- Ambiguous card→account mappings
- Unconfirmed captures
- Low-confidence category suggestions
- Sync conflicts (version mismatch)
- Reconciliation gaps
- CSV import matches
- Duplicate-capture candidates

## Dashboard & Insights
- Home: net worth trajectory as hero metric — Total / Me / Household views
- **`Total = Me + Household`, computed by one server-side RPC (`net_worth(scope)`), never assembled client-side from three separately-fetched numbers.** Because RLS makes another member's private accounts unqueryable rather than merely hidden (see Household → Access model), no combination of the three scopes can be subtracted to reveal a private total — there is no fourth number to leak. Centralizing the computation in one RPC keeps that guarantee in one place instead of re-deriving it correctly in every screen that shows a total
- **Historical points convert at the rate on that date**, never today's. Otherwise every EUR/USD move rewrites last year's net worth, and a chart that changes the past destroys trust faster than a wrong number
- Insights: category breakdowns, savings rate, budget allocation & tracking
- **Investments:** balance is the latest valuation plus transfers dated after it. `latest valuation − SUM(all transfers ever)` is **unrealized gain** — the account's cost basis is already in the ledger, so this metric is free
- **Savings rate excludes both transfers and valuation changes.** Otherwise moving money into savings reads as an expense, and a market dip reads as a bad month
- **Budgets:** viewer's base currency, calendar month, no rollover in v1
- **FI:** FI number, % progress, **years to FI**, and **Coast FI** — all driven by one visible, editable assumption set (target annual spend, withdrawal rate, real return). Never hidden constants. Years-to-FI responds immediately to a change in savings rate, which % progress does not; Coast FI is crossed years earlier and gives a new user something real to show

## Operations & Monitoring
- **Health is derived from data, never from job status.** A cron job reports success when it *dispatched* a request, not when the request worked. Check the data it should have produced: is the newest FX rate older than N days, did recurring materialization produce rows today, how many capture or import failures in 24h
- **Outbound alerts to the operator** — a scheduled check calls an Edge Function that posts to a webhook. Plus a **daily heartbeat**, so silence means the alerting itself is broken
- **MetricKit + Xcode Organizer** for client errors — free, built-in, and no third-party SDK receiving data from a finance app
- **`ops_events`** table (RLS on with no policies, 30-day prune). **No PII** — ids and codes only, never merchant names, amounts, or email addresses. The capture and import parsers will want to log what they could not parse; they must not
- The `—` rule and staleness banners stay as user-facing UX. They are what protect the user when monitoring fails

### Deletion & retention (GDPR/CCPA erasure)
- A member's own account and data are fully erasable on request
- **Erasure reuses the household-leave path** (fork, then delete the membership row) rather than a separate mechanism: fork first so the *other* member's shared-account history is never corrupted by the erasure, then scrub the leaving member's PII from their own resulting copy

## Out of Scope for v1
Deferred deliberately, not overlooked:
- **Email-receipt ingestion** — the one automation that would cover closed-loop apps and card-not-present spend
- **Bank aggregation** (Plaid/Tink/SaltEdge) — the real solution to automatic capture; deferred on cost and business-entity grounds
- **OFX import** — its `FITID` gives perfect dedupe, but parsing is messy across incompatible dialects and coverage skews US/older banks
- Per-holding investment tracking
- Households above two members
- Currencies outside the ECB set
- Web and Android
