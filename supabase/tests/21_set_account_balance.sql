-- set_account_balance: see supabase/migrations/20260814200000_
-- set_account_balance.sql, amended by 20260815100000_money_as_integers.sql
-- to take p_expected_version (LH6: two concurrent balance edits must
-- conflict like every other write, not silently apply and vanish) and to
-- check idempotency BEFORE the version check, so a retried outbox write
-- with the same client-generated id still succeeds even though the
-- account's version has since moved past what the retry claims to expect.
-- Collapsed by 20260902100000_unify_account_kinds.sql to a single path —
-- every account kind now files an adjustment transaction, never a
-- balance_snapshots row (that table and the old valuation branch are gone).
-- Fixture A = 11111111-...

\ir _helpers.psql

begin;
select plan(14);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000021', auth.uid(), auth.uid(), 'regular', 'Checking', 'EUR', 1000000);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000022', auth.uid(), auth.uid(), 'investment', 'Brokerage', 'EUR', 10000000);

-- 1. Raising a ledger account's balance creates a positive adjustment
-- transaction for exactly the gap. Both accounts start at version 1.
select set_account_balance('a0000000-0000-0000-0000-000000000021', 1500000, 1);
select is(
  (select amount_e4 from transactions where account_id = 'a0000000-0000-0000-0000-000000000021' and source = 'adjustment'),
  500000::bigint,
  'raising a ledger balance by 50 creates a +50 adjustment transaction'
);

-- 2. The adjustment is filed under the default "Other" (income) category.
select is(
  (select c.is_default from transactions t join categories c on c.id = t.category_id
   where t.account_id = 'a0000000-0000-0000-0000-000000000021' and t.source = 'adjustment'),
  true,
  'the adjustment is filed under the default category'
);

-- 3. account_balance_on now reflects the new balance exactly.
select is(
  (select account_balance_on('a0000000-0000-0000-0000-000000000021', current_date)),
  1500000::bigint,
  'the ledger account''s computed balance matches the entered value'
);

-- 4. Lowering the balance creates a negative (expense) adjustment. That
-- first edit bumped the checking account to version 2.
select set_account_balance('a0000000-0000-0000-0000-000000000021', 1000000, 2);
select is(
  (select account_balance_on('a0000000-0000-0000-0000-000000000021', current_date)),
  1000000::bigint,
  'lowering the balance creates a negative adjustment reaching the new value'
);

-- 5. Setting the balance to its current value is a no-op — no zero-amount
-- transaction (the DB's own amount_not_zero CHECK would reject one anyway),
-- and no version bump either. Now at version 3.
select is(
  (select transaction_id from set_account_balance('a0000000-0000-0000-0000-000000000021', 1000000, 3)),
  null::uuid,
  'setting a ledger balance to its current value creates no transaction'
);

select is(
  (select count(*) from transactions where account_id = 'a0000000-0000-0000-0000-000000000021' and source = 'adjustment'),
  2::bigint,
  'no-op balance set left the adjustment count unchanged'
);

-- 6. An investment account's balance edit is identical to a regular
-- account's — a plain adjustment transaction for the gap, no separate code
-- path. Brokerage is still at version 1.
select set_account_balance('a0000000-0000-0000-0000-000000000022', 12000000, 1);
select is(
  (select account_balance_on('a0000000-0000-0000-0000-000000000022', current_date)),
  12000000::bigint,
  'an investment account''s computed balance matches the newly entered value'
);

select is(
  (select amount_e4 from transactions where account_id = 'a0000000-0000-0000-0000-000000000022' and source = 'adjustment'),
  2000000::bigint,
  'an investment account''s balance edit files an adjustment transaction, exactly like a regular account'
);

-- 7. A second same-day edit on the investment account also just files
-- another adjustment transaction, version-checked like any other write.
select set_account_balance('a0000000-0000-0000-0000-000000000022', 13000000, 2);

select is(
  (select account_balance_on('a0000000-0000-0000-0000-000000000022', current_date)),
  13000000::bigint,
  'a second same-day investment balance edit reaches the newly entered value'
);

-- 8. Idempotency: replaying the same client-supplied id twice does not
-- double the effect (queued-write-replayed-twice safety, same pattern as
-- create_transfer's idempotent leg ids) — and critically, the SECOND call
-- still succeeds even though it passes the same p_expected_version=3 that
-- the first call already advanced past (checking is now at version 4),
-- because the idempotency check runs before the version check.
select set_account_balance('a0000000-0000-0000-0000-000000000021', 2500000, 3, 'b0000000-0000-0000-0000-000000000001');
select set_account_balance('a0000000-0000-0000-0000-000000000021', 2500000, 3, 'b0000000-0000-0000-0000-000000000001');
select is(
  (select count(*) from transactions where id = 'b0000000-0000-0000-0000-000000000001'),
  1::bigint,
  'replaying the same id twice inserts exactly one adjustment transaction'
);

select is(
  (select account_balance_on('a0000000-0000-0000-0000-000000000021', current_date)),
  2500000::bigint,
  'the balance after a duplicate replay still matches the single applied adjustment'
);

-- 9. A genuinely stale version (not a replay — a new id, an old version)
-- reports conflict, applies nothing, and logs a sync_conflicts row.
select is(
  (select conflict from set_account_balance('a0000000-0000-0000-0000-000000000021', 9990000, 1)),
  true,
  'a genuinely stale expected_version reports conflict = true, not a silent apply'
);

select is(
  (select account_balance_on('a0000000-0000-0000-0000-000000000021', current_date)),
  2500000::bigint,
  'a rejected stale-version balance edit leaves the account''s balance untouched'
);

-- 10. Fixture B cannot set fixture A's account balance.
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select throws_like(
  $$ select set_account_balance('a0000000-0000-0000-0000-000000000021', 9990000, 4) $$,
  '%not found or not accessible%',
  'a different owner cannot set another user''s account balance'
);

select * from finish();
rollback;
