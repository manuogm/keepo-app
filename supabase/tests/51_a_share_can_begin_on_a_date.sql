-- A share can begin on a date (20261009100000_a_share_can_begin_on_a_date.sql).
--
-- A's account X is shared with B from 30 days ago (`history_from`). B must
-- not see, derive, write, re-date or move anything before that moment, and
-- must still get X's true balance. A sees everything, and widening to full
-- history (null) restores what every share did before this migration.
--
-- Also #16 of the 2026-09-23 transfer review: a deleted account is no
-- target for a new transaction or transfer — while the anchor half a
-- deleted account keeps (20261007100000) can still be edited from the live
-- side.
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (partner).

\ir _helpers.psql

begin;
select plan(26);

-- ============================================================================
-- Setup, as postgres
-- ============================================================================

insert into households (id) values ('51000000-0000-0000-0000-000000000001');
insert into household_members (household_id, user_id)
values
  ('51000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('51000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a5100000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Shared From A Date', 'EUR', 1000000),
  ('a5100000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Private', 'EUR', 0),
  ('a5100000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Shared Then Deleted', 'EUR', 0),
  ('a5100000-0000-0000-0000-000000000004', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'regular', 'B Own Shared', 'EUR', 0);

insert into household_accounts (household_id, account_id, history_from)
values
  ('51000000-0000-0000-0000-000000000001', 'a5100000-0000-0000-0000-000000000001', now() - interval '30 days'),
  ('51000000-0000-0000-0000-000000000001', 'a5100000-0000-0000-0000-000000000003', null),
  ('51000000-0000-0000-0000-000000000001', 'a5100000-0000-0000-0000-000000000004', null);

insert into categories (id, owner_id, kind, name)
values
  ('c5100000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Only Before'),
  ('c5100000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'expense', 'Only After'),
  ('c5100000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'expense', 'B Spending');

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values
  ('d5100000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5100000-0000-0000-0000-000000000001',
   'c5100000-0000-0000-0000-000000000001', -100000, 'EUR', now() - interval '60 days'),
  ('d5100000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5100000-0000-0000-0000-000000000001',
   'c5100000-0000-0000-0000-000000000002', -200000, 'EUR', now() - interval '10 days'),
  ('d5100000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'a5100000-0000-0000-0000-000000000004',
   'c5100000-0000-0000-0000-000000000003', -50000, 'EUR', now() - interval '45 days');

insert into tags (id, owner_id, name)
values
  ('e5100000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Before Trip'),
  ('e5100000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'After Trip'),
  ('e5100000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'B Tag');

insert into transaction_tags (transaction_id, tag_id)
values
  ('d5100000-0000-0000-0000-000000000001', 'e5100000-0000-0000-0000-000000000001'),
  ('d5100000-0000-0000-0000-000000000002', 'e5100000-0000-0000-0000-000000000002');

-- A transfer from A's private account into the account about to be deleted,
-- so the deleted account keeps it as an anchor.
insert into transactions (id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, transfer_group_id)
values
  ('d5100000-0000-0000-0000-000000000011', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5100000-0000-0000-0000-000000000002',
   -70000, 'EUR', now() - interval '5 days', 'd5100000-0000-0000-0000-000000000011'),
  ('d5100000-0000-0000-0000-000000000012', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5100000-0000-0000-0000-000000000003',
   70000, 'EUR', now() - interval '5 days', 'd5100000-0000-0000-0000-000000000011');

update accounts set deleted_at = now() where id = 'a5100000-0000-0000-0000-000000000003';

-- ============================================================================
-- 1. What B reads
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select array_agg(id) from transactions where account_id = 'a5100000-0000-0000-0000-000000000001'),
  array['d5100000-0000-0000-0000-000000000002'::uuid],
  'the partner sees the shared account''s transactions from the start date on, and none before'
);

select is(
  (select array_agg(transaction_id) from transaction_tags
   where transaction_id in ('d5100000-0000-0000-0000-000000000001', 'd5100000-0000-0000-0000-000000000002')),
  array['d5100000-0000-0000-0000-000000000002'::uuid],
  'a tag link on a transaction before the start date is not the partner''s to see'
);

select is(
  (select array_agg(name) from tags where owner_id = '11111111-1111-1111-1111-111111111111'),
  array['After Trip'],
  'the owner''s tag reaches the partner only through a transaction the partner can see'
);

select is(
  (select array_agg(name) from categories where owner_id = '11111111-1111-1111-1111-111111111111'),
  array['Only After'],
  'so does the owner''s category'
);

select is(
  account_balance_on('a5100000-0000-0000-0000-000000000001', current_date),
  700000::bigint,
  'account_balance_on still gives the partner the true balance, history included'
);

select is(
  (select balance_e4 from accounts_with_balances where account_id = 'a5100000-0000-0000-0000-000000000001'),
  700000::bigint,
  'and so does every view built on it'
);

-- ============================================================================
-- 2. What B writes
-- ============================================================================

select throws_ok(
  $$ insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values ('d5100000-0000-0000-0000-000000000021', '11111111-1111-1111-1111-111111111111', auth.uid(),
             'a5100000-0000-0000-0000-000000000001', 'c5100000-0000-0000-0000-000000000002',
             -1000, 'EUR', now() - interval '45 days') $$,
  '42501',
  null,
  'the partner cannot add a transaction dated before the start date'
);

select lives_ok(
  $$ insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values ('d5100000-0000-0000-0000-000000000022', '11111111-1111-1111-1111-111111111111', auth.uid(),
             'a5100000-0000-0000-0000-000000000001', 'c5100000-0000-0000-0000-000000000002',
             -1000, 'EUR', now() - interval '2 days') $$,
  'but can from the start date on'
);

select throws_ok(
  $$ select update_transaction('d5100000-0000-0000-0000-000000000001', 1,
       'a5100000-0000-0000-0000-000000000001', 'c5100000-0000-0000-0000-000000000002',
       -1, 'EUR', now() - interval '60 days') $$,
  'P0001',
  'transaction not found or not accessible',
  'the partner cannot edit a transaction before the start date'
);

select throws_ok(
  $$ select delete_transaction('d5100000-0000-0000-0000-000000000001', 1) $$,
  'P0001',
  'transaction not found or not accessible',
  'or delete one'
);

select throws_ok(
  $$ select update_transaction('d5100000-0000-0000-0000-000000000002', 1,
       'a5100000-0000-0000-0000-000000000001', 'c5100000-0000-0000-0000-000000000002',
       -200000, 'EUR', now() - interval '45 days') $$,
  'P0001',
  'That date is before this account was shared with you. Pick a later date.',
  'or re-date a visible one to before it, and is told why'
);

select throws_ok(
  $$ select update_transaction('d5100000-0000-0000-0000-000000000003', 1,
       'a5100000-0000-0000-0000-000000000001', 'c5100000-0000-0000-0000-000000000003',
       -50000, 'EUR', now() - interval '45 days') $$,
  'P0001',
  'That date is before this account was shared with you. Pick a later date.',
  'or move one of their own there, onto a date before it'
);

select throws_ok(
  $$ insert into transaction_tags (transaction_id, tag_id)
     values ('d5100000-0000-0000-0000-000000000001', 'e5100000-0000-0000-0000-000000000003') $$,
  '42501',
  null,
  'or tag a transaction before it'
);

select throws_ok(
  $$ select create_transfer('a5100000-0000-0000-0000-000000000004', 'a5100000-0000-0000-0000-000000000001',
       10000, null, now() - interval '45 days') $$,
  'P0001',
  'That date is before this account was shared with you. Pick a later date.',
  'a transfer into the shared account before the start date is refused'
);

select lives_ok(
  $$ select create_transfer('a5100000-0000-0000-0000-000000000004', 'a5100000-0000-0000-0000-000000000001',
       10000, null, now() - interval '3 days', 'd5100000-0000-0000-0000-000000000031',
       'd5100000-0000-0000-0000-000000000032') $$,
  'a transfer after it is not'
);
set constraints all immediate;
set constraints all deferred;

select throws_ok(
  $$ select update_transfer('d5100000-0000-0000-0000-000000000031', 1, 1, 10000, 10000,
       now() - interval '45 days') $$,
  'P0001',
  'That date is before this account was shared with you. Pick a later date.',
  'and cannot be re-dated to before it'
);

select is(
  (select opening_balance_e4 from (select (account).* from update_account(
     'a5100000-0000-0000-0000-000000000001', 1, 'Renamed By B', 999, true, 'banknote', '#8E8E93')) a),
  1000000::bigint,
  'a partner''s rename never touches the owner''s opening balance'
);

-- ============================================================================
-- 3. #16 — a deleted account is no target
-- ============================================================================

select throws_ok(
  $$ select create_transfer('a5100000-0000-0000-0000-000000000004', 'a5100000-0000-0000-0000-000000000003',
       10000, null, now()) $$,
  'P0001',
  'account not found or not accessible',
  'create_transfer refuses a deleted account'
);

select throws_ok(
  $$ insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values ('d5100000-0000-0000-0000-000000000041', '11111111-1111-1111-1111-111111111111', auth.uid(),
             'a5100000-0000-0000-0000-000000000003', 'c5100000-0000-0000-0000-000000000002',
             -1000, 'EUR', now()) $$,
  '42501',
  null,
  'and so does a direct insert'
);

-- ============================================================================
-- 4. The owner
-- ============================================================================

reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  household_sharing_tag('e5100000-0000-0000-0000-000000000001'),
  null,
  'a tag linked only before the start date is not shared through the household'
);

select is(
  household_sharing_tag('e5100000-0000-0000-0000-000000000002'),
  '51000000-0000-0000-0000-000000000001'::uuid,
  'one linked after it is'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select count(*) from transactions where account_id = 'a5100000-0000-0000-0000-000000000001'
     and id in ('d5100000-0000-0000-0000-000000000001', 'd5100000-0000-0000-0000-000000000002')),
  2::bigint,
  'the owner sees the whole history of their own account'
);

select lives_ok(
  $$ select update_transaction('d5100000-0000-0000-0000-000000000001', 1,
       'a5100000-0000-0000-0000-000000000001', 'c5100000-0000-0000-0000-000000000001',
       -100000, 'EUR', now() - interval '61 days') $$,
  'and can still edit it'
);

select is(
  (select conflict from update_transfer('d5100000-0000-0000-0000-000000000011', 1, 1, 80000, 80000,
     now() - interval '4 days') limit 1),
  false,
  'a transfer whose other half is a deleted account''s anchor can still be edited from the live side'
);
set constraints all immediate;
set constraints all deferred;

-- ============================================================================
-- 5. Widening to full history
-- ============================================================================

reset role;
update household_accounts set history_from = null
where account_id = 'a5100000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select count(*) from transactions where id in (
     'd5100000-0000-0000-0000-000000000001', 'd5100000-0000-0000-0000-000000000002')),
  2::bigint,
  'with full history the partner sees everything, as every share did before'
);

select is(
  (select count(*) from tags where owner_id = '11111111-1111-1111-1111-111111111111'),
  2::bigint,
  'and every tag it wears'
);

select finish();
rollback;
