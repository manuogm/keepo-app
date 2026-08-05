-- update_transaction / update_transfer / delete_transaction / delete_transfer:
-- optimistic concurrency, conflict-as-data (never an exception for a version
-- mismatch — see supabase/migrations/20260805134921_transaction_editing.sql),
-- and the raw-UPDATE grant revocation. Fixture A = 11111111-...

\ir _helpers.psql

begin;
select plan(11);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a0000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Checking', 'EUR', 100);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a0000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Savings', 'EUR', 100);
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Test Expense');

insert into transactions (id, owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
values (
  'd0000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(),
  'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', -10, 'EUR', now()
);

-- 1. The raw UPDATE grant is gone — this is the whole point of revoking it
-- in Phase 3, re-confirmed here rather than trusted from the migration.
select throws_ok(
  $$ update transactions set amount = -20 where id = 'd0000000-0000-0000-0000-000000000001' $$,
  null::char(5), null,
  'authenticated has no raw UPDATE grant on transactions'
);

-- 2. A correct-version edit succeeds and bumps version to 2.
select results_eq(
  $$ select conflict, (transaction).amount, (transaction).version
     from update_transaction(
       'd0000000-0000-0000-0000-000000000001', 1,
       'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
       -20, 'EUR', now(), null
     ) $$,
  $$ values (false, -20.0000::numeric, 2) $$,
  'a correct-version edit succeeds, applies the new amount, and bumps version to 2'
);

-- 3. A stale-version edit reports conflict = true, applies no data change,
-- and leaves exactly one sync_conflicts row.
select is(
  (select conflict from update_transaction(
    'd0000000-0000-0000-0000-000000000001', 1,
    'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
    -999, 'EUR', now(), null
  )),
  true,
  'a stale-version edit reports conflict = true, not an exception'
);

select is(
  (select amount from transactions where id = 'd0000000-0000-0000-0000-000000000001'),
  -20.0000,
  'a rejected stale-version edit leaves the row''s data untouched'
);

select is(
  (select count(*) from sync_conflicts where row_id = 'd0000000-0000-0000-0000-000000000001'),
  1::bigint,
  'the stale edit left exactly one sync_conflicts row'
);

-- 4. Editing someone else's transaction raises (not a conflict — a real
-- access error, nothing to audit).
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select throws_ok(
  $$ select * from update_transaction(
       'd0000000-0000-0000-0000-000000000001', 2,
       'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
       -1, 'EUR', now(), null
     ) $$,
  null::char(5), null,
  'editing another owner''s transaction raises, not a conflict'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 5. Editing a deleted transaction raises.
select delete_transaction('d0000000-0000-0000-0000-000000000001', 2);

select throws_ok(
  $$ select * from update_transaction(
       'd0000000-0000-0000-0000-000000000001', 3,
       'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
       -1, 'EUR', now(), null
     ) $$,
  null::char(5), null,
  'editing a deleted transaction raises'
);

-- 6. update_transaction on a transfer leg raises with a redirect message —
-- the client is pointed at update_transfer instead of getting a generic
-- "not accessible."
select create_transfer('a0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 15);

select throws_like(
  $$ select * from update_transaction(
       (select id from transactions
        where account_id = 'a0000000-0000-0000-0000-000000000001'
          and transfer_group_id is not null limit 1),
       1, 'a0000000-0000-0000-0000-000000000001', null, -15, 'EUR', now(), null
     ) $$,
  '%is a transfer leg%',
  'update_transaction on a transfer leg redirects the caller to update_transfer'
);

-- 7. update_transfer applies no writes to either leg if either version is
-- stale — never a one-leg-updated, one-leg-not partial write.
select is(
  (select conflict from update_transfer(
    (select transfer_group_id from transactions
     where account_id = 'a0000000-0000-0000-0000-000000000001' and transfer_group_id is not null limit 1),
    999, 1, 20, 20, now()
  )),
  true,
  'update_transfer with one stale leg version reports conflict = true'
);

select is(
  (select amount from transactions
    where account_id = 'a0000000-0000-0000-0000-000000000001' and transfer_group_id is not null),
  -15.0000,
  'update_transfer applied no write to either leg when one version was stale'
);

-- 8. delete_transfer never leaves a 1-leg group.
select delete_transfer(
  (select transfer_group_id from transactions
   where account_id = 'a0000000-0000-0000-0000-000000000001' and transfer_group_id is not null limit 1),
  1, 1
);

select is(
  (select count(*) from transactions
    where transfer_group_id = (
      select transfer_group_id from transactions
      where account_id = 'a0000000-0000-0000-0000-000000000001' and transfer_group_id is not null
      limit 1
    ) and deleted_at is null),
  0::bigint,
  'delete_transfer soft-deletes both legs together, never leaving one behind'
);

select * from finish();
rollback;
