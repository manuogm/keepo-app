-- transactions: CHECK constraints, composite FKs, and check_transfer_integrity
-- (the deferred constraint trigger). Fixture A = 11111111-...

\ir _helpers.psql

begin;
select plan(7);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'A Checking', 'EUR', 100);
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'regular', 'A Savings', 'EUR', 100);
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Test Expense');
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000002', auth.uid(), 'income', 'Test Income');

-- amount_not_zero
select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values (
       '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
       'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 0, 'EUR', now()
     ) $$,
  '23514', null,
  'amount_not_zero rejects a zero-amount transaction'
);

-- transfer_xor_category: neither set
select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values (
       '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
       'a0000000-0000-0000-0000-000000000001', null, -10, 'EUR', now()
     ) $$,
  '23514', null,
  'transfer_xor_category rejects neither category_id nor transfer_group_id set'
);

-- sign_matches_category_kind: expense with a positive amount
select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values (
       '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
       'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 10, 'EUR', now()
     ) $$,
  '23514', null,
  'sign_matches_category_kind rejects a positive-amount expense'
);

select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values (
       '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
       'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002', -10, 'EUR', now()
     ) $$,
  '23514', null,
  'sign_matches_category_kind rejects a negative-amount income'
);

insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
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

-- Refused at the insert since 20261015100000: a category that is not the
-- owner's is swapped for the owner's counterpart when there is one (a
-- shared category, or the default), and refused in plain words when there
-- is not — before the composite FK, which stays behind it, ever sees it.
-- B's category here is private, so it has no counterpart on A's side.
--
-- Run as postgres (bypasses RLS on categories/accounts so the rule itself,
-- not a visibility gap, is what's being exercised) — it must refuse this
-- regardless of who's asking.
select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values (
       '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
       'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000099', -10, 'EUR', now()
     ) $$,
  'P0001', null,
  'a transaction cannot reference another owner''s private category (H12, 20261015100000)'
);

-- check_transfer_integrity: exactly 0 or 2 legs, never 1. The trigger is
-- DEFERRABLE INITIALLY DEFERRED, so it only fires at COMMIT — never inside
-- this test file's own transaction unless forced immediate right before
-- the assertion (per _helpers.sql's gotcha list).
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into transactions (owner_id, created_by, account_id, amount_e4, currency, occurred_at, transfer_group_id)
values (
  auth.uid(), auth.uid(), 'a0000000-0000-0000-0000-000000000001', -25, 'EUR', now(),
  '99999999-9999-9999-9999-999999999999'
);

-- 23514 (check_violation), deliberately, since 20261007100000. It was
-- P0001, the default for a plpgsql RAISE — but P0001 is how every RPC here
-- raises a sentence *meant for a person*, and `UserFacingError` shows those
-- verbatim, so an invariant violation reached the screen as raw text with a
-- UUID in it. An integrity failure is a bug, never the user's to read.
select throws_ok(
  $$ set constraints all immediate $$,
  '23514', null,
  'a lone transfer leg (1 of 2) is rejected once the deferred constraint fires'
);

select * from finish();
rollback;
