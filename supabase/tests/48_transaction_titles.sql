-- A transaction can have a title (20261005100000_a_transaction_has_a_title.sql).
--
-- Four things are under test:
--   1. The shape: "no title" is always null, never '' or whitespace.
--   2. Every path that writes or copies a transaction carries the title —
--      and capture never invents one.
--   3. A title never trains merchant_category_map.
--   4. capture_transaction's category hint is consulted AFTER a learned
--      merchant and BEFORE the default, and only when it names a live
--      category of the right kind that the owner owns.
--
-- Fixture A = 11111111-..., fixture B = 22222222-....
-- now() is frozen for the whole file, so every capture below counts toward
-- one rate-limit window (20/minute). There are six.

\ir _helpers.psql

begin;
select plan(25);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a4800000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'A Checking', 'EUR', 10000000),
  ('a4800000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'regular', 'A Savings', 'EUR', 0);
insert into categories (id, owner_id, kind, name)
values
  ('c4800000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Coffee'),
  ('c4800000-0000-0000-0000-000000000002', auth.uid(), 'expense', 'Dining'),
  ('c4800000-0000-0000-0000-000000000003', auth.uid(), 'income', 'Refunds'),
  ('c4800000-0000-0000-0000-000000000004', auth.uid(), 'expense', 'Gone');
update categories set deleted_at = now() where id = 'c4800000-0000-0000-0000-000000000004';

select map_card('card-48', 'a4800000-0000-0000-0000-000000000001');

-- ============================================================================
-- 1. The shape
-- ============================================================================

select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, title)
     values (auth.uid(), auth.uid(), 'a4800000-0000-0000-0000-000000000001',
       'c4800000-0000-0000-0000-000000000001', -45000, 'EUR', now(), '   ') $$,
  '23514', null,
  'a blank title is refused — no title is null, never whitespace'
);

select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, title)
     values (auth.uid(), auth.uid(), 'a4800000-0000-0000-0000-000000000001',
       'c4800000-0000-0000-0000-000000000001', -45000, 'EUR', now(), ' Coffee') $$,
  '23514', null,
  'an untrimmed title is refused'
);

select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, title)
     values (auth.uid(), auth.uid(), 'a4800000-0000-0000-0000-000000000001',
       'c4800000-0000-0000-0000-000000000001', -45000, 'EUR', now(), repeat('x', 81)) $$,
  '23514', null,
  'a title over 80 characters is refused'
);

select throws_ok(
  $$ insert into recurring_rules (account_id, category_id, amount_e4, currency, frequency, next_due_at, title,
       created_by)
     values ('a4800000-0000-0000-0000-000000000001', 'c4800000-0000-0000-0000-000000000001', -45000, 'EUR',
       'monthly', current_date, '', auth.uid()) $$,
  '23514', null,
  'a recurring rule refuses an empty title the same way'
);

-- ============================================================================
-- 2. Manual entry and editing
-- ============================================================================

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, title)
values ('d4800000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'a4800000-0000-0000-0000-000000000001',
  'c4800000-0000-0000-0000-000000000002', -120000, 'EUR', now(), 'Coffee with Beth');

select is(
  (select title from transactions_with_details where transaction_id = 'd4800000-0000-0000-0000-000000000001'),
  'Coffee with Beth',
  'a manually inserted title reaches transactions_with_details'
);

select update_transaction(
  'd4800000-0000-0000-0000-000000000001', 1, 'a4800000-0000-0000-0000-000000000001',
  'c4800000-0000-0000-0000-000000000002', -120000, 'EUR', now(), null, null, null, null, '  Lunch  '
);

select is(
  (select title from transactions where id = 'd4800000-0000-0000-0000-000000000001'),
  'Lunch',
  'update_transaction trims what it is given rather than tripping the CHECK'
);

select update_transaction(
  'd4800000-0000-0000-0000-000000000001', 2, 'a4800000-0000-0000-0000-000000000001',
  'c4800000-0000-0000-0000-000000000002', -120000, 'EUR', now(), null, null, null, null, '   '
);

select is(
  (select title from transactions where id = 'd4800000-0000-0000-0000-000000000001'),
  null::text,
  'a whitespace-only title clears it to null'
);

-- ============================================================================
-- 3. Transfers — both legs, like notes
-- ============================================================================

select create_transfer(
  'a4800000-0000-0000-0000-000000000001', 'a4800000-0000-0000-0000-000000000002', 50000, null, now(),
  'd4800000-0000-0000-0000-0000000000f1', 'd4800000-0000-0000-0000-0000000000f2', null, 'Rainy day'
);

