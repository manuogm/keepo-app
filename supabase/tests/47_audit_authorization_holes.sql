-- The database-side authorization holes found by the security audit of
-- 2026-09-21, pinned shut. Most assertions below are the exploit that
-- actually worked against the live stack before migrations 20261001100000 /
-- 20261002100000 / 20261003100000 / 20261004100000, rewritten as a test that
-- now fails if it ever works again.
--
-- Fixture A = 11111111-..., fixture B = 22222222-... (_helpers.psql). A is in
-- no household for the whole file, which is the point: every write attempted
-- here is by a complete stranger, not a household member. B joins one only in
-- the last section, and only so the self-scoped read has something to answer.

\ir _helpers.psql

begin;
select plan(18);

-- ===========================================================================
-- 20261001100000 — a sharing link is not the client's to write
-- ===========================================================================

-- B owns a category carrying a sharing group, as if it were shared with a
-- household A has nothing to do with.
insert into categories (id, owner_id, kind, name, shared_group_id)
values (
  'c0000000-0000-0000-0000-000000000047', '22222222-2222-2222-2222-222222222222',
  'expense', 'Victim Category', 'a0000000-0000-0000-0000-0000000000ff'
);

-- A owns an ordinary private one.
insert into categories (id, owner_id, kind, name)
values (
  'c0000000-0000-0000-0000-000000000048', '11111111-1111-1111-1111-111111111111',
  'expense', 'Attacker Category'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 1. The precondition that made this worth reporting: A cannot even read
--    the row A was able to overwrite.
select ok(
  not can_read_category('c0000000-0000-0000-0000-000000000047'),
  'the attacker cannot read the victim category'
);

-- 2. The root cause. shared_group_id is no longer a column the client may
--    write, so the hijack cannot even be set up.
select throws_ok(
  $$ update categories set shared_group_id = 'a0000000-0000-0000-0000-0000000000ff'
     where id = 'c0000000-0000-0000-0000-000000000048' $$,
  42501,
  null,
  'the client may not write shared_group_id'
);

-- 3. The columns the client legitimately edits still work, unchanged.
select lives_ok(
  $$ update categories set name = 'Renamed', icon = 'cart.fill', color = '#123456'
     where id = 'c0000000-0000-0000-0000-000000000048' $$,
  'name, icon and color remain editable'
);

select lives_ok(
  $$ update categories set deleted_at = now()
     where id = 'c0000000-0000-0000-0000-000000000048' $$,
  'deleted_at remains writable, so soft delete still works'
);
update categories set deleted_at = null where id = 'c0000000-0000-0000-0000-000000000048';

-- 4. The other columns that rode in on the same table-wide grant.
select throws_ok(
  $$ update categories set is_default = true
     where id = 'c0000000-0000-0000-0000-000000000048' $$,
  42501,
  null,
  'the client may not write is_default'
);

select throws_ok(
  $$ update categories set owner_id = '22222222-2222-2222-2222-222222222222'
     where id = 'c0000000-0000-0000-0000-000000000048' $$,
  42501,
  null,
  'the client may not write owner_id'
);

-- 5. Tags got the same narrowing.
reset role;
insert into tags (id, owner_id, name)
values ('7a000000-0000-0000-0000-000000000047', '11111111-1111-1111-1111-111111111111', 'Attacker Tag');
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select lives_ok(
  $$ update tags set name = 'Renamed Tag' where id = '7a000000-0000-0000-0000-000000000047' $$,
  'a tag rename still works'
);

select throws_ok(
  $$ update tags set owner_id = '22222222-2222-2222-2222-222222222222'
     where id = '7a000000-0000-0000-0000-000000000047' $$,
  42501,
  null,
  'the client may not write a tag owner_id'
);

-- 6. Belt and braces. Even with the group id planted by a privileged writer,
--    the propagation trigger no longer reaches outside the household — this
--    is the assertion that survives someone widening the grant again.
reset role;
update categories set shared_group_id = 'a0000000-0000-0000-0000-0000000000ff'
where id = 'c0000000-0000-0000-0000-000000000048';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
update categories set name = 'PWNED', icon = 'skull', color = '#FF0000'
where id = 'c0000000-0000-0000-0000-000000000048';

reset role;
select is(
  (select name from categories where id = 'c0000000-0000-0000-0000-000000000047'),
  'Victim Category',
  'the propagation trigger does not reach a stranger''s category'
);

-- 7. And unshare_category, the second exploit of the same hijack.
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select unshare_category('c0000000-0000-0000-0000-000000000048');

reset role;
select is(
  (select shared_group_id from categories where id = 'c0000000-0000-0000-0000-000000000047'),
  'a0000000-0000-0000-0000-0000000000ff'::uuid,
  'unshare_category does not sever a stranger''s sharing link'
);

-- ===========================================================================
-- 20261002100000 — a card is mapped only by its own owner
-- ===========================================================================

insert into accounts (id, owner_id, created_by, name, currency, opening_balance_e4, kind)
values (
  'acc00000-0000-0000-0000-000000000047', '22222222-2222-2222-2222-222222222222',
  '22222222-2222-2222-2222-222222222222', 'Victim Checking', 'USD', 0, 'regular'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 8. A naming somebody else as the owner is now refused at the grant, before
--    the function's own (correct, but insufficient) account check is reached.
select throws_ok(
  $$ select link_card_to_account(
       '22222222-2222-2222-2222-222222222222', 'VICTIM-CARD-0047',
       'acc00000-0000-0000-0000-000000000047', 'manual'
     ) $$,
  42501,
  null,
  'link_card_to_account is not callable by an ordinary user'
);

-- 9. map_card — the auth.uid()-scoped wrapper the client actually uses — is
--    untouched, and still refuses an account the caller does not own.
select throws_ok(
  $$ select map_card('VICTIM-CARD-0047', 'acc00000-0000-0000-0000-000000000047') $$,
  'account not found, not accessible, or archived',
  'map_card still refuses an account the caller does not own'
);

-- ===========================================================================
-- 20261003100000 — a rate-limit budget the caller cannot name
-- ===========================================================================

-- 10. The reset primitive is gone from the client's reach.
select throws_ok(
  $$ select ops_check_own_rate_limit('pull_changes', 1, 0) $$,
  42501,
  null,
  'a caller may no longer name its own rate-limit budget'
);

-- 11. The form that remains takes no budget, so there is nothing to shrink.
--     (pull_changes itself is exercised by 23_sync_primitives.sql; here we
--     only care that the entry point it now uses is callable.)
select lives_ok(
  $$ select ops_check_own_rate_limit('pull_changes') $$,
  'the budgeted form is callable by an ordinary user'
);

-- 12. An unregistered name is a programming error, not a permissive default.
select throws_ok(
  $$ select ops_check_own_rate_limit('not_a_real_rpc') $$,
  'no rate-limit budget registered for not_a_real_rpc',
  'an unregistered budget raises rather than falling back'
);

-- ===========================================================================
-- 20261004100000 — a household answers only to its own members
-- ===========================================================================

reset role;
insert into households (id) values ('40000000-0000-0000-0000-000000000047');
insert into household_members (household_id, user_id)
values ('40000000-0000-0000-0000-000000000047', '22222222-2222-2222-2222-222222222222');

-- 13. A is in no household, and asking about somebody else's now answers
--     nothing. It used to hand back the owner's user uuid.
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select is(
  household_owner_id('40000000-0000-0000-0000-000000000047'),
  null,
  'an outsider learns nothing about a household they are not in'
);

-- 14. The self-scoped question — the only one anything actually asks — is
--     untouched. This is what `household_member_profile` and the three
--     owner-only gates rely on.
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select is(
  household_owner_id(my_household_id()),
  '22222222-2222-2222-2222-222222222222'::uuid,
  'a member still gets the owner of their own household'
);

-- 15. The schema guard is an ops question, not a client one.
select throws_ok(
  $$ select unregistered_identity_columns() $$,
  42501,
  null,
  'the deletion schema guard is not reachable by an ordinary user'
);

select finish();
rollback;
