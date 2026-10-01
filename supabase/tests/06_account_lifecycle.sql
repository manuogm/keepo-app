-- update_account / archive_account / delete_account: optimistic concurrency,
-- conflict-as-data, the raw-UPDATE grant revocation, and delete's refusal
-- when transactions still reference the account — see
-- supabase/migrations/20260805180000_account_lifecycle.sql. Fixture A =
-- 11111111-...

\ir _helpers.psql

begin;
select plan(14);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000010', auth.uid(), auth.uid(), 'regular', 'Checking', 'EUR', 100);
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000011', auth.uid(), auth.uid(), 'regular', 'Cash', 'EUR', 0);
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
-- bumps version to 2. The opening balance is not one of them: it is ignored
-- since 20261009100000 (the form only echoes it; `set_account_balance` is how
-- a balance changes), so it keeps the 100 it was created with.
select results_eq(
  $$ select conflict, (account).name, (account).opening_balance_e4,
            (account).include_in_total, (account).icon, (account).color, (account).version
     from update_account(
       'a0000000-0000-0000-0000-000000000010', 1,
       'Main Checking', 2500000, false, 'wrench.and.screwdriver.fill', '#123456'
     ) $$,
  $$ values (
       false, 'Main Checking', 100::bigint, false,
       'wrench.and.screwdriver.fill', '#123456', 2
     ) $$,
  'a correct-version edit applies every editable column, leaves the opening balance, and bumps version to 2'
);

-- 3. A stale-version edit reports conflict = true, applies no data change,
-- and leaves exactly one sync_conflicts row.
select is(
  (select conflict from update_account(
    'a0000000-0000-0000-0000-000000000010', 1, 'Renamed', 9990000, true, 'tag.fill', '#ABCDEF'
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

-- 4b. net_worth('total') excludes an archived account's balance (H: the
-- account_lifecycle migration's own comment flagged this as unfinished
-- until account_balances_base/net_worth learned to filter archived_at).
select is(
  net_worth('total'),
  0::bigint,
  'net_worth(''total'') excludes the archived account, counting only the still-active Cash account'
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

-- The refusal itself is unchanged; its wording was rewritten for a person in
-- 20260917100000, which left this assertion pinning a sentence the function
-- no longer says. `p_cascade` is the second answer that migration added, so
-- the refusal is specifically the *no-cascade* one.
select throws_like(
  $$ select * from delete_account('a0000000-0000-0000-0000-000000000010', 4, false) $$,
  '%still has transactions%',
  'delete_account refuses, without a cascade, while non-deleted transactions remain'
);

-- 6. delete_account succeeds on an account with no transactions.
select is(
  (select conflict from delete_account('a0000000-0000-0000-0000-000000000011', 1)),
  false,
  'delete_account soft-deletes an account with no transactions'
);

-- 7–10. A cascade keeps a transfer whole (20261007100000). The half on the
-- deleted account stays as an anchor while its partner's account is live —
-- a lone live leg is what check_transfer_integrity refuses, and the delete
-- used to raise at COMMIT for exactly that reason. Every assertion forces
-- the deferred trigger: without it none of this would have been tested.
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a0000000-0000-0000-0000-000000000012', auth.uid(), auth.uid(), 'regular', 'Old Checking', 'EUR', 0),
  ('a0000000-0000-0000-0000-000000000013', auth.uid(), auth.uid(), 'regular', 'Savings', 'EUR', 0);
select create_transfer(
  'a0000000-0000-0000-0000-000000000012', 'a0000000-0000-0000-0000-000000000013', 300000, null, now(),
  'd0000000-0000-0000-0000-000000000012', 'd0000000-0000-0000-0000-000000000013'
);
set constraints all immediate;
set constraints all deferred;

select delete_account('a0000000-0000-0000-0000-000000000012', 1, true);
select lives_ok(
  $$ set constraints all immediate $$,
  'deleting an account that holds half of a transfer to a live account passes the integrity check at commit'
);
set constraints all deferred;

select is(
  account_balance_on('a0000000-0000-0000-0000-000000000013', current_date),
  300000::bigint,
  'the live account keeps the money that arrived in it'
);

select is(
  (select deleted_at is null from transactions where id = 'd0000000-0000-0000-0000-000000000012'),
  true,
  'the half on the deleted account stays, as the anchor of a whole transfer'
);

-- Once the partner's account is deleted too, there is nothing left to
-- anchor, and the pair goes whole — two legs to zero, never one.
select delete_account('a0000000-0000-0000-0000-000000000013', 1, true);
set constraints all immediate;
set constraints all deferred;
select is(
  (select count(*)::int from transactions
   where transfer_group_id = 'd0000000-0000-0000-0000-000000000012' and deleted_at is null),
  0,
  'a transfer between two deleted accounts is tombstoned whole'
);

select * from finish();
rollback;
