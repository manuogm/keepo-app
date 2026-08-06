-- Recurring transactions (migration 20260808120000_recurring.sql):
-- materialize_recurring's backfill + idempotency, the future-dated guard,
-- next_occurrences' read-time projection, sign validation, and RLS.
-- Fixture A = 11111111-..., fixture B = 22222222-....

\ir _helpers.psql

begin;
select plan(17);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a4000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Checking', 'EUR', 1000);
insert into categories (id, owner_id, kind, name)
values
  ('c4000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Subscriptions'),
  ('c4000000-0000-0000-0000-000000000002', auth.uid(), 'income', 'Salary');

-- 1. A wrong-signed rule (positive amount against an expense category) is
-- refused up front, not left to fail obscurely inside a later cron run.
select throws_like(
  $$
    insert into recurring_rules (account_id, category_id, amount, currency, frequency, next_due_at, created_by)
    values (
      'a4000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000001',
      12.99, 'EUR', 'monthly', current_date, '11111111-1111-1111-1111-111111111111'
    )
  $$,
  '%must be negative%',
  'a positive amount against an expense category is refused at creation, not at materialization'
);

-- 2. owner_id is derived from the account, not client-supplied — confirms
-- the trigger actually ran, not just that the column has a value.
insert into recurring_rules (id, account_id, category_id, amount, currency, frequency, next_due_at, created_by)
values (
  'e4000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000001',
  'c4000000-0000-0000-0000-000000000001', -12.99, 'EUR', 'monthly', current_date - 65,
  '11111111-1111-1111-1111-111111111111'
);

select is(
  (select owner_id from recurring_rules where id = 'e4000000-0000-0000-0000-000000000001'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'owner_id is derived from the rule''s account, matching its owner'
);

-- materialize_recurring/next_occurrences/recurring_materialization_check are
-- all service_role-only (ops-only surface, same pattern as Phase 13) — the
-- rest of this file runs as postgres, which bypasses RLS/grants entirely,
-- until the final RLS section re-establishes fixture roles explicitly.
reset role;
select set_config('request.jwt.claim.sub', '', true);

-- 3-4. Backfill after 65 missed days (a monthly rule) produces exactly 3
-- rows (~Jun 2, Jul 2, Aug 2 relative to whatever "today" the suite runs
-- on) — the exact count depends only on the date math, asserted generically
-- via next_due_at's own advancement rather than a hardcoded date.
select is(
  materialize_recurring(current_date),
  3,
  'a monthly rule 65 days overdue backfills exactly 3 occurrences'
);

select is(
  (select count(*) from transactions where recurring_rule_id = 'e4000000-0000-0000-0000-000000000001'),
  3::bigint,
  'exactly 3 recurring transactions were actually inserted'
);

-- 5. Re-running the exact same call is a no-op — idempotency by
-- construction (the partial unique index on (owner_id, source,
-- external_id)), not a separate "already materialized" check.
select is(
  materialize_recurring(current_date),
  0,
  're-running materialize_recurring for the same date produces zero new rows'
);

-- 6. next_due_at advanced past today, matching the last inserted occurrence
-- plus one more period.
select ok(
  (select next_due_at > current_date from recurring_rules where id = 'e4000000-0000-0000-0000-000000000001'),
  'next_due_at is advanced strictly past the materialized-through date'
);

-- 7. Every materialized row is source='recurring' and carries the rule id.
select is(
  (select count(*) from transactions
   where recurring_rule_id = 'e4000000-0000-0000-0000-000000000001' and source != 'recurring'),
  0::bigint,
  'every row materialized from a rule is source=recurring'
);

-- 8-9. The future-dated guard: materializing 60 days ahead creates
-- future-dated rows, but today's account_balances is untouched — Home's
-- balance can never move because of a not-yet-due recurring occurrence.
select balance from account_balances where account_id = 'a4000000-0000-0000-0000-000000000001' \gset before_

select materialize_recurring(current_date + 60);

select is(
  (select count(*) from transactions
   where recurring_rule_id = 'e4000000-0000-0000-0000-000000000001' and occurred_at::date > current_date),
  2::bigint,
  'materializing ahead of today does create future-dated rows'
);

select is(
  (select balance from account_balances where account_id = 'a4000000-0000-0000-0000-000000000001'),
  :'before_balance'::numeric,
  'a future-dated materialized row never moves today''s account_balances'
);

-- 10-11. next_occurrences is pure projection — it never inserts anything,
-- and it starts from the rule's own next_due_at (already advanced above).
select is(
  (select count(*) from next_occurrences('e4000000-0000-0000-0000-000000000001', 3)),
  3::bigint,
  'next_occurrences returns exactly the requested count'
);

select is(
  (select count(*) from transactions where recurring_rule_id = 'e4000000-0000-0000-0000-000000000001'),
  5::bigint,
  'calling next_occurrences inserted no additional rows (still exactly the 5 from materialize above)'
);

-- 12. recurring_materialization_check reports unhealthy for a rule overdue
-- by more than a day, healthy once caught up.
insert into recurring_rules (id, account_id, category_id, amount, currency, frequency, next_due_at, created_by)
values (
  'e4000000-0000-0000-0000-000000000002', 'a4000000-0000-0000-0000-000000000001',
  'c4000000-0000-0000-0000-000000000002', 3000, 'EUR', 'monthly', current_date - 10,
  '11111111-1111-1111-1111-111111111111'
);

select is(
  (select healthy from recurring_materialization_check()),
  false,
  'recurring_materialization_check is unhealthy while a rule sits overdue'
);

select materialize_recurring(current_date);

select is(
  (select healthy from recurring_materialization_check()),
  true,
  'recurring_materialization_check recovers once the overdue rule is caught up'
);

-- ----------------------------------------------------------------------------
-- 13-16. RLS: fixture B cannot see or write fixture A's recurring rules;
-- materialize_recurring/next_occurrences/recurring_materialization_check
-- are all locked to service_role, same ops-only-surface pattern as Phase 13.
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select count(*) from recurring_rules),
  0::bigint,
  'fixture B sees none of fixture A''s recurring rules'
);

-- RLS filters the row out of UPDATE's own view rather than raising — a
-- matched-zero-rows UPDATE is a normal, silent success, not an exception.
-- Confirmed as postgres afterward that the row was genuinely untouched.
update recurring_rules set active = false where id = 'e4000000-0000-0000-0000-000000000001';

reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select active from recurring_rules where id = 'e4000000-0000-0000-0000-000000000001'),
  true,
  'fixture B''s update matched zero rows — the rule is still active, untouched'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select throws_like(
  $$ select materialize_recurring(current_date) $$,
  '%permission denied%',
  'an authenticated user cannot call materialize_recurring()'
);

select throws_like(
  $$ select recurring_materialization_check() $$,
  '%permission denied%',
  'an authenticated user cannot call recurring_materialization_check()'
);

select * from finish();
rollback;
