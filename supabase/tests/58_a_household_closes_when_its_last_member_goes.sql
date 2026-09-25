-- A household closes when its last member goes
-- (20261016100000_a_household_closes_when_its_last_member_goes.sql).
--
--   1. The only member leaves: the household closes, its pending invite is
--      revoked, and that invite can no longer be accepted into it.
--   2. Both members leave: closed.
--   3. One of two erases: still open. The other erases too: closed.
--   4. `discard_household`: closed.
--   5. Account deletion still closes it, now through the trigger
--      (29_delete_own_account covers the rest of that path).
--
-- Fixture A = 11111111-... , fixture B = 22222222-... . Tokens and household
-- ids ride in custom settings, since `authenticated` cannot create a temp
-- table.

\ir _helpers.psql

begin;
select plan(10);

create function pg_temp.is_closed(p_household text) returns boolean
language sql as $$
  select deleted_at is not null from public.households where id = p_household::uuid
$$;

-- ============================================================================
-- 1. The only member leaves
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select create_household();
select set_config('t.h1', my_household_id()::text, true);
select set_config('t.token1', create_invite('{}'::uuid[], '{}'::uuid[]), true);
select leave_household();
reset role;

select ok(pg_temp.is_closed(current_setting('t.h1')), 'the only member leaving closes the household');

select is(
  (select status::text from household_invites where household_id = current_setting('t.h1')::uuid),
  'revoked',
  'its pending invite is revoked'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select throws_ok(
  $$ select accept_invite(current_setting('t.token1'), '{}'::uuid[], '{}'::uuid[]) $$,
  'invite not found, already used, or expired',
  'nobody can join a closed household through an old invite'
);
reset role;

-- ============================================================================
-- 2. Both members leave
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select lives_ok($$ select create_household() $$, 'the member who left can start a new household');
select set_config('t.h2', my_household_id()::text, true);
select set_config('t.token2', create_invite('{}'::uuid[], '{}'::uuid[]), true);

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select accept_invite(current_setting('t.token2'), '{}'::uuid[], '{}'::uuid[]);
select leave_household();
reset role;

select ok(pg_temp.is_closed(current_setting('t.h2')), 'a leave, which ends both memberships, closes the household');

-- ============================================================================
-- 3. Erasing, one member at a time
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select create_household();
select set_config('t.h3', my_household_id()::text, true);
select set_config('t.token3', create_invite('{}'::uuid[], '{}'::uuid[]), true);

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select accept_invite(current_setting('t.token3'), '{}'::uuid[], '{}'::uuid[]);

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select erase_own_account();
reset role;

select ok(not pg_temp.is_closed(current_setting('t.h3')), 'a household with a member left stays open');

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select erase_own_account();
reset role;

select ok(pg_temp.is_closed(current_setting('t.h3')), 'the last member erasing closes it');

-- ============================================================================
-- 4. Discarding
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select create_household();
select set_config('t.h4', my_household_id()::text, true);
select set_config('t.token4', create_invite('{}'::uuid[], '{}'::uuid[]), true);

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select accept_invite(current_setting('t.token4'), '{}'::uuid[], '{}'::uuid[]);
select discard_household();
reset role;

select ok(pg_temp.is_closed(current_setting('t.h4')), 'discarding the household closes it');

-- ============================================================================
-- 5. Account deletion, through the trigger
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select create_household();
select set_config('t.h5', my_household_id()::text, true);
select delete_own_account();
reset role;

select ok(pg_temp.is_closed(current_setting('t.h5')), 'deleting the only member''s account closes the household');

select is(
  (select count(*) from households h
   where h.deleted_at is null
     and h.id in (
       current_setting('t.h1')::uuid, current_setting('t.h2')::uuid, current_setting('t.h3')::uuid,
       current_setting('t.h4')::uuid, current_setting('t.h5')::uuid
     )),
  0::bigint,
  'no household made here is left open'
);

select * from finish();
rollback;
