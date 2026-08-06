-- needs_review view + resolve_sync_conflict (migration
-- 20260807090000_needs_review.sql): the sync_conflict branch, the
-- reconciliation_gap branch, resolution, and RLS scoping. Fixture A =
-- 11111111-..., fixture B = 22222222-....

\ir _helpers.psql

begin;
select plan(10);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a1000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Checking', 'EUR', 100);
insert into categories (id, owner_id, kind, name)
values ('c1000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Test Expense');
insert into transactions (id, owner_id, created_by, account_id, category_id, amount, currency, occurred_at)
values (
  'd1000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(),
  'a1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', -10, 'EUR', now()
);

-- Force a stale-version conflict, exactly as 04_transaction_editing.sql
-- does, to populate sync_conflicts.
select update_transaction(
  'd1000000-0000-0000-0000-000000000001', 999,
  'a1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001',
  -20, 'EUR', now(), null
);

-- A second account, backdated well past the checking threshold (3 days) so
-- it surfaces as a reconciliation_gap with no reconciliations row needed —
-- accounts_sync_status falls back to created_at as the verification clock.
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance, created_at)
values (
  'a1000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Stale', 'EUR', 50,
  now() - interval '10 days'
);

-- 1. The unresolved sync conflict appears in needs_review.
select is(
  (select count(*) from needs_review
   where kind = 'sync_conflict' and item_id in (select id from sync_conflicts where row_id = 'd1000000-0000-0000-0000-000000000001')),
  1::bigint,
  'an unresolved sync conflict appears in needs_review'
);

-- 2. Its account_id resolves through the transactions table (table_name =
-- 'transactions'), not left null.
select is(
  (select account_id from needs_review where kind = 'sync_conflict' limit 1),
  'a1000000-0000-0000-0000-000000000001'::uuid,
  'a sync_conflict row resolves account_id via the conflicted transaction''s own account'
);

-- 3. The backdated, never-reconciled account appears as a reconciliation_gap.
select is(
  (select count(*) from needs_review
   where kind = 'reconciliation_gap' and item_id = 'a1000000-0000-0000-0000-000000000002'),
  1::bigint,
  'an overdue-for-reconciliation account appears in needs_review as a reconciliation_gap'
);

-- 4. A freshly created account (created "now," not backdated) does NOT
-- appear — it's within every subtype's threshold.
select is(
  (select count(*) from needs_review where item_id = 'a1000000-0000-0000-0000-000000000001'
   and kind = 'reconciliation_gap'),
  0::bigint,
  'a freshly verified account is not a reconciliation_gap'
);

-- 5. Reconciling the stale account removes it from needs_review — the
-- ritual closing the gap is what needs_review is watching for, not a
-- separate dismissal action.
select reconcile_ledger_account('a1000000-0000-0000-0000-000000000002', 50, null);

select is(
  (select count(*) from needs_review where item_id = 'a1000000-0000-0000-0000-000000000002'
   and kind = 'reconciliation_gap'),
  0::bigint,
  'reconciling a stale account removes its reconciliation_gap row'
);

-- 6. resolve_sync_conflict marks it resolved and it drops out of needs_review.
select resolve_sync_conflict((select id from sync_conflicts where row_id = 'd1000000-0000-0000-0000-000000000001'));

select is(
  (select count(*) from needs_review where kind = 'sync_conflict'),
  0::bigint,
  'resolve_sync_conflict removes the row from needs_review'
);

-- 7. Calling it again on the same, already-resolved conflict is a no-op,
-- not an exception — a client retry must be safe.
select lives_ok(
  $$ select resolve_sync_conflict((select id from sync_conflicts where row_id = 'd1000000-0000-0000-0000-000000000001')) $$,
  'resolving an already-resolved conflict is a no-op, not an error'
);

-- 8. resolve_sync_conflict on a nonexistent id raises.
select throws_like(
  $$ select resolve_sync_conflict('00000000-0000-0000-0000-000000000099') $$,
  '%not found%',
  'resolve_sync_conflict raises for a nonexistent id'
);

-- ----------------------------------------------------------------------------
-- 9-10. RLS: fixture B sees none of A's needs_review rows, and can't
-- resolve A's conflict either.
-- ----------------------------------------------------------------------------

-- Recreate a live conflict for A to test B's inability to resolve it.
select update_transaction(
  'd1000000-0000-0000-0000-000000000001', 2,
  'a1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001',
  -30, 'EUR', now(), null
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select count(*) from needs_review),
  0::bigint,
  'fixture B sees none of fixture A''s needs_review rows'
);

select throws_like(
  $$ select resolve_sync_conflict((select id from sync_conflicts where row_id = 'd1000000-0000-0000-0000-000000000001')) $$,
  '%not found%',
  'fixture B cannot resolve fixture A''s sync conflict'
);

select * from finish();
rollback;
