-- Phase 5: local dev seed data. `supabase/config.toml` has pointed
-- `db.seed.sql_paths` at this file since Phase 1; it never existed, so every
-- account after onboarding's first one required direct SQL (flagged as
-- blocking in the phase-3 and phase-4 logs). Runs once per `supabase db
-- reset`, local only — never applied to the hosted project.
--
-- Two fixture users, deliberately DIFFERENT ids from the pgTAP suite's own
-- fixtures (supabase/tests/_helpers.psql, 11111111-.../22222222-...) —
-- Phase 8 found the two sets had accidentally been given the SAME ids
-- despite _helpers.psql's own header comment already claiming they were
-- distinct. That collision was invisible through Phase 7 because no test
-- before Phase 8 aggregated "everything a fixture user owns"; net_worth_
-- series does exactly that, and started summing this file's seeded
-- accounts into what were supposed to be tightly-scoped test assertions.
-- Fixed by actually separating the id spaces, matching what _helpers.psql
-- already said should be true. Inserted directly into auth.users (bcrypt
-- via pgcrypto, already enabled) rather than through a signup call — this
-- file runs before any Edge/Auth container work is meaningful, and a raw
-- insert is what every Supabase seed script does for this. handle_new_user()
-- fires on insert exactly as it would for a real signup, creating each
-- profile and its two default categories.
--
-- These are NOT the same identity as StubAuthProvider's dev@keepo.local —
-- that one is created by the app itself on first launch via a real signUp
-- call and is untouched by this file.

-- Local-only placeholder vault secrets (Phase 13) — never real values.
-- Seeded FIRST, before any account/profile insert below, since those fire
-- the FX-backfill triggers immediately — seeding secrets after them would
-- mean this file's own inserts always log a missing_vault_secret error on
-- every fresh `db reset`. The Edge Functions themselves still need
-- matching env vars (`supabase functions serve --env-file ...`) to accept
-- these — see version-logs/phase-13-log.md for the exact local values.
select vault.create_secret(
  'http://host.docker.internal:54321/functions/v1/sync-fx-rates', 'fx_sync_url', 'sync-fx-rates Edge Function URL'
)
where not exists (select 1 from vault.decrypted_secrets where name = 'fx_sync_url');

select vault.create_secret('local-dev-fx-sync-secret', 'fx_sync_secret', 'X-Fx-Sync-Secret header value')
where not exists (select 1 from vault.decrypted_secrets where name = 'fx_sync_secret');

select vault.create_secret(
  'http://host.docker.internal:54321/functions/v1/alert-operator', 'alert_operator_url', 'alert-operator Edge Function URL'
)
where not exists (select 1 from vault.decrypted_secrets where name = 'alert_operator_url');

select vault.create_secret(
  'local-dev-alert-operator-secret', 'alert_operator_secret', 'X-Alert-Operator-Secret header value'
)
where not exists (select 1 from vault.decrypted_secrets where name = 'alert_operator_secret');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, recovery_token,
  email_change_token_new, email_change
) values
  (
    '00000000-0000-0000-0000-000000000000',
    '99999999-9999-9999-9999-999999999999',
    'authenticated', 'authenticated', 'seed-a@keepo.local',
    crypt('keepo-seed-password', gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}',
    now(), now(), '', '', '', ''
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    '88888888-8888-8888-8888-888888888888',
    'authenticated', 'authenticated', 'seed-b@keepo.local',
    crypt('keepo-seed-password', gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}', '{}',
    now(), now(), '', '', '', ''
  );

insert into auth.identities (
  provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
) values
  (
    '99999999-9999-9999-9999-999999999999', '99999999-9999-9999-9999-999999999999',
    '{"sub":"99999999-9999-9999-9999-999999999999","email":"seed-a@keepo.local"}',
    'email', now(), now(), now()
  ),
  (
    '88888888-8888-8888-8888-888888888888', '88888888-8888-8888-8888-888888888888',
    '{"sub":"88888888-8888-8888-8888-888888888888","email":"seed-b@keepo.local"}',
    'email', now(), now(), now()
  );

-- handle_new_user() already created profiles + default "Other" categories.
-- Onboard both with different base currencies — deliberately, so any screen
-- that assumes "everyone shares one base currency" breaks visibly in Studio
-- long before Phase 7 makes it a correctness requirement.
update profiles set base_currency = 'EUR', onboarded_at = now()
where id = '99999999-9999-9999-9999-999999999999';
update profiles set base_currency = 'USD', onboarded_at = now()
where id = '88888888-8888-8888-8888-888888888888';

