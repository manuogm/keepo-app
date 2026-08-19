-- delete_category_and_reassign: see supabase/migrations/20260812100000_
-- category_delete_reassign.sql. Fixture A = 11111111-...

\ir _helpers.psql

begin;
select plan(8);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-000000000020', auth.uid(), auth.uid(), 'regular', 'Checking', 'EUR', 100);

insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000020', auth.uid(), 'expense', 'Groceries');

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values
  ('d0000000-0000-0000-0000-000000000020', auth.uid(), auth.uid(),
   'a0000000-0000-0000-0000-000000000020', 'c0000000-0000-0000-0000-000000000020', -10, 'EUR', now()),
  ('d0000000-0000-0000-0000-000000000021', auth.uid(), auth.uid(),
   'a0000000-0000-0000-0000-000000000020', 'c0000000-0000-0000-0000-000000000020', -20, 'EUR', now());

-- 1. Deleting a category with two transactions reassigns both and reports
-- the count.
select is(
  (select delete_category_and_reassign('c0000000-0000-0000-0000-000000000020')),
  2,
  'delete_category_and_reassign reassigns and reports every affected transaction'
);

-- 2. The category itself is soft-deleted.
select isnt(
  (select deleted_at from categories where id = 'c0000000-0000-0000-0000-000000000020'),
  null,
  'the deleted category carries a deleted_at tombstone'
);

-- 3. Both transactions now point at the owner's default expense category,
-- not the deleted one.
select is(
  (select array_agg(distinct category_id) from transactions
   where id in ('d0000000-0000-0000-0000-000000000020', 'd0000000-0000-0000-0000-000000000021')),
  (select array[id] from categories where owner_id = auth.uid() and kind = 'expense' and is_default),
  'both transactions were reassigned to the default Other (expense) category'
);

-- 4. category_kind stayed consistent (set_transaction_derived_columns
-- re-derives it from the new category_id) — sign_matches_category_kind
-- would otherwise have rejected the UPDATE outright.
select is(
  (select category_kind from transactions where id = 'd0000000-0000-0000-0000-000000000020'),
  'expense'::category_kind,
  'category_kind was re-derived from the reassigned category, not left stale'
);

-- 5. Deleting the default "Other" category itself is refused.
select throws_like(
  $$ select delete_category_and_reassign(
       (select id from categories where owner_id = '11111111-1111-1111-1111-111111111111'
        and kind = 'expense' and is_default)
     ) $$,
  '%cannot be deleted%',
  'delete_category_and_reassign refuses the default category'
);

-- 6. Creating a second category named "Other" (any case, plural or not) is
-- refused — it's reserved for the one true default, per
-- 20260814100000_remove_sync_ritual_and_system_categories.sql.
select throws_like(
  $$ insert into categories (owner_id, kind, name) values (auth.uid(), 'expense', 'others') $$,
  '%reserved%',
  'a custom category cannot be named "Other"/"Others"'
);

-- 7. A category with zero transactions still deletes cleanly, reporting 0.
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000021', auth.uid(), 'income', 'Freelance');

select is(
  (select delete_category_and_reassign('c0000000-0000-0000-0000-000000000021')),
  0,
  'a category with no transactions deletes cleanly and reports zero reassigned'
);

-- 8. Fixture B cannot delete fixture A's category — not found/accessible.
-- Inserted while still fixture A (categories_insert's WITH CHECK requires
-- owner_id = auth.uid()), then the ownership check is exercised after
-- switching identities below.
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000022', auth.uid(), 'expense', 'Not Yours');

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select throws_like(
  $$ select delete_category_and_reassign('c0000000-0000-0000-0000-000000000022') $$,
  '%not found or not accessible%',
  'a different owner cannot delete a category they do not own'
);

select * from finish();
rollback;
