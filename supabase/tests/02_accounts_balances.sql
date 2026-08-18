-- accounts / balance_snapshots: RLS visibility and the two balance formulas
-- (money rule 1). Fixture A = 11111111-..., fixture B = 22222222-...
-- (supabase/tests/_helpers.sql).
--
-- Money is bigint at fixed scale 4 (L1, migration 20260815100000) — 100.00
-- is written as 1000000.

\ir _helpers.psql

begin;
select plan(12);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- ----------------------------------------------------------------------------
-- RLS visibility
-- ----------------------------------------------------------------------------

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Checking', 'EUR', 1000000);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('b0000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'B Checking', 'USD', 1000000);

select is(
  (select count(*) from accounts where id = 'a0000000-0000-0000-0000-000000000001'),
  0::bigint,
  'fixture B cannot see fixture A''s private account (RLS SELECT, not a UI filter)'
);

-- As of Phase 6 (migration 20260805180000), `authenticated` has no raw
-- UPDATE grant on accounts at all — every account mutation goes through
-- update_account/archive_account/delete_account. This is now a permission
-- error, not RLS's USING clause silently matching zero rows (that was the
-- pre-Phase-6 behavior, and accounts_update's own USING/WITH CHECK is left
-- dormant in place per the same rationale as transactions_update in
-- migration 003).
select throws_ok(
  $$ update accounts set name = 'hijacked' where id = 'a0000000-0000-0000-0000-000000000001' $$,
  null::char(5), null,
  'authenticated has no raw UPDATE grant on accounts, even acting on another owner''s row'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select name from accounts where id = 'a0000000-0000-0000-0000-000000000001'),
  'A Checking',
  'fixture A''s account is untouched by fixture B''s rejected update attempt'
);

-- ----------------------------------------------------------------------------
-- Ledger balance: opening_balance_e4 + SUM(confirmed, non-deleted, occurred_at <= now())
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select balance_e4 from account_balances where account_id = 'a0000000-0000-0000-0000-000000000001'),
  1000000::bigint,
  'ledger balance with zero transactions is exactly opening_balance_e4'
);

insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Test Expense');

insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', -300000, 'EUR', now());

select is(
  (select balance_e4 from account_balances where account_id = 'a0000000-0000-0000-0000-000000000001'),
  700000::bigint,
  'ledger balance reflects a confirmed expense'
);

-- A future-dated row must never move today's balance (recurring's guard,
-- built in now since account_balances already filters on it — Phase 14
-- inherits this for free rather than needing to add it later).
insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', -10000000, 'EUR', now() + interval '10 days');

select is(
  (select balance_e4 from account_balances where account_id = 'a0000000-0000-0000-0000-000000000001'),
  700000::bigint,
  'a future-dated transaction never moves today''s balance'
);

-- A pending (unconfirmed capture) row must never move the balance either.
-- source='capture'/status='pending' is only ever written by
-- capture_transaction (SECURITY DEFINER, bypasses RLS) since S-02 tightened
-- transactions_insert's own WITH CHECK — this is testing account_balances'
-- own filtering, not insert authorization, so the fixture inserts with the
-- same elevated privilege that RPC has, then drops back to authenticated.
reset role;
insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, status, source)
values (auth.uid(), auth.uid(), 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', -5000000, 'EUR', now(), 'pending', 'capture');
set local role authenticated;

select is(
  (select balance_e4 from account_balances where account_id = 'a0000000-0000-0000-0000-000000000001'),
  700000::bigint,
  'a pending transaction never moves the balance'
);

-- ----------------------------------------------------------------------------
-- Valuation balance: latest snapshot at/before today + SUM(transfers after
-- the snapshot's created_at, confirmed, occurred_at <= now())
-- ----------------------------------------------------------------------------

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'valuation', 'investment', 'Brokerage', 'EUR', 0);

select is(
  (select balance_e4 from account_balances where account_id = 'a0000000-0000-0000-0000-000000000002'),
  null::bigint,
  'an unsnapshotted valuation account renders no balance (never 0)'
);

-- created_at is backdated by a minute explicitly: now() is frozen for the
-- whole enclosing transaction in Postgres, so inside this one test-file
-- transaction the snapshot and the transfer below would otherwise share
-- the EXACT same now()-derived timestamp, making occurred_at > created_at
-- false and silently failing to reproduce the same-day-transfer scenario
-- this test exists to cover. Two separate client calls in production never
-- have this problem — each gets its own transaction and its own now().
insert into balance_snapshots (account_id, currency, as_of, value_e4, created_by, created_at)
values ('a0000000-0000-0000-0000-000000000002', 'EUR', current_date, 10000000, auth.uid(), clock_timestamp() - interval '1 minute');

select is(
  (select balance_e4 from account_balances where account_id = 'a0000000-0000-0000-0000-000000000002'),
  10000000::bigint,
  'valuation balance with zero transfers after the snapshot is exactly the snapshot value'
);

-- A same-day transfer must count — the exact bug the Phase 2 log documents
-- comparing occurred_at::date > as_of (both "today", so false) instead of
-- occurred_at > created_at.
select create_transfer('a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 500000);

select is(
  (select balance_e4 from account_balances where account_id = 'a0000000-0000-0000-0000-000000000002'),
  10500000::bigint,
  'a same-day transfer after the snapshot is included in the valuation balance'
);

-- valuation_transfers_only: a valuation account can never take a plain
-- expense/income insert, only transfers.
-- The 4-arg form (sql, errcode, errmsg, description) is the only one that
-- can pin the SQLSTATE while leaving the message unchecked and still
-- supplying a friendly description: the 3-arg (sql, errcode, X) form
-- dispatches X as errmsg to match, NOT as a free-text description —
-- confirmed against pgtap's own source while building this test, after the
-- 3-arg form failed here expecting the description text verbatim as the
-- constraint's error message.
select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values (
       '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
       'a0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', -100000, 'EUR', now()
     ) $$,
  '23514', null,
  'a valuation account rejects a plain expense/income insert (transfers only)'
);

-- accounts_with_balances exposes the join every screen relies on.
select is(
  (select name from accounts_with_balances where account_id = 'a0000000-0000-0000-0000-000000000001'),
  'A Checking',
  'accounts_with_balances joins name/kind/currency onto the balance'
);

select * from finish();
rollback;
