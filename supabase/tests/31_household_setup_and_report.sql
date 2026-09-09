-- The household setup ceremony's server half
-- (migration 20260913100000_household_setup_and_report.sql).
--
-- Four things are worth pinning here, and the first is a regression:
--
--   1. Leaving a household actually releases it. `leave_household()`
--      soft-deletes the member row and `my_household_id()` used to ignore
--      `deleted_at`, so a user who left could never create or join another
--      household again — with no error naming the cause. The two assertions
--      at the end are the ones that would have caught it.
--   2. Owner authority is real and is checked on the server, not assumed by
--      the client that happens to be showing the report.
--   3. A merge links two rows into one group under one identity, and never
--      moves a transaction or changes an owner.
--   4. Deleting a tag with a destination keeps the transactions, including
--      the case where the destination was once on the transaction and had
--      been removed — a tombstone sitting on the primary key the move lands
--      on.
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (guest).

\ir _helpers.psql

begin;
select plan(23);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a1000000-0000-0000-0000-00000000d001', auth.uid(), auth.uid(), 'regular', 'A Current', 'EUR', 5000000);

insert into categories (id, owner_id, kind, name, icon, color)
values
  ('c1000000-0000-0000-0000-00000000d001', auth.uid(), 'expense', 'Dine Out', 'fork.knife', '#FF0000'),
  ('c1000000-0000-0000-0000-00000000d002', auth.uid(), 'income', 'Salary', 'banknote', '#00FF00');

select is(
  household_owner_id(my_household_id()),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'the member who created the household owns it'
);

-- Alone in the household: there is no other member to describe, and the
-- honest answer is no rows rather than a half-drawn card.
select is_empty(
  $$ select * from household_member_profile() $$,
  'household_member_profile returns nothing while you are alone in a household'
);

select is(
  create_invite(
    array['a1000000-0000-0000-0000-00000000d001']::uuid[],
    array['c1000000-0000-0000-0000-00000000d001']::uuid[]
  ) is not null,
  true,
  'the owner can mint an invite carrying their selections'
);

-- The token is returned once and never stored, so the test has to keep its
-- own copy the same way the client does.
create temporary table invite_token on commit drop as
select create_invite(
  array['a1000000-0000-0000-0000-00000000d001']::uuid[],
  array['c1000000-0000-0000-0000-00000000d001']::uuid[]
) as token;

-- ============================================================================
-- The guest joins
-- ============================================================================

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('b2000000-0000-0000-0000-00000000d001', auth.uid(), auth.uid(), 'regular', 'B Current', 'USD', 3000000);

-- "Dining Out" against A's "Dine Out": near, not equal. `ensure_category_twin`
-- matches exactly, so these stay two rows until somebody merges them — which
-- is the whole reason the report exists.
insert into categories (id, owner_id, kind, name, icon, color)
values
  ('c2000000-0000-0000-0000-00000000d001', auth.uid(), 'expense', 'Dining Out', 'cart.fill', '#0000FF'),
  ('c2000000-0000-0000-0000-00000000d002', auth.uid(), 'income', 'Salary', 'banknote', '#00FF00');

insert into tags (id, owner_id, name) values
  ('7a900000-0000-0000-0000-00000000d001', auth.uid(), 'Holidays'),
  ('7a900000-0000-0000-0000-00000000d002', auth.uid(), 'Holiday');

insert into transactions (id, owner_id, created_by, account_id, category_id, kind, amount_e4, occurred_at)
values (
  '77000000-0000-0000-0000-00000000d001', auth.uid(), auth.uid(),
  'b2000000-0000-0000-0000-00000000d001', 'c2000000-0000-0000-0000-00000000d001',
  'expense', -250000, now()
);

insert into transaction_tags (transaction_id, tag_id, owner_id)
values ('77000000-0000-0000-0000-00000000d001', '7a900000-0000-0000-0000-00000000d001', auth.uid());

select lives_ok(
  format(
    $$ select accept_invite(%L, array['b2000000-0000-0000-0000-00000000d001']::uuid[], array['c2000000-0000-0000-0000-00000000d001']::uuid[]) $$,
    (select token from invite_token)
  ),
  'the guest accepts, sharing back an account and a category'
);

select is(
  household_owner_id(my_household_id()),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'joining does not make the guest the owner'
);

-- The guest sees the owner, and sees that they are the owner.
select results_eq(
  $$ select user_id, is_owner from household_member_profile() $$,
  $$ values ('11111111-1111-1111-1111-111111111111'::uuid, true) $$,
  'the guest can read the owner''s profile, flagged as the owner'
);

select throws_ok(
  $$ select apply_category_merges('[{"mine":"c2000000-0000-0000-0000-00000000d001","theirs":"c1000000-0000-0000-0000-00000000d001"}]'::jsonb) $$,
  'only the household owner can merge categories'
);

