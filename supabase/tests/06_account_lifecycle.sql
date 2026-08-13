-- update_account / archive_account / delete_account: optimistic concurrency,
-- conflict-as-data, the raw-UPDATE grant revocation, and delete's refusal
-- when transactions still reference the account — see
-- supabase/migrations/20260805180000_account_lifecycle.sql. Fixture A =
-- 11111111-...

\ir _helpers.psql

begin;
select plan(9);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000010', auth.uid(), auth.uid(), 'ledger', 'checking', 'Checking', 'EUR', 100);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000011', auth.uid(), auth.uid(), 'ledger', 'cash', 'Cash', 'EUR', 0);
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000010', auth.uid(), 'expense', 'Test Expense');

-- 1. The raw UPDATE grant is gone — re-confirmed here rather than trusted
-- from the migration, same convention as 04_transaction_editing.sql.
select throws_ok(
  $$ update accounts set name = 'Hacked' where id = 'a0000000-0000-0000-0000-000000000010' $$,
  null::char(5), null,
  'authenticated has no raw UPDATE grant on accounts'
);

-- 2. A correct-version edit succeeds, applies every editable column, and
-- bumps version to 2.
select results_eq(
  $$ select conflict, (account).name, (account).subtype, (account).opening_balance_e4,
            (account).include_in_total, (account).counts_toward_fi, (account).version
     from update_account(
       'a0000000-0000-0000-0000-000000000010', 1,
       'Main Checking', 'checking', 2500000, false, false
     ) $$,
  $$ values (false, 'Main Checking', 'checking'::account_subtype, 2500000::bigint, false, false, 2) $$,
  'a correct-version edit applies every editable column and bumps version to 2'
);

-- 3. A stale-version edit reports conflict = true, applies no data change,
-- and leaves exactly one sync_conflicts row.
select is(
  (select conflict from update_account(
    'a0000000-0000-0000-0000-000000000010', 1, 'Renamed', 'checking', 9990000, true, true
  )),
  true,
  'a stale-version edit reports conflict = true, not an exception'
);

select is(
  (select name from accounts where id = 'a0000000-0000-0000-0000-000000000010'),
  'Main Checking',
  'a rejected stale-version edit leaves the row''s data untouched'
);

select is(
  (select count(*) from sync_conflicts where row_id = 'a0000000-0000-0000-0000-000000000010'),
  1::bigint,
  'the stale edit left exactly one sync_conflicts row'
);

-- 4. archive_account toggles archived_at both ways, version-checked like
-- every other write RPC.
select is(
  (select (account).archived_at is not null from archive_account(
    'a0000000-0000-0000-0000-000000000010', 2, true
  )),
  true,
  'archive_account(true) sets archived_at'
);

select is(
  (select (account).archived_at is null from archive_account(
    'a0000000-0000-0000-0000-000000000010', 3, false
  )),
  true,
  'archive_account(false) clears archived_at again'
);

-- 5. delete_account refuses (raises, nothing to audit) while non-deleted
-- transactions still reference the account.
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (
  'd0000000-0000-0000-0000-000000000010', auth.uid(), auth.uid(),
  'a0000000-0000-0000-0000-000000000010', 'c0000000-0000-0000-0000-000000000010', -100000, 'EUR', now()
);

select throws_like(
  $$ select * from delete_account('a0000000-0000-0000-0000-000000000010', 4) $$,
  '%archive it instead%',
  'delete_account refuses while the account still has non-deleted transactions'
);

-- 6. delete_account succeeds on an account with no transactions.
select is(
  (select conflict from delete_account('a0000000-0000-0000-0000-000000000011', 1)),
  false,
  'delete_account soft-deletes an account with no transactions'
);

select * from finish();
rollback;
