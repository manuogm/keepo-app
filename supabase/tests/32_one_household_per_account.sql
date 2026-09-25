-- The two invariants the household model has always assumed and never stated
-- (migration 20260914100000_one_household_per_account.sql), plus the leave
-- they broke when violated.
--
-- The bug: `fork_one_account` re-derived the household from the account with
-- an unconstrained `select ... into`, which in plpgsql silently takes an
-- arbitrary row when several match. With an account live in two households —
-- or a user a member of two — it could pick the wrong one, fail its own
-- membership check against a caller who *was* a member of the household being
-- forked, and abort `leave_household` entirely with "caller is not a member
-- of this account's household".
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (guest).

\ir _helpers.psql

begin;
select plan(8);

-- Asserted against `pg_indexes` rather than pgTAP's `has_index`: its
-- three-argument form is `(table, index, description)`, not
-- `(schema, table, index)`, so the obvious call looks for an index named
-- after the table and fails on a perfectly good index.
select is(
  (select count(*) from pg_indexes
   where schemaname = 'public' and indexname = 'household_members_one_household_per_user'),
  1::bigint,
  'a user belongs to at most one household, enforced by a partial unique index'
);

select is(
  (select count(*) from pg_indexes
   where schemaname = 'public' and indexname = 'household_accounts_one_household_per_account'),
  1::bigint,
  'an account is shared into at most one household, enforced by a partial unique index'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a1000000-0000-0000-0000-00000000e001', auth.uid(), auth.uid(), 'regular', 'A Joint', 'EUR', 9000000);

create temporary table leave_token on commit drop as
select create_invite(array['a1000000-0000-0000-0000-00000000e001']::uuid[], '{}'::uuid[]) as token;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select lives_ok(
  format($$ select accept_invite(%L, '{}'::uuid[], '{}'::uuid[]) $$, (select token from leave_token)),
  'the guest joins, and the owner''s account is shared into the household'
);

-- ============================================================================
-- The invariants, asserted as the database refusing to hold the bad state
-- ============================================================================

reset role;

-- A second household for the same account. Attempted as superuser, so this is
-- the *index* refusing it rather than a policy — the point is that no code
-- path, however privileged, can produce the ambiguity any more.
insert into households (id) values ('11110000-0000-0000-0000-0000000000ff');

select throws_ok(
  $$ insert into household_accounts (household_id, account_id)
     values ('11110000-0000-0000-0000-0000000000ff', 'a1000000-0000-0000-0000-00000000e001') $$,
  '23505'
);

select throws_ok(
  $$ insert into household_members (household_id, user_id)
     values ('11110000-0000-0000-0000-0000000000ff', '11111111-1111-1111-1111-111111111111') $$,
  '23505'
);

-- ============================================================================
-- The leave that used to fail
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select lives_ok(
  $$ select leave_household() $$,
  'the owner leaves a household holding a shared account — the fork no longer guesses which household it is in'
);

reset role;

select is(
  (select count(*) from household_accounts
   where account_id = 'a1000000-0000-0000-0000-00000000e001' and deleted_at is null),
  0::bigint,
  'the fork retires the sharing row, so nothing points at a household the account has left'
);

-- The owner keeps her account as it was, and the guest keeps a copy
-- (20261012100000; the old fork archived the original and copied it for both).
select is(
  (select count(*) from accounts where name = 'A Joint' and archived_at is null and deleted_at is null),
  2::bigint,
  'the owner keeps the original, unarchived, and the guest keeps a private copy'
);

select * from finish();
rollback;
