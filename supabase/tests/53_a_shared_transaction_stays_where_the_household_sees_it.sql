-- A shared transaction stays where the household sees it
-- (20261011100000_a_shared_transaction_stays_where_the_household_sees_it.sql).
--
--   1. An edit that would take a live row out of the household's view is
--      refused on every write path, with a sentence saying what to do instead.
--   2. Every other move still works: inside the view, into it, and anything
--      that was never in it.
--   3. What the sentence suggests works: a deletion reaches the partner.
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (partner).

\ir _helpers.psql

begin;
select plan(16);

-- ============================================================================
-- Setup, as postgres
-- ============================================================================

insert into households (id) values ('53000000-0000-0000-0000-000000000001');
insert into household_members (household_id, user_id)
values
  ('53000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('53000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a5300000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Full History', 'EUR', 0),
  ('a5300000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A From A Date', 'EUR', 0),
  ('a5300000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Private', 'EUR', 0);

insert into household_accounts (household_id, account_id, history_from)
values
  ('53000000-0000-0000-0000-000000000001', 'a5300000-0000-0000-0000-000000000001', null),
  ('53000000-0000-0000-0000-000000000001', 'a5300000-0000-0000-0000-000000000002', now() - interval '30 days');

insert into categories (id, owner_id, kind, name)
values ('c5300000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Everyday');

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values
  -- Seen by the household: on the full-history share, and after the start date.
  ('d5300000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5300000-0000-0000-0000-000000000001',
   'c5300000-0000-0000-0000-000000000001', -1000, 'EUR', now() - interval '5 days'),
  ('d5300000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5300000-0000-0000-0000-000000000002',
   'c5300000-0000-0000-0000-000000000001', -2000, 'EUR', now() - interval '10 days'),
  -- Never seen: before the start date, and private.
  ('d5300000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5300000-0000-0000-0000-000000000002',
   'c5300000-0000-0000-0000-000000000001', -3000, 'EUR', now() - interval '60 days'),
  ('d5300000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5300000-0000-0000-0000-000000000003',
   'c5300000-0000-0000-0000-000000000001', -4000, 'EUR', now() - interval '3 days'),
  ('d5300000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5300000-0000-0000-0000-000000000002',
   'c5300000-0000-0000-0000-000000000001', -5000, 'EUR', now() - interval '50 days'),
  -- Seen, and about to be deleted the way the refusal suggests.
  ('d5300000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5300000-0000-0000-0000-000000000001',
   'c5300000-0000-0000-0000-000000000001', -6000, 'EUR', now() - interval '2 days');

-- A pending capture that landed on the shared account.
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, source, status)
values ('d5300000-0000-0000-0000-000000000007', '11111111-1111-1111-1111-111111111111',
        '11111111-1111-1111-1111-111111111111', 'a5300000-0000-0000-0000-000000000001',
        'c5300000-0000-0000-0000-000000000001', -7000, 'EUR', now() - interval '1 day', 'capture', 'pending');

-- A transfer between the two shared accounts.
insert into transactions (id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, transfer_group_id)
values
  ('d5300000-0000-0000-0000-000000000011', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5300000-0000-0000-0000-000000000001',
   -8000, 'EUR', now() - interval '4 days', 'd5300000-0000-0000-0000-000000000011'),
  ('d5300000-0000-0000-0000-000000000012', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5300000-0000-0000-0000-000000000002',
   8000, 'EUR', now() - interval '4 days', 'd5300000-0000-0000-0000-000000000011');

create temp table pulls (label text primary key, payload jsonb, next_cursor bigint);
grant all on pulls to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
insert into pulls select 'b1', payload, next_cursor from pull_changes(0, 0);

-- ============================================================================
-- 1. Out of the view: refused
-- ============================================================================

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select throws_ok(
  $$ select update_transaction('d5300000-0000-0000-0000-000000000001', 1,
       'a5300000-0000-0000-0000-000000000003', 'c5300000-0000-0000-0000-000000000001',
       -1000, 'EUR', now() - interval '5 days') $$,
  'P0001',
  'This transaction is shared with your household, so it can''t be moved to an account they can''t see. Delete it and add it again on that account.',
  'the owner cannot move a shared transaction to a private account'
);

-- Clients have no UPDATE grant; the rule binds a privileged write too.
reset role;
select throws_ok(
  $$ update transactions set account_id = 'a5300000-0000-0000-0000-000000000003'
     where id = 'd5300000-0000-0000-0000-000000000001' $$,
  'P0001',
  'This transaction is shared with your household, so it can''t be moved to an account they can''t see. Delete it and add it again on that account.',
  'not even by a write that goes around the RPCs'
);
set local role authenticated;

select throws_ok(
  $$ select update_transaction('d5300000-0000-0000-0000-000000000002', 1,
       'a5300000-0000-0000-0000-000000000002', 'c5300000-0000-0000-0000-000000000001',
       -2000, 'EUR', now() - interval '40 days') $$,
  'P0001',
  'Your household sees this account''s transactions from the day you shared it, so this transaction can''t be moved before that date. Delete it and add it again with the earlier date.',
  'or re-date one to before the start date'
);

