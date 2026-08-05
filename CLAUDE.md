# Project: KEEPO

Personal finance iOS app: auto-captures expenses from Apple Pay + iOS Shortcuts (closed-loop apps like Walmart Pay) into Supabase; native SwiftUI client.

## Stack
SwiftUI + Swift Package Manager, Xcode. Supabase (Postgres/Auth/Edge Functions/Storage) — new backend built from scratch for this version, no ORM, hand-written SQL migrations + `supabase-swift` client.

## Structure
See `app-architecture.md` 
Fill it in as the architecture solidifies, don't duplicate here.

## Master plan
**`keepo-v1-master-plan.md` is the authoritative roadmap for the rest of the v1 build (Phases 5–20).** If a session starts with no memory of prior work — context lost, cleared, or a fresh agent — **read this file first**, before touching code. It has the phase-by-phase order, the reasoning for that order (hazards it exists to avoid), doc amendments in flight, and the human-review-stop cadence agreed with the user.
If the plan changes while building — a phase splits, a hazard turns out different, a decision gets revisited — **update `keepo-v1-master-plan.md` in place** with the key finding before continuing. It must stay a reliable source of truth, not a snapshot of the day it was written.

## Version logs
Before starting work on a new version, **read every file in `version-logs/`** — all `*-log.md` and `lessons-learned.md` files, across all past versions. They contain prior implementation summaries, open items carried forward, and hard-won lessons (environment quirks, framework gotchas, footguns already hit). Do not repeat mistakes documented there. When you finish a version, add/update its log and lessons file in that same folder, concise and written for the next agent, not a human.

## Commands
- Build/run: Xcode (`xcodebuild -scheme Keepo build`, or open `Keepo.xcodeproj` and Run). `Keepo.xcodeproj` is generated from `project.yml` via XcodeGen — edit `project.yml`, then run `xcodegen generate`, never hand-edit the `.xcodeproj`
- Lint: SwiftLint — must pass before PR/release
- `Swift Testing` (`@Suite`/`@Test`/`#expect`, not `XCTest`) — pure logic (money, dates, FX, validation) lives in the `KeepoCore` Swift package and is unit tested in `Packages/KeepoCore/Tests/KeepoCoreTests`, run via `swift test` or as part of the `Keepo` scheme. App-target-specific logic is tested in `KeepoTests`
- `XCUITest` — UI flows in `KeepoUITests`
- `supabase start` / `db reset` / `db push`
- `supabase gen types swift` — regenerate types after **every** migration
- `supabase functions deploy <name>`

## Money rules (non-negotiable)
1. `amount` is **signed** — negative outflow, positive inflow. Two account kinds, two balance rules: `ledger` accounts (checking, cash, credit card, loan) take income/expense/transfer and balance is `SUM(amount)`; `valuation` accounts (investment) take transfers only and balance is the latest valuation snapshot plus `SUM(transfers dated after it)`. Never re-sign in application code, and never let a valuation change post as income or expense.
2. `numeric(20,4)`, never `(14,2)` — JPY has 0 minor digits, and FX conversion intermediates need the extra headroom even though v1's supported currencies (the ECB/Frankfurter set) are all 2-decimal. Round only for display, from `currencies.minor_unit`.
3. **All money arithmetic in SQL**, never Swift. `supabase-swift` should decode `numeric` columns as `String`/`Decimal`, never `Double` — and never sum decoded amounts client-side.
4. Postgres **enums, not `text` + CHECK** — a CHECK generates as a plain string in codegen, an enum as a proper type.
5. A value that cannot be computed renders as **`—`, never `0`**. A missing FX rate is not a zero balance.
6. **No converted amount is ever stored.** `fx_rates` is append-only, so converting on read is stable *and* survives a base-currency change.

## Code Style
- Visual/brand: see `keepo-brand-identity.md` 
- `snake_case` SQL ↔ `camelCase` Swift, mapped explicitly via `CodingKeys` in model types
- Never commit `.env` / secrets — keep Supabase keys out of git, load via `.xcconfig` or a gitignored config
- **RLS grants nothing** — every table needs explicit `GRANT`s alongside its policies, `service_role` included

## Deploy
Backend: `supabase db push` manually — migrations are **not** automatic. Order: migration first, then dependent client code — never reverse.
Client: TestFlight for beta builds, App Store Connect for release. No auto-deploy on push.

## Engineering Principles
- **Reuse before writing.** Before adding a function, view, or RPC, search for an existing one that already does the job — extend or call it rather than writing a parallel copy. Money formatting, currency conversion, FX lookups, date bucketing, and ownership/RLS checks are exactly the kind of logic that must live in **one place**, never re-implemented per screen or per migration:
  - **SQL** — shared logic as a function or view, called by every RPC/policy that needs it. Never copy a query across migrations.
  - **Swift** — shared view models, formatters, and extensions in one common location, referenced by every screen that needs them. The transaction form's three tabs and the Home/Insights/Sync Ritual screens should call the same balance/currency-formatting code, not each carry their own.
- **Simplest code that solves the actual requirement.** No speculative abstraction, no configurability nobody asked for, no wrapper around a wrapper. Two similar call sites can stay duplicated; a third is the signal to extract a shared helper — don't extract earlier on a guess, don't stay duplicated past that point out of inertia.
- **Root-cause fixes, not patches.** When something fails, trace it to where it actually originates before writing a fix. A wrong balance is a schema or query bug, not a display-side rounding tweak; a duplicate transaction is a missing idempotency key, not a client-side dedupe filter added after the fact. A change that only makes the symptom disappear at the point it was noticed is not acceptable — find the layer where the invariant actually broke and fix it there, the way a senior engineer would.

## Rules
Be concise. Gold-standard work.