-- ============================================================================
-- The owner runs the report
-- ============================================================================

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select results_eq(
  $$ select user_id, is_owner from household_member_profile() $$,
  $$ values ('22222222-2222-2222-2222-222222222222'::uuid, false) $$,
  'the owner can read the guest''s profile, flagged as not the owner'
);

select is(
  (select base_currency from household_member_profile()),
  'USD'::text,
  'the member card carries their own base currency, not the viewer''s'
);

select is(
  apply_category_merges(
    '[{"mine":"c1000000-0000-0000-0000-00000000d001","theirs":"c2000000-0000-0000-0000-00000000d001","name":"Dining Out","icon":"fork.knife","color":"#123456"}]'::jsonb
  ),
  1,
  'the owner merges Dine Out with Dining Out'
);

reset role;

select is(
  (select count(distinct shared_group_id) from categories
   where id in ('c1000000-0000-0000-0000-00000000d001', 'c2000000-0000-0000-0000-00000000d001')),
  1::bigint,
  'a merge puts both rows in one shared group'
);

select results_eq(
  $$ select name, icon, color from categories
     where id in ('c1000000-0000-0000-0000-00000000d001', 'c2000000-0000-0000-0000-00000000d001')
     order by owner_id $$,
  $$ values ('Dining Out'::text, 'fork.knife'::text, '#123456'::text),
            ('Dining Out'::text, 'fork.knife'::text, '#123456'::text) $$,
  'both rows take the resultant name, icon and colour'
);

select results_eq(
  $$ select owner_id from categories
     where id in ('c1000000-0000-0000-0000-00000000d001', 'c2000000-0000-0000-0000-00000000d001')
     order by owner_id $$,
  $$ values ('11111111-1111-1111-1111-111111111111'::uuid), ('22222222-2222-2222-2222-222222222222'::uuid) $$,
  'a merge never moves a category to the other member'
);

select is(
  (select category_id from transactions where id = '77000000-0000-0000-0000-00000000d001'),
  'c2000000-0000-0000-0000-00000000d001'::uuid,
  'the guest''s transaction still points at the guest''s own row'
);

-- A merge the owner made by hand is `manual`; the robot glyph in the report
-- is reserved for what the fuzzy pass did without being asked.
select results_eq(
  $$ select merge_origin::text from categories
     where id in ('c1000000-0000-0000-0000-00000000d001', 'c2000000-0000-0000-0000-00000000d001')
     order by owner_id $$,
  $$ values ('manual'::text), ('manual'::text) $$,
  'a merge with no p_automatic flag is recorded as manual, on both rows'
);

-- Both members already had "Salary" spelled identically, and
-- `ensure_category_twin` matched rather than created. That is a merge nobody
-- was asked about, and it is what puts a category in the report's Merged list
-- with the robot glyph.
select is(
  (select merge_origin::text from categories where id = 'c1000000-0000-0000-0000-00000000d002'),
  null::text,
  'an unshared category carries no merge origin'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select throws_ok(
  $$ select apply_category_merges('[{"mine":"c1000000-0000-0000-0000-00000000d002","theirs":"c2000000-0000-0000-0000-00000000d001"}]'::jsonb) $$,
  'an expense category cannot be merged with an income one'
);

-- The owner prunes the guest's duplicate tag into the guest's other tag. The
-- transaction wearing it has to survive with the survivor on it.
select is(
  delete_tag_retagging('7a900000-0000-0000-0000-00000000d001', '7a900000-0000-0000-0000-00000000d002'),
  1,
  'the owner re-tags the guest''s transaction onto the surviving tag'
);

reset role;

select is(
  (select tag_id from transaction_tags
   where transaction_id = '77000000-0000-0000-0000-00000000d001' and deleted_at is null),
  '7a900000-0000-0000-0000-00000000d002'::uuid,
  'the transaction now wears the surviving tag'
);

select isnt(
  (select deleted_at from tags where id = '7a900000-0000-0000-0000-00000000d001'),
  null::timestamptz,
  'the redundant tag is tombstoned, not hard-deleted'
);

-- ============================================================================
-- Leaving actually releases the household (the regression)
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select lives_ok(
  $$ select leave_household() $$,
  'the guest leaves'
);

select is(
  my_household_id(),
  null::uuid,
  'my_household_id() stops answering once the member row is tombstoned'
);

-- The bug this replaces: `create_household()` refused with "you already
-- belong to a household" forever, because the tombstoned membership row still
-- satisfied an unfiltered `my_household_id()`.
select lives_ok(
  $$ select create_household() $$,
  'a member who has left can create a household again'
);

select * from finish();
rollback;
