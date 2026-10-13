-- A change sent twice is saved once
-- (20261017100000_a_change_sent_twice_is_saved_once.sql).
--
-- The outbox resends any write whose first attempt ended without an answer,
-- and that first attempt can have landed. These pin that every
-- version-checked transaction write answers its own resend with success —
-- never a refusal, never a conflict against the user's own change — while a
-- genuinely stale write is still a conflict.
--
-- Fixture A = 11111111-....

\ir _helpers.psql

begin;
select plan(19);

-- Captures are written as the table owner: RLS (rightly) refuses a client
-- insert with source = 'capture', and only their status matters here.
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a5900000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '11111111-1111-1111-1111-111111111111', 'regular', 'A Checking', 'EUR', 0),
       ('a5900000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
        '11111111-1111-1111-1111-111111111111', 'regular', 'A Savings', 'EUR', 0);
insert into categories (id, owner_id, kind, name)
values ('c5900000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Dining'),
       ('c5900000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'expense', 'Groceries');
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
                          source, status)
values
  ('d5900000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5900000-0000-0000-0000-000000000001',
   'c5900000-0000-0000-0000-000000000001', -45000, 'EUR', now(), 'manual', 'confirmed'),
  ('d5900000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5900000-0000-0000-0000-000000000001',
   'c5900000-0000-0000-0000-000000000001', -380000, 'EUR', now(), 'capture', 'pending'),
  ('d5900000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5900000-0000-0000-0000-000000000001',
   'c5900000-0000-0000-0000-000000000001', -12000, 'EUR', now(), 'capture', 'pending'),
  ('d5900000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5900000-0000-0000-0000-000000000001',
   'c5900000-0000-0000-0000-000000000001', -9000, 'EUR', now(), 'manual', 'confirmed');

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- ============================================================================
-- A review — the write behind the bug: a resend raised "not a pending
-- capture" and the phone showed that sentence to the user
-- ============================================================================

select review_capture_transaction(
  'd5900000-0000-0000-0000-000000000002', 1, 'a5900000-0000-0000-0000-000000000001',
  'c5900000-0000-0000-0000-000000000001', -380000, 'EUR', now(), 'TRATTORIA', null, null, null, 'Dinner'
);

select is(
  (select conflict from review_capture_transaction(
     'd5900000-0000-0000-0000-000000000002', 1, 'a5900000-0000-0000-0000-000000000001',
     'c5900000-0000-0000-0000-000000000001', -380000, 'EUR', now(), 'TRATTORIA', null, null, null, 'Dinner')),
  false,
  'resending a review that already landed is its success, not a refusal'
);

select is(
  (select count(*)::int from sync_conflicts where row_id = 'd5900000-0000-0000-0000-000000000002'),
  0,
  'and logs no conflict against the user''s own change'
);

select is(
  (select conflict from review_capture_transaction(
     'd5900000-0000-0000-0000-000000000002', 1, 'a5900000-0000-0000-0000-000000000001',
     'c5900000-0000-0000-0000-000000000002', -380000, 'EUR', now(), 'TRATTORIA', null, null, null, 'Dinner')),
  true,
  'a stale review that asks for something else is still a conflict'
);

select is(
  (select conflict from review_capture_transaction(
     'd5900000-0000-0000-0000-000000000002', 2, 'a5900000-0000-0000-0000-000000000001',
     'c5900000-0000-0000-0000-000000000002', -380000, 'EUR', now(), 'TRATTORIA', null, null, null, 'Dinner')),
  false,
  'a review of a confirmed capture at its current version applies, as an edit'
);

select is(
  (select category_id from transactions where id = 'd5900000-0000-0000-0000-000000000002'),
  'c5900000-0000-0000-0000-000000000002'::uuid,
  'and the edit is saved'
);

-- ============================================================================
-- A confirm
-- ============================================================================

select confirm_capture_transaction('d5900000-0000-0000-0000-000000000003', 1);

select is(
  (select conflict from confirm_capture_transaction('d5900000-0000-0000-0000-000000000003', 1)),
  false,
  'resending a confirm that already landed is its success'
);

select is(
  (select count(*)::int from sync_conflicts where row_id = 'd5900000-0000-0000-0000-000000000003'),
  0,
  'and logs no conflict'
);

-- ============================================================================
-- A ledger edit
-- ============================================================================

select update_transaction(
  'd5900000-0000-0000-0000-000000000001', 1, 'a5900000-0000-0000-0000-000000000001',
  'c5900000-0000-0000-0000-000000000002', -52000, 'EUR', now(), null, 'with the receipt'
);

