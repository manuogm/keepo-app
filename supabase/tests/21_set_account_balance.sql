-- set_account_balance: see supabase/migrations/20260814200000_
-- set_account_balance.sql. Fixture A = 11111111-...

\ir _helpers.psql

begin;
select plan(12);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a0000000-0000-0000-0000-000000000021', auth.uid(), auth.uid(), 'ledger', 'checking', 'Checking', 'EUR', 100);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a0000000-0000-0000-0000-000000000022', auth.uid(), auth.uid(), 'valuation', 'investment', 'Brokerage', 'EUR', 0);

-- Backdated to yesterday, not today: `now()` is frozen for this whole test
-- transaction (_helpers.psql's own documented gotcha), so a same-day
-- snapshot inserted here and one inserted later by set_account_balance
-- would carry an identical created_at too — as_of desc alone should be
-- what disambiguates the common case, and created_at is only the tiebreak
-- for the genuine same-day case, exercised separately below.
insert into balance_snapshots (account_id, currency, as_of, value, created_by)
values ('a0000000-0000-0000-0000-000000000022', 'EUR', current_date - 1, 1000, auth.uid());

-- 1. Raising a ledger account's balance creates a positive adjustment
-- transaction for exactly the gap.
select set_account_balance('a0000000-0000-0000-0000-000000000021', 150);
select is(
  (select amount from transactions where account_id = 'a0000000-0000-0000-0000-000000000021' and source = 'adjustment'),
  50::numeric,
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
  150::numeric,
  'the ledger account''s computed balance matches the entered value'
);

-- 4. Lowering the balance creates a negative (expense) adjustment.
select set_account_balance('a0000000-0000-0000-0000-000000000021', 100);
select is(
  (select account_balance_on('a0000000-0000-0000-0000-000000000021', current_date)),
  100::numeric,
  'lowering the balance creates a negative adjustment reaching the new value'
);

-- 5. Setting the balance to its current value is a no-op — no zero-amount
-- transaction (the DB's own amount_not_zero CHECK would reject one anyway).
select is(
  (select transaction_id from set_account_balance('a0000000-0000-0000-0000-000000000021', 100)),
  null::uuid,
  'setting a ledger balance to its current value creates no transaction'
);

select is(
  (select count(*) from transactions where account_id = 'a0000000-0000-0000-0000-000000000021' and source = 'adjustment'),
  2::bigint,
  'no-op balance set left the adjustment count unchanged'
);

-- 6. A valuation account's balance edit writes a new snapshot, not a
-- transaction.
select set_account_balance('a0000000-0000-0000-0000-000000000022', 1200);
select is(
  (select account_balance_on('a0000000-0000-0000-0000-000000000022', current_date)),
  1200::numeric,
  'a valuation account''s computed balance matches the newly entered value'
);

select is(
  (select count(*) from transactions where account_id = 'a0000000-0000-0000-0000-000000000022'),
  0::bigint,
  'a valuation balance edit never creates a transaction'
);

-- 7. Same-day tiebreak: two snapshots sharing an `as_of` (editing the
-- balance twice in one day, now realistic thanks to this RPC) resolve to
-- the later `created_at`, not an unspecified row. `now()` is frozen for
-- this whole transaction — including for step 6's own set_account_balance
-- call above, which already wrote a same-day snapshot at the frozen
-- now() — so both rows here are inserted with an explicit `created_at`
-- strictly after that frozen instant, not just after each other.
insert into balance_snapshots (account_id, currency, as_of, value, created_by, created_at)
values ('a0000000-0000-0000-0000-000000000022', 'EUR', current_date, 1150, auth.uid(), now() + interval '1 minute');
insert into balance_snapshots (account_id, currency, as_of, value, created_by, created_at)
values ('a0000000-0000-0000-0000-000000000022', 'EUR', current_date, 1300, auth.uid(), now() + interval '2 minutes');

select is(
  (select account_balance_on('a0000000-0000-0000-0000-000000000022', current_date)),
  1300::numeric,
  'two same-day snapshots resolve to the one with the later created_at'
);

-- 8. Idempotency: replaying the same client-supplied id twice does not
-- double the effect (queued-write-replayed-twice safety, same pattern as
-- create_transfer's idempotent leg ids).
select set_account_balance('a0000000-0000-0000-0000-000000000021', 250, 'b0000000-0000-0000-0000-000000000001');
select set_account_balance('a0000000-0000-0000-0000-000000000021', 250, 'b0000000-0000-0000-0000-000000000001');
select is(
  (select count(*) from transactions where id = 'b0000000-0000-0000-0000-000000000001'),
  1::bigint,
  'replaying the same id twice inserts exactly one adjustment transaction'
);

select is(
  (select account_balance_on('a0000000-0000-0000-0000-000000000021', current_date)),
  250::numeric,
  'the balance after a duplicate replay still matches the single applied adjustment'
);

-- 9. Fixture B cannot set fixture A's account balance.
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select throws_like(
  $$ select set_account_balance('a0000000-0000-0000-0000-000000000021', 999) $$,
  '%not found or not accessible%',
  'a different owner cannot set another user''s account balance'
);

select * from finish();
rollback;
