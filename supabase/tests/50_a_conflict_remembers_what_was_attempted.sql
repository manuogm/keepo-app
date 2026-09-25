-- A conflict remembers what was attempted
-- (20261008100000_a_conflict_remembers_what_was_attempted.sql).
--
-- "Keep mine" can only replay what the conflict row kept. These pin that
-- every transaction RPC keeps its rejected call, that a transfer records one
-- conflict rather than one per leg, and that nobody can forge a conflict row
-- through the helper directly.
--
-- Fixture A = 11111111-....

\ir _helpers.psql

begin;
select plan(8);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a5000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'A Checking', 'EUR', 0),
  ('a5000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'regular', 'A Savings', 'EUR', 0);
insert into categories (id, owner_id, kind, name)
values ('c5000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Groceries');
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values ('d5000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(),
        'a5000000-0000-0000-0000-000000000001', 'c5000000-0000-0000-0000-000000000001', -45000, 'EUR', now());
select create_transfer(
  'a5000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', 100000, null, now(),
  'd5000000-0000-0000-0000-000000000002', 'd5000000-0000-0000-0000-000000000003'
);

-- ============================================================================
-- A ledger edit
-- ============================================================================

select is(
  (select conflict from update_transaction(
     'd5000000-0000-0000-0000-000000000001', 99, 'a5000000-0000-0000-0000-000000000001',
     'c5000000-0000-0000-0000-000000000001', -52000, 'EUR', now(), null, 'with the receipt', null, null,
     'Weekly shop')),
  true,
  'a stale ledger edit is a conflict'
);

select results_eq(
  $$ select attempted_payload->>'rpc', (attempted_payload->>'amount_e4')::bigint,
            attempted_payload->>'notes', attempted_payload->>'title'
     from sync_conflicts where row_id = 'd5000000-0000-0000-0000-000000000001' $$,
  $$ values ('update_transaction'::text, -52000::bigint, 'with the receipt'::text, 'Weekly shop'::text) $$,
  'the conflict keeps the edit the user attempted, not just two version numbers'
);

-- ============================================================================
-- A transfer edit: one conflict, on the sending leg, with the whole attempt
-- ============================================================================

select is(
  (select conflict from update_transfer(
     'd5000000-0000-0000-0000-000000000002', 99, 99, 120000, 120000, now(), 'rent share', 'Rent') limit 1),
  true,
  'a stale transfer edit is a conflict'
);

select is(
  (select count(*)::int from sync_conflicts
   where row_id in ('d5000000-0000-0000-0000-000000000002', 'd5000000-0000-0000-0000-000000000003')),
  1,
  'one transfer edit records one conflict, not one per leg'
);

select results_eq(
  $$ select row_id, attempted_payload->>'rpc', (attempted_payload->>'transfer_group_id')::uuid,
            (attempted_payload->>'from_amount_e4')::bigint, attempted_payload->>'title',
            (attempted_payload->>'to_account_id')::uuid
     from sync_conflicts where row_id = 'd5000000-0000-0000-0000-000000000002' $$,
  $$ values ('d5000000-0000-0000-0000-000000000002'::uuid, 'update_transfer'::text,
             'd5000000-0000-0000-0000-000000000002'::uuid, 120000::bigint, 'Rent'::text,
             'a5000000-0000-0000-0000-000000000002'::uuid) $$,
  'it is filed on the sending leg and carries everything update_transfer needs to replay it'
);

-- ============================================================================
-- Deletes
-- ============================================================================

select is(
  (select conflict from delete_transfer('d5000000-0000-0000-0000-000000000002', 1, 99)),
  true,
  'a stale transfer delete is a conflict'
);

-- Counted by rpc rather than read by recency: now() is frozen for the whole
-- file, so the update's conflict and this one share a created_at.
select is(
  (select count(*)::int from sync_conflicts
   where row_id = 'd5000000-0000-0000-0000-000000000002' and attempted_payload->>'rpc' = 'delete_transfer'),
  1,
  'and says it was a delete'
);

-- ============================================================================
-- The helper is not a way in
-- ============================================================================

select throws_ok(
  $$ select record_transaction_conflict('d5000000-0000-0000-0000-000000000001', 1, 2, '{}'::jsonb) $$,
  '42501', null,
  'record_transaction_conflict cannot be called directly'
);

select * from finish();
rollback;
