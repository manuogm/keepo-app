-- categories.icon/color columns, and the rename-lock extension to
-- prevent_default_category_deletion (migration 20260813100000). Fixture A
-- = 11111111-...

\ir _helpers.psql

begin;
select plan(6);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into categories (id, owner_id, kind, name, icon, color)
values ('c0000000-0000-0000-0000-000000000030', auth.uid(), 'expense', 'Groceries', 'cart.fill', '#34C759');

-- 1. icon/color round-trip through a plain insert.
select results_eq(
  $$ select icon, color from categories where id = 'c0000000-0000-0000-0000-000000000030' $$,
  $$ values ('cart.fill', '#34C759') $$,
  'icon and color persist exactly as inserted'
);

-- 2. A custom category's name is freely renamable.
update categories set name = 'Food & Drink' where id = 'c0000000-0000-0000-0000-000000000030';
select is(
  (select name from categories where id = 'c0000000-0000-0000-0000-000000000030'),
  'Food & Drink',
  'a non-default, non-system category can be renamed'
);

-- 3. A custom category's icon/color can be changed freely, independent of
-- name.
update categories set icon = 'fork.knife', color = '#FF9500'
where id = 'c0000000-0000-0000-0000-000000000030';
select results_eq(
  $$ select icon, color from categories where id = 'c0000000-0000-0000-0000-000000000030' $$,
  $$ values ('fork.knife', '#FF9500') $$,
  'icon and color can be updated independently of name'
);

-- 4. Renaming the default "Other" category is refused.
select throws_like(
  $$ update categories set name = 'Renamed'
     where owner_id = '11111111-1111-1111-1111-111111111111' and kind = 'expense' and is_default $$,
  '%cannot be renamed%',
  'renaming the default category is refused'
);

-- 5. Renaming a custom category to "Other" is refused — reserved for the
-- one true default (20260814100000_remove_sync_ritual_and_system_categories.sql).
select throws_like(
  $$ update categories set name = 'Other' where id = 'c0000000-0000-0000-0000-000000000030' $$,
  '%reserved%',
  'renaming a custom category to "Other" is refused'
);

-- 6. Changing the default category's icon/color (not its name) still
-- succeeds — the lock is name-specific, not a blanket update refusal.
update categories set icon = 'star.fill', color = '#007AFF'
where owner_id = '11111111-1111-1111-1111-111111111111' and kind = 'expense' and is_default;
select results_eq(
  $$ select icon, color from categories
     where owner_id = '11111111-1111-1111-1111-111111111111' and kind = 'expense' and is_default $$,
  $$ values ('star.fill', '#007AFF') $$,
  'the default category''s icon/color can still change even though its name cannot'
);

select * from finish();
rollback;
