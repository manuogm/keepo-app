-- A conflict asks only when there is a choice
-- (20261018100000_a_conflict_asks_only_when_there_is_a_choice.sql).
--
-- Pins the three ways a conflict used to reach the user with nothing to
-- decide: one that outlived the row it was about, an account conflict that
-- kept no record of the attempt, and the version bump a balance save left
-- behind — plus the inbox row's wording.
--
-- Fixture A = 11111111-....

\ir _helpers.psql

begin;
select plan(17);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a6000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'Checking', 'EUR', 1000000),
  ('a6000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'regular', 'Old Card', 'EUR', 0);
insert into categories (id, owner_id, kind, name)
values ('c6000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Groceries');
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, merchant_raw)
values ('d6000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(),
        'a6000000-0000-0000-0000-000000000001', 'c6000000-0000-0000-0000-000000000001', -45000, 'EUR', now(),
        'Mercadona');

-- ============================================================================
-- Setting a balance leaves the account's version alone
-- ============================================================================

select set_account_balance('a6000000-0000-0000-0000-000000000001', 1500000, 1);

select is(
  (select version from accounts where id = 'a6000000-0000-0000-0000-000000000001'),
  1,
  'setting a balance files an adjustment without bumping the account''s version'
);

select is(
  (select conflict from update_account('a6000000-0000-0000-0000-000000000001', 1, 'Everyday', 0, true, 'banknote', '#22AA88')),
  false,
  'so the next edit made with the version the phone holds is not a conflict against the user''s own save'
);

select is(
  (select conflict from set_account_balance('a6000000-0000-0000-0000-000000000001', 1500000, 1)),
  false,
  'a stale balance save that asks for the balance the account already shows is no conflict'
);

-- ============================================================================
-- Account conflicts keep what was attempted
-- ============================================================================

-- "Elsewhere" renames first (v2 → v3); this phone still holds v2.
select update_account('a6000000-0000-0000-0000-000000000001', 2, 'Main', 0, true, 'banknote', '#22AA88');

select update_account('a6000000-0000-0000-0000-000000000001', 2, 'Daily', 0, true, 'banknote', '#22AA88');
select set_account_balance('a6000000-0000-0000-0000-000000000001', 2000000, 2);
select archive_account('a6000000-0000-0000-0000-000000000001', 2, true);
select set_account_kind('a6000000-0000-0000-0000-000000000001', 2, 'investment');
select delete_account('a6000000-0000-0000-0000-000000000001', 2);

select results_eq(
  $$ select attempted_payload->>'rpc' from sync_conflicts
     where row_id = 'a6000000-0000-0000-0000-000000000001' order by sync_seq $$,
  $$ values ('update_account'::text), ('set_account_balance'), ('archive_account'), ('set_account_kind'),
            ('delete_account') $$,
  'every account write keeps the call it attempted'
);

select results_eq(
  $$ select attempted_payload->>'name', (attempted_payload->>'include_in_total')::boolean from sync_conflicts
     where row_id = 'a6000000-0000-0000-0000-000000000001' and attempted_payload->>'rpc' = 'update_account' $$,
  $$ values ('Daily'::text, true) $$,
  'a rename keeps the name it asked for'
);

select is(
  (select (attempted_payload->>'new_balance_e4')::bigint from sync_conflicts
   where row_id = 'a6000000-0000-0000-0000-000000000001' and attempted_payload->>'rpc' = 'set_account_balance'),
  2000000::bigint,
  'a balance keeps the balance it asked for'
);

select is(
  (select (attempted_payload->>'archived')::boolean from sync_conflicts
   where row_id = 'a6000000-0000-0000-0000-000000000001' and attempted_payload->>'rpc' = 'archive_account'),
  true,
  'an archive keeps which way it went'
);

select is(
  (select attempted_payload->>'kind' from sync_conflicts
   where row_id = 'a6000000-0000-0000-0000-000000000001' and attempted_payload->>'rpc' = 'set_account_kind'),
  'investment',
  'a type change keeps the type it asked for'
);

-- ============================================================================
-- A stale write that asks for what the account already holds is no conflict
-- ============================================================================

select is(
  (select count(*)::int from sync_conflicts where row_id = 'a6000000-0000-0000-0000-000000000002'),
  0,
  'precondition: the second account has no conflicts'
);

select update_account('a6000000-0000-0000-0000-000000000002', 1, 'Old Card (closed)', 0, true, 'banknote', '#22AA88');
select update_account('a6000000-0000-0000-0000-000000000002', 1, 'Old Card (closed)', 0, true, 'banknote', '#22AA88');
select archive_account('a6000000-0000-0000-0000-000000000002', 2, false);
select set_account_kind('a6000000-0000-0000-0000-000000000002', 1, 'regular');

select is(
  (select count(*)::int from sync_conflicts where row_id = 'a6000000-0000-0000-0000-000000000002'),
  0,
  'a rename, archive or type change that is already true conflicts with nothing'
);

-- ============================================================================
-- The inbox row names the thing and says what to do
-- ============================================================================

select is(
  (select title || ' / ' || subtitle from needs_review
   where kind = 'sync_conflict' and item_id = (
     select id from sync_conflicts where row_id = 'a6000000-0000-0000-0000-000000000001'
     order by sync_seq limit 1)),
  'Sync Conflict / Main · Choose which version to keep',
  'an account conflict''s inbox row names the account in plain words'
);

select update_transaction('d6000000-0000-0000-0000-000000000001', 1, 'a6000000-0000-0000-0000-000000000001',
  'c6000000-0000-0000-0000-000000000001', -50000, 'EUR', now(), 'Mercadona');
select update_transaction('d6000000-0000-0000-0000-000000000001', 1, 'a6000000-0000-0000-0000-000000000001',
  'c6000000-0000-0000-0000-000000000001', -60000, 'EUR', now(), 'Mercadona');

select is(
  (select subtitle from needs_review where kind = 'sync_conflict' and item_id = (
     select id from sync_conflicts where row_id = 'd6000000-0000-0000-0000-000000000001')),
  'Mercadona · Choose which version to keep',
  'a transaction conflict''s inbox row names the merchant'
);

-- ============================================================================
-- A deleted row closes its conflicts
-- ============================================================================

select delete_transaction('d6000000-0000-0000-0000-000000000001', 2);

select ok(
  (select resolved_at is not null from sync_conflicts where row_id = 'd6000000-0000-0000-0000-000000000001'),
  'deleting a transaction closes its open conflict'
);

select delete_account('a6000000-0000-0000-0000-000000000001', 3, true);

select is(
  (select count(*)::int from sync_conflicts
   where row_id = 'a6000000-0000-0000-0000-000000000001' and resolved_at is null),
  0,
  'deleting an account closes every open conflict about it'
);

select is(
  (select count(*)::int from needs_review where kind = 'sync_conflict'),
  0,
  'and none of them is left in the inbox'
);

select is(
  (select conflict from delete_account('a6000000-0000-0000-0000-000000000001', 3, true)),
  false,
  'a delete sent again after it landed is its success, not "not found"'
);

select throws_ok(
  $$ select record_account_conflict('a6000000-0000-0000-0000-000000000002', 1, 2, '{}'::jsonb) $$,
  '42501', null,
  'record_account_conflict cannot be called directly'
);

select * from finish();
rollback;