select is(
  (select count(*) from transactions
   where id in ('d4800000-0000-0000-0000-0000000000f1', 'd4800000-0000-0000-0000-0000000000f2')
     and title = 'Rainy day'),
  2::bigint,
  'create_transfer writes the title onto both legs'
);

select update_transfer(
  (select transfer_group_id from transactions where id = 'd4800000-0000-0000-0000-0000000000f1'),
  1, 1, 50000, 50000, now(), null, 'Holiday fund'
);

select is(
  (select count(*) from transactions
   where id in ('d4800000-0000-0000-0000-0000000000f1', 'd4800000-0000-0000-0000-0000000000f2')
     and title = 'Holiday fund'),
  2::bigint,
  'update_transfer rewrites the title on both legs'
);

-- ============================================================================
-- 4. Capture never titles; review can; and a title never trains the map
-- ============================================================================

select capture_transaction(
  'd4800000-0000-0000-0000-0000000000c1', 'card-48', 'STARBUCKS STORE 00042', 'STARBUCKS',
  45000, now(), 'ext-48-1'
);

select is(
  (select title from transactions where id = 'd4800000-0000-0000-0000-0000000000c1'),
  null::text,
  'a capture never gets a title of its own'
);

select review_capture_transaction(
  'd4800000-0000-0000-0000-0000000000c1', 1, 'a4800000-0000-0000-0000-000000000001',
  'c4800000-0000-0000-0000-000000000001', -45000, 'EUR', now(), 'STARBUCKS STORE 00042', null, null, null,
  'Flat white'
);

select is(
  (select title from transactions where id = 'd4800000-0000-0000-0000-0000000000c1'),
  'Flat white',
  'review_capture_transaction stores the title the user typed while reviewing'
);

select is(
  (select category_id from merchant_category_map where owner_id = auth.uid() and merchant_pattern = 'STARBUCKS'),
  'c4800000-0000-0000-0000-000000000001'::uuid,
  'reviewing still trains the merchant map on the merchant'
);

select is(
  (select count(*) from merchant_category_map
   where owner_id = auth.uid() and upper(merchant_pattern) like '%FLAT WHITE%'),
  0::bigint,
  'but never on the title'
);

-- ============================================================================
-- 5. The category hint
-- ============================================================================

-- (a) Nothing learned for this merchant: a valid hint wins over the default.
select capture_transaction(
  'd4800000-0000-0000-0000-0000000000c2', 'card-48', 'BLUE BOTTLE', 'BLUE BOTTLE',
  45000, now(), 'ext-48-2', null, null, 'c4800000-0000-0000-0000-000000000001'
);

select is(
  (select category_id from transactions where id = 'd4800000-0000-0000-0000-0000000000c2'),
  'c4800000-0000-0000-0000-000000000001'::uuid,
  'with nothing learned, a valid hint is used instead of the default'
);

-- (b) A learned merchant beats the hint — same order as the device.
select capture_transaction(
  'd4800000-0000-0000-0000-0000000000c3', 'card-48', 'STARBUCKS STORE 00099', 'STARBUCKS',
  45000, now(), 'ext-48-3', null, null, 'c4800000-0000-0000-0000-000000000002'
);

select is(
  (select category_id from transactions where id = 'd4800000-0000-0000-0000-0000000000c3'),
  'c4800000-0000-0000-0000-000000000001'::uuid,
  'a learned merchant outranks the hint'
);

-- (c) A hint of the wrong kind is ignored, not obeyed and not raised.
select capture_transaction(
  'd4800000-0000-0000-0000-0000000000c4', 'card-48', 'CORNER SHOP', 'CORNER SHOP',
  45000, now(), 'ext-48-4', null, null, 'c4800000-0000-0000-0000-000000000003'
);

select is(
  (select c.is_default from transactions t join categories c on c.id = t.category_id
   where t.id = 'd4800000-0000-0000-0000-0000000000c4'),
  true,
  'an income category offered as a hint for an expense is ignored'
);

-- (d) A deleted category is not a hint.
select capture_transaction(
  'd4800000-0000-0000-0000-0000000000c5', 'card-48', 'NEWSAGENT', 'NEWSAGENT',
  45000, now(), 'ext-48-5', null, null, 'c4800000-0000-0000-0000-000000000004'
);

select is(
  (select c.is_default from transactions t join categories c on c.id = t.category_id
   where t.id = 'd4800000-0000-0000-0000-0000000000c5'),
  true,
  'a deleted category offered as a hint is ignored'
);

-- (e) Someone else's category is not a hint — B's category, offered by A.
reset role;
insert into categories (id, owner_id, kind, name)
values ('c4800000-0000-0000-0000-0000000000b1', '22222222-2222-2222-2222-222222222222', 'expense', 'B Coffee');
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select capture_transaction(
  'd4800000-0000-0000-0000-0000000000c6', 'card-48', 'KIOSK', 'KIOSK',
  45000, now(), 'ext-48-6', null, null, 'c4800000-0000-0000-0000-0000000000b1'
);

