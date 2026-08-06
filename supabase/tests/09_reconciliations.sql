-- Sync Ritual & reconciliations (migration 20260806200000_sync_ritual.sql):
-- adjustment transactions move the balance by exactly the gap, a stale
-- reconciliation point is refused rather than risking a double-counted
-- adjustment, valuation reconciliation never touches transactions, and the
-- Adjustment system category is as undeletable as a default one. Fixture A
-- = 11111111-..., fixture B = 22222222-....

\ir _helpers.psql

begin;
select plan(15);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a9000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'Ledger', 'EUR', 1000);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a9000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'valuation', 'investment', 'Brokerage', 'EUR', 5000);
insert into categories (id, owner_id, kind, name)
values ('c9000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Test Expense');

-- The valuation account's first snapshot (Phase 1's AccountRepository.create
-- writes this atomically at real account creation; a raw insert here for
-- test setup mirrors that, matching the "coalesce to real 0 only for
-- ledger" design — a valuation account with no snapshot at all renders `—`,
-- not 0, so a computed_balance for the reconciliation insert below needs
-- one to exist).
insert into balance_snapshots (account_id, currency, as_of, value, created_by)
values ('a9000000-0000-0000-0000-000000000002', 'EUR', current_date, 5000, auth.uid());

insert into transactions (id, owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
values (
  'd9000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(),
  'a9000000-0000-0000-0000-000000000001', 'c9000000-0000-0000-0000-000000000001', -100, 'EUR', now()
);

-- 1. First reconciliation (no prior point, expected id is null): entered
-- 950 against a real 900 (1000 opening - 100 expense) is a +50 gap, which
-- must land as an INCOME adjustment (the sign, not a fixed direction).
select results_eq(
  $$ select conflict, (reconciliation).entered_balance, (reconciliation).computed_balance,
            (adjustment).amount, (adjustment).source::text
     from reconcile_ledger_account('a9000000-0000-0000-0000-000000000001', 950, null) $$,
  $$ values (false, 950.0000::numeric, 900.0000::numeric, 50.0000::numeric, 'adjustment') $$,
  'a +50 gap posts a +50 income adjustment against the real computed balance'
);

select is(
  (select c.kind::text from transactions t join categories c on c.id = t.category_id
   where t.account_id = 'a9000000-0000-0000-0000-000000000001' and t.source = 'adjustment'),
  'income',
  'a positive gap files under the income-kind Adjustment category'
);

select is(
  (select account_balance_on('a9000000-0000-0000-0000-000000000001', current_date)),
  950.0000::numeric,
  'the balance after the first reconciliation equals the entered balance exactly'
);

-- 2. A stale retry — expected_last_reconciliation_id = null is no longer
-- the real last id (reconciliation #1 now exists) — must be refused, not
-- silently write a second adjustment for the same gap.
select is(
  (select conflict from reconcile_ledger_account('a9000000-0000-0000-0000-000000000001', 999, null)),
  true,
  'reconciling against a stale (no-longer-latest) expected id is refused'
);

select is(
  (select count(*) from reconciliations where account_id = 'a9000000-0000-0000-0000-000000000001'),
  1::bigint,
  'the refused stale retry left no second reconciliations row'
);

-- 3. The correct follow-up, against the real last id, succeeds with a
-- negative gap and an EXPENSE adjustment.
select is(
  (select (adjustment).amount from reconcile_ledger_account(
    'a9000000-0000-0000-0000-000000000001', 900,
    (select id from reconciliations where account_id = 'a9000000-0000-0000-0000-000000000001')
  )),
  -50.0000::numeric,
  'a -50 gap against the real last reconciliation posts a -50 expense adjustment'
);

-- 4. A zero-gap reconciliation writes a reconciliations row but no
-- adjustment transaction at all (never a $0 adjustment nobody asked for).
select is(
  (select (adjustment).id from reconcile_ledger_account(
    'a9000000-0000-0000-0000-000000000001', 900,
    (select id from reconciliations where account_id = 'a9000000-0000-0000-0000-000000000001'
     order by created_at desc limit 1)
  )),
  null::uuid,
  'a zero gap posts no adjustment transaction'
);

select is(
  (select count(*) from transactions
   where account_id = 'a9000000-0000-0000-0000-000000000001' and source = 'adjustment'),
  2::bigint,
  'exactly two adjustments exist total — the zero-gap reconciliation added none'
);

-- 5. Wrong-kind guard: reconcile_ledger_account refuses a valuation account.
select throws_like(
  $$ select * from reconcile_ledger_account('a9000000-0000-0000-0000-000000000002', 100, null) $$,
  '%use reconcile_valuation_account%',
  'reconcile_ledger_account refuses a valuation account'
);

-- 6. Valuation reconciliation: writes a snapshot + reconciliation, posts
-- zero transactions, no matter the size of the gap (spec: no adjustment,
-- no transaction review step for valuation accounts).
select results_eq(
  $$ select conflict, (reconciliation).entered_balance, (reconciliation).computed_balance,
            (reconciliation).snapshot_id is not null, (reconciliation).adjustment_txn_id is null
     from reconcile_valuation_account('a9000000-0000-0000-0000-000000000002', 5200, null) $$,
  $$ values (false, 5200.0000::numeric, 5000.0000::numeric, true, true) $$,
  'reconcile_valuation_account writes a snapshot and a reconciliation with no adjustment'
);

select is(
  (select count(*) from transactions where account_id = 'a9000000-0000-0000-0000-000000000002'),
  0::bigint,
  'a valuation reconciliation never inserts a transaction'
);

-- 7. Wrong-kind guard, the other direction.
select throws_like(
  $$ select * from reconcile_valuation_account('a9000000-0000-0000-0000-000000000001', 100, null) $$,
  '%use reconcile_ledger_account%',
  'reconcile_valuation_account refuses a ledger account'
);

-- 8. The Adjustment system category is exactly as undeletable as a default
-- one — prevent_default_category_deletion's widened condition.
select throws_like(
  $$ update categories set deleted_at = now()
     where owner_id = '11111111-1111-1111-1111-111111111111' and system_key = 'adjustment_income' $$,
  '%cannot be deleted%',
  'the Adjustment system category cannot be soft-deleted'
);

-- ----------------------------------------------------------------------------
-- 9. Two household members reconciling the same shared account: the second
-- one's stale expected-id is refused, exactly as it would be for one owner
-- reconciling twice — the guard is identity-agnostic by design, which is
-- what makes it correct for both cases with the same code path.
-- ----------------------------------------------------------------------------

select create_household();

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a9000000-0000-0000-0000-000000000003', auth.uid(), auth.uid(), 'ledger', 'checking', 'Shared', 'EUR', 300);
select share_account('a9000000-0000-0000-0000-000000000003');

reset role;
select set_config('request.jwt.claim.sub', '', true);

insert into household_members (household_id, user_id)
select household_id, '22222222-2222-2222-2222-222222222222'
from household_members where user_id = '11111111-1111-1111-1111-111111111111';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- A reconciles first, from a state where no reconciliation exists yet.
select reconcile_ledger_account('a9000000-0000-0000-0000-000000000003', 320, null);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- B, who also loaded the ritual before A's reconciliation landed, still
-- holds expected_id = null — now stale. Must be refused, not double-post.
select is(
  (select conflict from reconcile_ledger_account('a9000000-0000-0000-0000-000000000003', 350, null)),
  true,
  'a household member reconciling against B''s now-stale expected id is refused, not double-counted'
);

select is(
  (select count(*) from reconciliations where account_id = 'a9000000-0000-0000-0000-000000000003'),
  1::bigint,
  'only A''s reconciliation exists — B''s refused attempt wrote nothing'
);

select * from finish();
rollback;