select is(
  (select conflict from update_transaction(
     'd5900000-0000-0000-0000-000000000001', 1, 'a5900000-0000-0000-0000-000000000001',
     'c5900000-0000-0000-0000-000000000002', -52000, 'EUR', now(), null, 'with the receipt')),
  false,
  'resending an edit that already landed is its success'
);

select is(
  (select conflict from update_transaction(
     'd5900000-0000-0000-0000-000000000001', 1, 'a5900000-0000-0000-0000-000000000001',
     'c5900000-0000-0000-0000-000000000002', -61000, 'EUR', now(), null, 'with the receipt')),
  true,
  'a stale edit that asks for something else is still a conflict'
);

-- ============================================================================
-- A delete
-- ============================================================================

select delete_transaction('d5900000-0000-0000-0000-000000000004', 1);

select is(
  (select conflict from delete_transaction('d5900000-0000-0000-0000-000000000004', 1)),
  false,
  'resending a delete that already landed is its success, not "not found"'
);

-- ============================================================================
-- A transfer edit and a transfer delete
-- ============================================================================

select create_transfer(
  'a5900000-0000-0000-0000-000000000001', 'a5900000-0000-0000-0000-000000000002', 50000, null, now(),
  'd5900000-0000-0000-0000-000000000007', 'd5900000-0000-0000-0000-000000000008'
);

select update_transfer('d5900000-0000-0000-0000-000000000007', 1, 1, 60000, 60000, now(), 'rent share', 'Rent');

select is(
  (select bool_or(conflict) from update_transfer(
     'd5900000-0000-0000-0000-000000000007', 1, 1, 60000, 60000, now(), 'rent share', 'Rent')),
  false,
  'resending a transfer edit that already landed is its success'
);

select is(
  (select count(*)::int from sync_conflicts
   where row_id in ('d5900000-0000-0000-0000-000000000007', 'd5900000-0000-0000-0000-000000000008')),
  0,
  'and logs no conflict'
);

select is(
  (select bool_or(conflict) from update_transfer(
     'd5900000-0000-0000-0000-000000000007', 1, 1, 70000, 70000, now(), 'rent share', 'Rent')),
  true,
  'a stale transfer edit that asks for something else is still a conflict'
);

select delete_transfer('d5900000-0000-0000-0000-000000000007', 2, 2);

select is(
  (select conflict from delete_transfer('d5900000-0000-0000-0000-000000000007', 2, 2)),
  false,
  'resending a transfer delete that already landed is its success, not "not found"'
);

select throws_ok(
  $$ select update_transfer('d5900000-0000-0000-0000-000000000007', 2, 2, 1, 1, now()) $$,
  'P0001', 'This transfer was deleted, or is no longer shared with you.',
  'a transfer that is gone says so in words, without its id'
);

select throws_ok(
  $$ select delete_transfer('d5900000-0000-0000-0000-0000000000ff', 1, 1) $$,
  'P0001', 'This transfer was deleted, or is no longer shared with you.',
  'and one that never existed is not mistaken for one already deleted'
);

-- ============================================================================
-- Developer guards are not sentences for the user
-- ============================================================================

select create_transfer(
  'a5900000-0000-0000-0000-000000000001', 'a5900000-0000-0000-0000-000000000002', 10000, null, now(),
  'd5900000-0000-0000-0000-000000000005', 'd5900000-0000-0000-0000-000000000006'
);

select throws_ok(
  $$ select update_transaction('d5900000-0000-0000-0000-000000000005', 1,
       'a5900000-0000-0000-0000-000000000001', 'c5900000-0000-0000-0000-000000000001', -10000, 'EUR', now()) $$,
  '22023', null,
  'a wrong-RPC guard raises 22023, which the phone never shows verbatim'
);

select throws_ok(
  $$ select review_capture_transaction('d5900000-0000-0000-0000-000000000001', 2,
       'a5900000-0000-0000-0000-000000000001', 'c5900000-0000-0000-0000-000000000001', -52000, 'EUR', now()) $$,
  '22023', null,
  'reviewing a row that was never a capture is a developer error too'
);

select throws_ok(
  $$ select transaction_already_matches('d5900000-0000-0000-0000-000000000001', '{}'::jsonb) $$,
  '42501', null,
  'transaction_already_matches cannot be called directly'
);

select * from finish();
rollback;