-- User A: EUR checking, USD checking, an investment account — covers the
-- regular/investment kinds and a cross-currency FX line in one seed. Every
-- kind takes the same opening_balance_e4 + SUM(amount_e4) formula now, so
-- the investment account's value is just its opening balance like any
-- other — no separate balance_snapshots seed needed.
-- Money columns are bigint at fixed scale 4 (see the L1 migration) — 1000
-- becomes 10000000, i.e. amount_e4 = decimal_amount * 10000.
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  (
    'aaaaaaaa-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999',
    '99999999-9999-9999-9999-999999999999', 'regular', 'Everyday Checking', 'EUR', 10000000
  ),
  (
    'aaaaaaaa-0000-0000-0000-000000000002', '99999999-9999-9999-9999-999999999999',
    '99999999-9999-9999-9999-999999999999', 'regular', 'US Checking', 'USD', 5000000
  ),
  (
    'aaaaaaaa-0000-0000-0000-000000000003', '99999999-9999-9999-9999-999999999999',
    '99999999-9999-9999-9999-999999999999', 'investment', 'Brokerage', 'EUR', 50000000
  );

-- User B: a single USD checking account, kept simple.
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values (
  'bbbbbbbb-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888',
  '88888888-8888-8888-8888-888888888888', 'regular', 'Checking', 'USD', 20000000
);

-- A handful of transactions against user A's default "Other" categories.
-- `is_default` (not just `kind`) is required here — Phase 9/12 added
-- Adjustment/Uncategorized categories of the same kind for every user, and
-- a bare `kind = 'expense'` filter on a SELECT feeding an INSERT ... SELECT
-- silently multiplies one intended row into one per matching category
-- (confirmed empirically: this exact query tripled every seeded expense
-- transaction until this fix, only noticed once Phase 15's insights RPCs
-- summed the duplicates).
insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, source)
select
  '99999999-9999-9999-9999-999999999999', '99999999-9999-9999-9999-999999999999',
  'aaaaaaaa-0000-0000-0000-000000000001', c.id, -425000, 'EUR', now() - interval '2 days', 'manual'
from categories c
where c.owner_id = '99999999-9999-9999-9999-999999999999' and c.kind = 'expense' and c.is_default;

insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, source)
select
  '99999999-9999-9999-9999-999999999999', '99999999-9999-9999-9999-999999999999',
  'aaaaaaaa-0000-0000-0000-000000000001', c.id, 25000000, 'EUR', now() - interval '5 days', 'manual'
from categories c
where c.owner_id = '99999999-9999-9999-9999-999999999999' and c.kind = 'income' and c.is_default;

insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, source)
select
  '88888888-8888-8888-8888-888888888888', '88888888-8888-8888-8888-888888888888',
  'bbbbbbbb-0000-0000-0000-000000000001', c.id, -182000, 'USD', now() - interval '1 days', 'manual'
from categories c
where c.owner_id = '88888888-8888-8888-8888-888888888888' and c.kind = 'expense' and c.is_default;

-- A handful of fx_rates so the two USD-denominated rows above convert to a
-- real number instead of "—" when a screen renders them. Deliberately
-- routes through the same upsert_fx_rate() every real write uses, not a
-- direct insert — fx_rates has no INSERT grant at all, seed included.
--
-- **units_per_eur is units of the currency per 1 EUR** — the direction
-- Frankfurter returns for ?base=EUR, which sync-fx-rates stores verbatim, and
-- the direction fx_convert() divides and multiplies by. So 1.1669 means one
-- euro buys 1.1669 dollars (the real close for 2026-08-26, checked against
-- the API rather than invented, so a dev dashboard shows a number a human
-- would recognise).
--
-- It was 0.92 here — that figure roughly the wrong way round. Read against
-- the column it says a euro buys 92 cents, so every dev dashboard quoted
-- EUR/USD about 20% low while the arithmetic around it was perfectly
-- correct. The seed had followed the old column name (`rate_to_eur`) instead
-- of the data; see migration 20260905100000.
select upsert_fx_rate('USD', current_date - n, 1.1669, 'ecb', now())
from generate_series(0, 5) as n;
