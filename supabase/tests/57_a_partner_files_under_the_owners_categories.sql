-- A partner files a row on the owner's account under the owner's category
-- (20261015100000_a_partner_files_under_the_owners_categories.sql).
--
--   1. The partner's insert, as the app sends it (owner = the account's
--      owner, created_by = the partner): a shared category and "Other"
--      become the owner's counterparts; a private one is refused.
--   2. `update_transaction` by the partner does the same.
--   3. Recurring rules, whose owner the server already takes from the
--      account: the same swap, the same refusal.
--   4. Nothing changes for a row on your own account.
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (partner).

\ir _helpers.psql

begin;
select plan(14);

-- ============================================================================
-- Setup, as postgres
-- ============================================================================

insert into households (id) values ('57000000-0000-0000-0000-000000000001');
insert into household_members (household_id, user_id)
values
  ('57000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('57000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a5700000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Joint', 'EUR', 0),
  ('a5700000-0000-0000-0000-000000000011', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'regular', 'B Own', 'EUR', 0);

insert into household_accounts (household_id, account_id)
values ('57000000-0000-0000-0000-000000000001', 'a5700000-0000-0000-0000-000000000001');

-- A shared "Kids" (one row each, one group), B's private "Hobby", A's
-- private "Dining".
insert into categories (id, owner_id, kind, name, shared_group_id)
values
  ('c5700000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Kids',
   '57c00000-0000-0000-0000-000000000001'),
  ('c5700000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'expense', 'Kids',
   '57c00000-0000-0000-0000-000000000001'),
  ('c5700000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'expense', 'Hobby', null),
  ('c5700000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'expense', 'Dining', null);

create temp table defaults on commit drop as
select owner_id, id from categories
where owner_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')
  and kind = 'expense' and is_default and deleted_at is null;
grant select on defaults to authenticated;

-- ============================================================================
-- 1. The partner's insert
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values ('d5700000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', 'a5700000-0000-0000-0000-000000000001',
        'c5700000-0000-0000-0000-000000000002', -1000, 'EUR', now());

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
select 'd5700000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
       '22222222-2222-2222-2222-222222222222', 'a5700000-0000-0000-0000-000000000001', d.id, -2000, 'EUR', now()
from defaults d where d.owner_id = '22222222-2222-2222-2222-222222222222';

select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
             'a5700000-0000-0000-0000-000000000001', 'c5700000-0000-0000-0000-000000000003',
             -3000, 'EUR', now()) $$,
  'Only categories shared with your household can be used on an account that isn''t yours. Pick a shared category.',
  'a private category of the partner''s is refused on the owner''s account, in plain words'
);

-- The owner's own category, which the partner's form keeps when editing
-- the owner's row, is simply the owner's.
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values ('d5700000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222', 'a5700000-0000-0000-0000-000000000001',
        'c5700000-0000-0000-0000-000000000004', -4000, 'EUR', now());

reset role;

select is(
  (select category_id from transactions where id = 'd5700000-0000-0000-0000-000000000001'),
  'c5700000-0000-0000-0000-000000000001'::uuid,
  'a shared category becomes the owner''s row in the same group'
);

select is(
  (select category_id from transactions where id = 'd5700000-0000-0000-0000-000000000002'),
  (select id from defaults where owner_id = '11111111-1111-1111-1111-111111111111'),
  'the partner''s Other becomes the owner''s Other'
);

select is(
  (select created_by from transactions where id = 'd5700000-0000-0000-0000-000000000001'),
  '22222222-2222-2222-2222-222222222222'::uuid,
  'the row still records who entered it'
);

select is(
  (select category_id from transactions where id = 'd5700000-0000-0000-0000-000000000003'),
  'c5700000-0000-0000-0000-000000000004'::uuid,
  'the owner''s own category is kept as it is'
);

-- ============================================================================
-- 2. update_transaction by the partner
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select update_transaction(
  'd5700000-0000-0000-0000-000000000003', 1, 'a5700000-0000-0000-0000-000000000001',
  'c5700000-0000-0000-0000-000000000002', -4000, 'EUR', now()
);

select throws_ok(
  $$ select update_transaction(
       'd5700000-0000-0000-0000-000000000003', 2, 'a5700000-0000-0000-0000-000000000001',
       'c5700000-0000-0000-0000-000000000003', -4000, 'EUR', now()) $$,
  'Only categories shared with your household can be used on an account that isn''t yours. Pick a shared category.',
  'an edit to a private category of the partner''s is refused'
);

reset role;

select is(
  (select category_id from transactions where id = 'd5700000-0000-0000-0000-000000000003'),
  'c5700000-0000-0000-0000-000000000001'::uuid,
  'an edit to a shared category lands on the owner''s row'
);

-- ============================================================================
-- 3. Recurring rules
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- As the app sends it today: the partner as owner. The server takes the
-- owner from the account.
insert into recurring_rules (id, owner_id, created_by, account_id, category_id, amount_e4, currency, frequency, next_due_at)
values ('e5700000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
        '22222222-2222-2222-2222-222222222222', 'a5700000-0000-0000-0000-000000000001',
        'c5700000-0000-0000-0000-000000000002', -5000, 'EUR', 'monthly', now() + interval '1 day');

select throws_ok(
  $$ insert into recurring_rules (owner_id, created_by, account_id, category_id, amount_e4, currency, frequency, next_due_at)
     values ('22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222',
             'a5700000-0000-0000-0000-000000000001', 'c5700000-0000-0000-0000-000000000003',
             -5000, 'EUR', 'monthly', now() + interval '1 day') $$,
  'Only categories shared with your household can be used on an account that isn''t yours. Pick a shared category.',
  'a rule under a private category of the partner''s is refused'
);

select throws_ok(
  $$ update recurring_rules set category_id = 'c5700000-0000-0000-0000-000000000003'
     where id = 'e5700000-0000-0000-0000-000000000001' $$,
  'Only categories shared with your household can be used on an account that isn''t yours. Pick a shared category.',
  'moving the rule to a private category of the partner''s is refused'
);

update recurring_rules set category_id = (select id from defaults where owner_id = '22222222-2222-2222-2222-222222222222')
where id = 'e5700000-0000-0000-0000-000000000001';

reset role;

select is(
  (select owner_id from recurring_rules where id = 'e5700000-0000-0000-0000-000000000001'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'the rule belongs to the account''s owner'
);

select is(
  (select category_id from recurring_rules where id = 'e5700000-0000-0000-0000-000000000001'),
  (select id from defaults where owner_id = '11111111-1111-1111-1111-111111111111'),
  'an edit to the partner''s Other lands on the owner''s Other'
);

-- ============================================================================
-- 4. Your own account
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values ('d5700000-0000-0000-0000-000000000011', '22222222-2222-2222-2222-222222222222',
        '22222222-2222-2222-2222-222222222222', 'a5700000-0000-0000-0000-000000000011',
        'c5700000-0000-0000-0000-000000000003', -1000, 'EUR', now());

-- The owner's Other the partner's row now carries is readable to the
-- partner, so their phone can name it.
select ok(
  can_read_category((select id from defaults where owner_id = '11111111-1111-1111-1111-111111111111')),
  'the owner''s Other, now labelling a row the partner can see, is readable to the partner'
);

reset role;

select is(
  (select category_id from transactions where id = 'd5700000-0000-0000-0000-000000000011'),
  'c5700000-0000-0000-0000-000000000003'::uuid,
  'a private category on your own account is untouched'
);

set constraints all immediate;
select pass('every row above satisfies the owner and category foreign keys');
set constraints all deferred;

select * from finish();
rollback;
