-- transactions: CHECK constraints, composite FKs, and check_transfer_integrity
-- (the deferred constraint trigger). Fixture A = 11111111-...

\ir _helpers.psql

begin;
select plan(7);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a0000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Checking', 'EUR', 100);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a0000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Savings', 'EUR', 100);
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Test Expense');
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000002', auth.uid(), 'income', 'Test Income');

-- amount_not_zero
select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
     values (
       '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
       'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 0, 'EUR', now()
     ) $$,
  '23514', null,
  'amount_not_zero rejects a zero-amount transaction'
);

-- transfer_xor_category: neither set
select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
     values (
       '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
       'a0000000-0000-0000-0000-000000000001', null, -10, 'EUR', now()
     ) $$,
  '23514', null,
  'transfer_xor_category rejects neither category_id nor transfer_group_id set'
);

-- sign_matches_category_kind: expense with a positive amount
select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
     values (
       '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
       'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 10, 'EUR', now()
     ) $$,
  '23514', null,
  'sign_matches_category_kind rejects a positive-amount expense'
);

select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
     values (
       '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
       'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002', -10, 'EUR', now()
     ) $$,
  '23514', null,
  'sign_matches_category_kind rejects a negative-amount income'
);

insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
values (
  '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
  'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', -10, 'EUR', now()
);

select is(
  (select category_kind from transactions
   where account_id = 'a0000000-0000-0000-0000-000000000001'
     and category_id = 'c0000000-0000-0000-0000-000000000001'
   limit 1)::text,
  'expense',
  'set_transaction_derived_columns() populates category_kind from category_id, never the client'
);

-- H12: (category_id, owner_id) -> categories (id, owner_id) composite FK.
-- Fixture B's category id, used in a transaction owned by fixture A, must
-- be rejected — the exact gap the accounts (account_id, owner_id) FK
-- already closed, now closed for categories too.
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000099', auth.uid(), 'expense', 'B''s category');

reset role;
select set_config('request.jwt.claim.sub', '', true);

-- The composite FK is DEFERRABLE INITIALLY DEFERRED (same as accounts'
-- equivalent), so the violation doesn't fire at INSERT — only once
-- something forces the check, here `SET CONSTRAINTS ALL IMMEDIATE`. An
-- explicit SAVEPOINT wraps both statements and is always rolled back
-- afterward: throws_ok's own internal savepoint only undoes the immediate-
-- check statement itself (reverting the constraint mode back to deferred),
-- NOT the earlier INSERT — without this outer savepoint, the bad row and
-- its still-deferred violation would leak into every later assertion in
-- this file (confirmed empirically: it corrupted the transfer-leg test
-- below before this fix, which had nothing to do with categories).
savepoint h12_check;

-- Run as postgres (bypasses RLS on categories/accounts so the FK itself,
-- not a visibility gap, is what's being exercised) — the FK must reject
-- this regardless of who's asking.
insert into transactions (owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
values (
  '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
  'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000099', -10, 'EUR', now()
);

select throws_ok(
  $$ set constraints all immediate $$,
  '23503', null,
  'a transaction cannot reference another owner''s category (H12 composite FK)'
);

rollback to savepoint h12_check;

-- check_transfer_integrity: exactly 0 or 2 legs, never 1. The trigger is
-- DEFERRABLE INITIALLY DEFERRED, so it only fires at COMMIT — never inside
-- this test file's own transaction unless forced immediate right before
-- the assertion (per _helpers.sql's gotcha list).
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into transactions (owner_id, created_by, account_id, amount, currency, occurred_at, transfer_group_id)
values (
  auth.uid(), auth.uid(), 'a0000000-0000-0000-0000-000000000001', -25, 'EUR', now(),
  '99999999-9999-9999-9999-999999999999'
);

-- P0001 ("raise_exception"), not 23514 — check_transfer_integrity is a
-- plpgsql RAISE EXCEPTION, not a declarative CHECK constraint, so it gets
-- Postgres's generic user-raised-exception code rather than check_violation.
select throws_ok(
  $$ set constraints all immediate $$,
  'P0001', null,
  'a lone transfer leg (1 of 2) is rejected once the deferred constraint fires'
);

select * from finish();
rollback;
