-- One live category name per (owner, kind), case- and whitespace-
-- insensitively — migration 20260926100000. The migration's other half,
-- the merge of the duplicates that already existed, is a one-shot data
-- fix and is not re-runnable; what has to hold from here on is the index,
-- and that is what this file pins. Fixture A = 11111111-..., fixture B =
-- 22222222-... (supabase/tests/_helpers.psql).

\ir _helpers.psql

begin;
select plan(6);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000420', auth.uid(), 'expense', 'Groceries');

-- 1. The thing the development database had nine of.
select throws_ok(
  $$ insert into categories (owner_id, kind, name)
     values ('11111111-1111-1111-1111-111111111111', 'expense', 'Groceries') $$,
  23505,
  null,
  'a second live expense category called Groceries is refused'
);

-- 2. Case is not a difference. Nine copies of a name nobody can tell
--    apart is the same problem whatever the shift key was doing.
select throws_ok(
  $$ insert into categories (owner_id, kind, name)
     values ('11111111-1111-1111-1111-111111111111', 'expense', 'GROCERIES') $$,
  23505,
  null,
  'case alone does not make a new category'
);

-- 3. Neither is padding, which is what a paste out of a spreadsheet looks
--    like.
select throws_ok(
  $$ insert into categories (owner_id, kind, name)
     values ('11111111-1111-1111-1111-111111111111', 'expense', '  Groceries  ') $$,
  23505,
  null,
  'surrounding whitespace does not make a new category'
);

-- 4. The two kinds are separate namespaces. "Gift" is a plausible expense
--    and a plausible income, and a user who has both has made no mistake.
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000421', auth.uid(), 'income', 'Groceries');
select is(
  (select count(*) from categories where lower(name) = 'groceries' and deleted_at is null),
  2::bigint,
  'the same name may exist once as an expense and once as income'
);

-- 5. A deleted name is free again — the behaviour a user expects after
--    deleting "Groceries" and typing it back, and the reason the index is
--    partial rather than total.
update categories set deleted_at = now() where id = 'c0000000-0000-0000-0000-000000000420';
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000422', auth.uid(), 'expense', 'Groceries');
select is(
  (select count(*) from categories where lower(name) = 'groceries' and kind = 'expense' and deleted_at is null),
  1::bigint,
  'a tombstoned name can be used again'
);

-- 6. The rule is per owner. A household member's identically-named
--    category is theirs, and sharing a name with one of ours is not a
--    collision — the same reasoning `tags_owner_name_idx` is built on.
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-000000000423', auth.uid(), 'expense', 'Groceries');
select is(
  (select count(*) from categories where id = 'c0000000-0000-0000-0000-000000000423'),
  1::bigint,
  'another owner may have a category of the same name and kind'
);

select finish();
rollback;
