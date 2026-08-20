-- Migration 20260903100000: accounts.sort_order + reorder_accounts,
-- set_account_kind (kind becomes mutable), and card_mappings.source.
-- Fixture A = 11111111-... (base EUR), fixture B = 22222222-... (base USD).

\ir _helpers.psql

begin;
select plan(21);

select has_column('public', 'accounts', 'sort_order', 'accounts has a sort_order column');
select col_not_null('public', 'accounts', 'sort_order', 'sort_order is not null');
select has_column('public', 'card_mappings', 'source', 'card_mappings has a source column');
select has_type('public', 'card_mapping_source', 'card_mapping_source is a real enum type, not text + CHECK');

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4, sort_order)
values
  ('a8000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'Alpha', 'EUR', 0, 1),
  ('a8000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'regular', 'Bravo', 'EUR', 0, 2),
  ('a8000000-0000-0000-0000-000000000003', auth.uid(), auth.uid(), 'regular', 'Charlie', 'EUR', 0, 3);

-- A row inserted without an explicit sort_order lands last in its group, not
-- first — otherwise every new account would jump ahead of the arrangement
-- the user already made.
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a8000000-0000-0000-0000-00000000000a', auth.uid(), auth.uid(), 'regular', 'Zulu', 'EUR', 0);

select results_eq(
  $$ select sort_order from accounts where id = 'a8000000-0000-0000-0000-00000000000a' $$,
  $$ values (4) $$,
  'a new account is appended after the three that already exist in its group'
);

-- ...and the trigger is per-group, so the first investment account starts at
-- 1 rather than continuing the Everyday group's numbering.
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a8000000-0000-0000-0000-00000000000b', auth.uid(), auth.uid(), 'investment', 'Broker', 'EUR', 0);

select results_eq(
  $$ select sort_order from accounts where id = 'a8000000-0000-0000-0000-00000000000b' $$,
  $$ values (1) $$,
  'sort_order is numbered per kind group, not per owner'
);

-- ============================================================================
-- reorder_accounts
-- ============================================================================

select lives_ok(
  $$ select reorder_accounts(array[
       'a8000000-0000-0000-0000-000000000003',
       'a8000000-0000-0000-0000-000000000001',
       'a8000000-0000-0000-0000-000000000002'
     ]::uuid[]) $$,
  'reorder_accounts accepts a full ordered id list'
);

select results_eq(
  $$ select name from accounts
     where id in (
       'a8000000-0000-0000-0000-000000000001',
       'a8000000-0000-0000-0000-000000000002',
       'a8000000-0000-0000-0000-000000000003'
     ) order by sort_order $$,
  $$ values ('Charlie'), ('Alpha'), ('Bravo') $$,
  'sort_order reflects the array position, so the list re-renders in the dragged order'
);

-- The point of §1b: a reorder re-stamps the row for sync but is not an
-- edit, so it must leave `version` (and `updated_at`) exactly where they
-- were. Without this, every drag would invalidate the expectedVersion each
-- client holds and turn the next real edit into a phantom conflict.
select results_eq(
  $$ select count(distinct version) from accounts where id::text like 'a8000000%' $$,
  $$ values (1::bigint) $$,
  'reorder_accounts leaves every dragged row at the version it already had'
);

select is_empty(
  $$ select 1 from accounts where id::text like 'a8000000%' and updated_at <> created_at $$,
  'reorder_accounts does not touch updated_at either'
);

-- Ordering is deliberately NOT version-checked (see the migration's own
-- comment) — but it must still respect access. Fixture B owns none of these.
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select throws_ok(
  $$ select reorder_accounts(array['a8000000-0000-0000-0000-000000000001']::uuid[]) $$,
  'account not found or not accessible',
  'reorder_accounts refuses an account the caller cannot write'
);

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- ============================================================================
-- set_account_kind — the drag-between-sections write
-- ============================================================================

select results_eq(
  $$ select (account).kind::text
     from set_account_kind('a8000000-0000-0000-0000-000000000001', 1, 'investment') $$,
  $$ values ('investment') $$,
  'set_account_kind flips regular to investment'
);

select results_eq(
  $$ select (account).kind::text
     from set_account_kind('a8000000-0000-0000-0000-000000000001', 2, 'regular') $$,
  $$ values ('regular') $$,
  'set_account_kind flips back — the conversion is not one-way'
);

-- Unlike ordering, kind IS conflict-checked: a stale version must log to
-- sync_conflicts and change nothing, exactly like update_account.
select results_eq(
  $$ select conflict from set_account_kind('a8000000-0000-0000-0000-000000000001', 1, 'investment') $$,
  $$ values (true) $$,
  'a stale expected_version returns conflict rather than silently winning'
);

select results_eq(
  $$ select kind::text from accounts where id = 'a8000000-0000-0000-0000-000000000001' $$,
  $$ values ('regular') $$,
  'the conflicting write left kind untouched'
);

select isnt_empty(
  $$ select 1 from sync_conflicts
     where table_name = 'accounts' and row_id = 'a8000000-0000-0000-0000-000000000001' $$,
  'the conflict is recorded in sync_conflicts for Needs Review to surface'
);

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select throws_ok(
  $$ select * from set_account_kind('a8000000-0000-0000-0000-000000000001', 3, 'investment') $$,
  'account not found or not accessible',
  'set_account_kind refuses an account the caller cannot write'
);

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- ============================================================================
-- card_mappings.source provenance
-- ============================================================================

select map_card('MANUALCARD', 'a8000000-0000-0000-0000-000000000002');
select results_eq(
  $$ select source::text from card_mappings
     where owner_id = auth.uid() and card_identifier = 'MANUALCARD' $$,
  $$ values ('manual') $$,
  'map_card — the only user-facing entry point — records manual provenance'
);

select link_card_to_account(auth.uid(), 'AUTOCARD', 'a8000000-0000-0000-0000-000000000002');
select results_eq(
  $$ select source::text from card_mappings
     where owner_id = auth.uid() and card_identifier = 'AUTOCARD' $$,
  $$ values ('automatic') $$,
  'link_card_to_account defaults to automatic, so every existing capture caller is unchanged'
);

-- The load-bearing case: capture_transaction inserts a bare (owner, card)
-- placeholder with no account for an unrecognised card. That placeholder
-- takes the column default; the automatic link that follows it must still
-- be labelled automatic, not inherit 'manual' from the placeholder.
-- Written as postgres, not as the fixture: `authenticated` deliberately has
-- no INSERT grant on card_mappings (every write goes through an RPC), and
-- capture_transaction reaching this insert is exactly why it is SECURITY
-- DEFINER. Impersonating the grant would be testing a schema we do not have.
reset role;
insert into card_mappings (owner_id, card_identifier)
values ('11111111-1111-1111-1111-111111111111', 'PLACEHOLDERCARD');
set local role authenticated;

select link_card_to_account(auth.uid(), 'PLACEHOLDERCARD', 'a8000000-0000-0000-0000-000000000002');
select results_eq(
  $$ select source::text from card_mappings
     where owner_id = auth.uid() and card_identifier = 'PLACEHOLDERCARD' $$,
  $$ values ('automatic') $$,
  'an unmapped placeholder does not poison the provenance of the link that resolves it'
);

-- ...but a card the user named themselves keeps saying so, even after a
-- later capture re-links it.
select link_card_to_account(auth.uid(), 'MANUALCARD', 'a8000000-0000-0000-0000-000000000003');
select results_eq(
  $$ select source::text from card_mappings
     where owner_id = auth.uid() and card_identifier = 'MANUALCARD' $$,
  $$ values ('manual') $$,
  'provenance is never rewritten once a real account is attached'
);

select * from finish();
rollback;
