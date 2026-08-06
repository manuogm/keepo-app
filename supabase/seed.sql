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
-- ledger/valuation split and a cross-currency FX line in one seed.
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values
  (
    'aaaaaaaa-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999',
    '99999999-9999-9999-9999-999999999999', 'ledger', 'checking', 'Everyday Checking', 'EUR', 1000
  ),
  (
    'aaaaaaaa-0000-0000-0000-000000000002', '99999999-9999-9999-9999-999999999999',
    '99999999-9999-9999-9999-999999999999', 'ledger', 'checking', 'US Checking', 'USD', 500
  ),
  (
    'aaaaaaaa-0000-0000-0000-000000000003', '99999999-9999-9999-9999-999999999999',
    '99999999-9999-9999-9999-999999999999', 'valuation', 'investment', 'Brokerage', 'EUR', 0
  );

insert into balance_snapshots (account_id, currency, as_of, value, created_by)
values (
  'aaaaaaaa-0000-0000-0000-000000000003', 'EUR', current_date, 5000,
  '99999999-9999-9999-9999-999999999999'
);

-- User B: a single USD checking account, kept simple.
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values (
  'bbbbbbbb-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888',
  '88888888-8888-8888-8888-888888888888', 'ledger', 'checking', 'Checking', 'USD', 2000
);

-- A handful of transactions against user A's default "Other" categories.
insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at, source)
select
  '99999999-9999-9999-9999-999999999999', '99999999-9999-9999-9999-999999999999',
  'aaaaaaaa-0000-0000-0000-000000000001', c.id, -42.50, 'EUR', now() - interval '2 days', 'manual'
from categories c
where c.owner_id = '99999999-9999-9999-9999-999999999999' and c.kind = 'expense';

insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at, source)
select
  '99999999-9999-9999-9999-999999999999', '99999999-9999-9999-9999-999999999999',
  'aaaaaaaa-0000-0000-0000-000000000001', c.id, 2500.00, 'EUR', now() - interval '5 days', 'manual'
from categories c
where c.owner_id = '99999999-9999-9999-9999-999999999999' and c.kind = 'income';

insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at, source)
select
  '88888888-8888-8888-8888-888888888888', '88888888-8888-8888-8888-888888888888',
  'bbbbbbbb-0000-0000-0000-000000000001', c.id, -18.20, 'USD', now() - interval '1 days', 'manual'
from categories c
where c.owner_id = '88888888-8888-8888-8888-888888888888' and c.kind = 'expense';

-- A handful of fx_rates so the two USD-denominated rows above convert to a
-- real number instead of "—" when a screen renders them. Deliberately
-- routes through the same upsert_fx_rate() every real write uses, not a
-- direct insert — fx_rates has no INSERT grant at all, seed included.
select upsert_fx_rate('USD', current_date - n, 0.92, 'ecb', now())
from generate_series(0, 5) as n;