select is(
  (select c.owner_id from transactions t join categories c on c.id = t.category_id
   where t.id = 'd4800000-0000-0000-0000-0000000000c6'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'another user''s category offered as a hint is ignored'
);

-- ============================================================================
-- 6. Recurring — every occurrence inherits the rule's title
-- ============================================================================

insert into recurring_rules (
  id, account_id, category_id, amount_e4, currency, frequency, next_due_at, title, created_by
) values (
  'e4800000-0000-0000-0000-000000000001', 'a4800000-0000-0000-0000-000000000001',
  'c4800000-0000-0000-0000-000000000002', -1500000, 'EUR', 'monthly', date '2026-09-20', 'Gym', auth.uid()
);

insert into recurring_rules (
  id, account_id, to_account_id, amount_e4, currency, frequency, next_due_at, title, created_by
) values (
  'e4800000-0000-0000-0000-000000000002', 'a4800000-0000-0000-0000-000000000001',
  'a4800000-0000-0000-0000-000000000002', -2000000, 'EUR', 'monthly', date '2026-09-20', 'Save 20', auth.uid()
);

reset role;
select materialize_recurring(date '2026-09-20');
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select title from transactions where recurring_rule_id = 'e4800000-0000-0000-0000-000000000001'),
  'Gym',
  'an expense occurrence inherits its rule''s title'
);

select is(
  (select count(*) from transactions
   where recurring_rule_id = 'e4800000-0000-0000-0000-000000000002' and title = 'Save 20'),
  2::bigint,
  'both legs of a recurring transfer inherit the title'
);

select is(
  (select title from transactions_with_details
   where recurring_rule_id = 'e4800000-0000-0000-0000-000000000001'),
  'Gym',
  'and the view carries it'
);

-- A rule with no title mints occurrences with no title, not ''.
insert into recurring_rules (
  id, account_id, category_id, amount_e4, currency, frequency, next_due_at, created_by
) values (
  'e4800000-0000-0000-0000-000000000003', 'a4800000-0000-0000-0000-000000000001',
  'c4800000-0000-0000-0000-000000000002', -100000, 'EUR', 'monthly', date '2026-09-20', auth.uid()
);
reset role;
select materialize_recurring(date '2026-09-20');
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select title from transactions where recurring_rule_id = 'e4800000-0000-0000-0000-000000000003'),
  null::text,
  'an untitled rule mints untitled occurrences'
);

-- ============================================================================
-- 7. Leaving a household keeps the titles on both copies
-- ============================================================================

select create_household();

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a4800000-0000-0000-0000-0000000000a9', auth.uid(), auth.uid(), 'regular', 'Joint', 'EUR', 0);
select share_account('a4800000-0000-0000-0000-0000000000a9');

create temp table captured_token_48 (token text);
insert into captured_token_48 select create_invite();

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, title)
values ('d4800000-0000-0000-0000-0000000000a9', auth.uid(), auth.uid(), 'a4800000-0000-0000-0000-0000000000a9',
  'c4800000-0000-0000-0000-000000000002', -300000, 'EUR', now(), 'Anniversary dinner');

insert into recurring_rules (
  id, account_id, category_id, amount_e4, currency, frequency, next_due_at, title, created_by
) values (
  'e4800000-0000-0000-0000-0000000000a9', 'a4800000-0000-0000-0000-0000000000a9',
  'c4800000-0000-0000-0000-000000000002', -100000, 'EUR', 'monthly', current_date + 30, 'Streaming', auth.uid()
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select accept_invite((select token from captured_token_48));
select leave_household();

select is(
  (select t.title from transactions t join accounts a on a.id = t.account_id
   where a.owner_id = auth.uid() and a.name = 'Joint' and t.amount_e4 = -300000),
  'Anniversary dinner',
  'the forked copy of a transaction keeps its title'
);

select is(
  (select rr.title from recurring_rules rr join accounts a on a.id = rr.account_id
   where a.owner_id = auth.uid() and a.name = 'Joint'),
  'Streaming',
  'the forked copy of a recurring rule keeps its title'
);

reset role;
select is(
  (select count(*) from transactions t join accounts a on a.id = t.account_id
   where a.owner_id = '11111111-1111-1111-1111-111111111111' and a.name = 'Joint'
     and a.archived_at is null and t.title = 'Anniversary dinner'),
  1::bigint,
  'and so does the other member''s copy'
);

select * from finish();
rollback;
