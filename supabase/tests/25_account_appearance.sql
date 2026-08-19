-- accounts.icon/color columns, and counts_toward_fi's removal
-- (migration 20260819100000_remove_fi_add_account_appearance.sql) — same
-- pattern as 20_category_appearance.sql for categories. Fixture A =
-- 11111111-... (base EUR).

\ir _helpers.psql

begin;
select plan(5);

select hasnt_column('public', 'accounts', 'counts_toward_fi', 'counts_toward_fi is gone from accounts');
select has_column('public', 'accounts', 'icon', 'accounts has an icon column');
select has_column('public', 'accounts', 'color', 'accounts has a color column');

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 1. icon/color round-trip through a plain insert.
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4, icon, color)
values (
  'a7000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'Custom Look', 'EUR',
  0, 'creditcard.fill', '#5856D6'
);

select results_eq(
  $$ select icon, color from accounts where id = 'a7000000-0000-0000-0000-000000000001' $$,
  $$ values ('creditcard.fill', '#5856D6') $$,
  'icon and color persist exactly as inserted'
);

-- 2. update_account changes icon/color independently of every other field.
select results_eq(
  $$ select (account).name, (account).icon, (account).color
     from update_account(
       'a7000000-0000-0000-0000-000000000001', 1, 'Custom Look', 0, true,
       'star.fill', '#FF3B30'
     ) $$,
  $$ values ('Custom Look', 'star.fill', '#FF3B30') $$,
  'update_account changes icon/color, leaving name untouched'
);

select * from finish();
rollback;