select throws_ok(
  $$ select update_transfer('d5300000-0000-0000-0000-000000000011', 1, 1, 8000, 8000,
       now() - interval '4 days', null, null,
       'a5300000-0000-0000-0000-000000000001', 'a5300000-0000-0000-0000-000000000003') $$,
  'P0001',
  'This transfer is shared with your household, so it can''t be moved to an account they can''t see. Delete it and add it again on that account.',
  'or move half of a shared transfer to a private account'
);

select throws_ok(
  $$ select review_capture_transaction('d5300000-0000-0000-0000-000000000007', 1,
       'a5300000-0000-0000-0000-000000000003', 'c5300000-0000-0000-0000-000000000001',
       -7000, 'EUR', now() - interval '1 day', null, null, null, null, null) $$,
  'P0001',
  'This transaction is shared with your household, so it can''t be moved to an account they can''t see. Delete it and add it again on that account.',
  'or file a capture that landed on a shared account under a private one'
);

-- ============================================================================
-- 2. Everything else: allowed
-- ============================================================================

select is(
  (select conflict from update_transaction('d5300000-0000-0000-0000-000000000001', 1,
     'a5300000-0000-0000-0000-000000000001', 'c5300000-0000-0000-0000-000000000001',
     -1500, 'EUR', now() - interval '5 days')),
  false,
  'a shared transaction can still be edited where it is'
);

select is(
  (select (transaction).account_id from update_transaction('d5300000-0000-0000-0000-000000000002', 1,
     'a5300000-0000-0000-0000-000000000001', 'c5300000-0000-0000-0000-000000000001',
     -2000, 'EUR', now() - interval '10 days')),
  'a5300000-0000-0000-0000-000000000001'::uuid,
  'and moved to another account the household sees'
);

select throws_ok(
  $$ select update_transaction('d5300000-0000-0000-0000-000000000002', 2,
       'a5300000-0000-0000-0000-000000000002', 'c5300000-0000-0000-0000-000000000001',
       -2000, 'EUR', now() - interval '45 days') $$,
  'P0001',
  'Your household sees this account''s transactions from the day you shared it, so this transaction can''t be moved before that date. Delete it and add it again with the earlier date.',
  'but not to a date before that account''s start date'
);

select is(
  (select (transaction).occurred_at from update_transaction('d5300000-0000-0000-0000-000000000003', 1,
     'a5300000-0000-0000-0000-000000000002', 'c5300000-0000-0000-0000-000000000001',
     -3000, 'EUR', now() - interval '20 days')),
  now() - interval '20 days',
  'a transaction before the start date can be moved into the view'
);

select is(
  (select (transaction).account_id from update_transaction('d5300000-0000-0000-0000-000000000005', 1,
     'a5300000-0000-0000-0000-000000000003', 'c5300000-0000-0000-0000-000000000001',
     -5000, 'EUR', now() - interval '50 days')),
  'a5300000-0000-0000-0000-000000000003'::uuid,
  'or to a private account, since the household never saw it'
);

select is(
  (select (transaction).account_id from update_transaction('d5300000-0000-0000-0000-000000000004', 1,
     'a5300000-0000-0000-0000-000000000001', 'c5300000-0000-0000-0000-000000000001',
     -4000, 'EUR', now() - interval '3 days')),
  'a5300000-0000-0000-0000-000000000001'::uuid,
  'a private transaction can be moved onto a shared account'
);

-- ============================================================================
-- 3. What the refusal suggests
-- ============================================================================

select is(
  (select conflict from delete_transaction('d5300000-0000-0000-0000-000000000006', 1)),
  false,
  'the owner deletes the shared transaction instead'
);

select lives_ok(
  $$ insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
     values ('d5300000-0000-0000-0000-000000000016', auth.uid(), auth.uid(),
             'a5300000-0000-0000-0000-000000000003', 'c5300000-0000-0000-0000-000000000001',
             -6000, 'EUR', now() - interval '2 days') $$,
  'and adds it again on the private account'
);

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
insert into pulls select 'b2', payload, next_cursor
from pull_changes((select next_cursor from pulls where label = 'b1'), 0);

select isnt(
  (select e->>'deleted_at' from pulls, jsonb_array_elements(payload->'transactions') e
   where label = 'b2' and e->>'id' = 'd5300000-0000-0000-0000-000000000006'),
  null,
  'so the partner''s next pull carries the deletion'
);

select is(
  (select count(*) from pulls, jsonb_array_elements(payload->'transactions') e
   where label = 'b2' and e->>'id' = 'd5300000-0000-0000-0000-000000000016'),
  0::bigint,
  'and not the private copy'
);

-- Once the account is no longer shared, the household sees none of it.
reset role;
update household_accounts set deleted_at = now()
where account_id = 'a5300000-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select (transaction).account_id from update_transaction('d5300000-0000-0000-0000-000000000001', 2,
     'a5300000-0000-0000-0000-000000000003', 'c5300000-0000-0000-0000-000000000001',
     -1500, 'EUR', now() - interval '5 days')),
  'a5300000-0000-0000-0000-000000000003'::uuid,
  'a transaction on an account no longer shared moves freely'
);

select finish();
rollback;
