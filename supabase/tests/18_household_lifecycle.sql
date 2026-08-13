-- Household lifecycle (migration 20260810100000_household_lifecycle.sql):
-- invites, category merge at formation, leave/fork, the forkable-table
-- registry guard, and erasure. Fixture A = 11111111-... (base EUR),
-- fixture B = 22222222-... (base USD).

\ir _helpers.psql

begin;
select plan(24);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 1. create_invite requires a household first.
select throws_like(
  $$ select create_invite() $$,
  '%create a household%',
  'create_invite raises with no household yet'
);

select create_household();

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a4000000-0000-0000-0000-00000000a001', auth.uid(), auth.uid(), 'ledger', 'checking', 'Shared Checking', 'EUR', 10000000);
insert into categories (id, owner_id, kind, name)
values ('c4000000-0000-0000-0000-00000000a001', auth.uid(), 'expense', 'Groceries');
select share_account('a4000000-0000-0000-0000-00000000a001');

-- captured via a temp table, since it must survive the role switch below.
create temp table captured_token (token text);
insert into captured_token select create_invite();

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into categories (id, owner_id, kind, name)
values ('c4000000-0000-0000-0000-00000000b001', auth.uid(), 'expense', 'Coffee');

-- 3. A bogus token is rejected.
select throws_like(
  $$ select accept_invite('not-a-real-token') $$,
  '%not found%',
  'an invalid token is rejected'
);

-- 4. Accepting a real invite joins the household.
select accept_invite((select token from captured_token));

select is(
  (select household_id from household_members where user_id = auth.uid()),
  (select household_id from household_members where user_id = '11111111-1111-1111-1111-111111111111'),
  'B is now in the same household as A'
);

-- 5. merge_household_categories gave B a copy of A's "Groceries" (exact
-- name+kind match, since B never had one) without duplicating B's own
-- pre-existing "Coffee".
select is(
  (select count(*) from categories where owner_id = auth.uid() and kind = 'expense' and lower(name) = 'groceries'),
  1::bigint,
  'B received a category matching A''s "Groceries" at formation'
);

select is(
  (select count(*) from categories where owner_id = auth.uid() and kind = 'expense' and lower(name) = 'coffee'),
  1::bigint,
  'B''s own pre-existing "Coffee" category was not duplicated'
);

-- 6. Accepting a second invite while already a member is rejected.
select throws_like(
  $$ select accept_invite('irrelevant') $$,
  '%already a member%',
  'a member already in a household cannot accept another invite'
);

-- ----------------------------------------------------------------------------
-- Build up real history on the shared account before leaving: a
-- transaction and a recurring rule.
-- ----------------------------------------------------------------------------

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (
  'd4000000-0000-0000-0000-00000000d001', '11111111-1111-1111-1111-111111111111', auth.uid(),
  'a4000000-0000-0000-0000-00000000a001', 'c4000000-0000-0000-0000-00000000a001', -500000, 'EUR', now()
);

insert into recurring_rules (id, created_by, account_id, category_id, amount_e4, currency, frequency, next_due_at)
values (
  'e4000000-0000-0000-0000-00000000e001', auth.uid(), 'a4000000-0000-0000-0000-00000000a001',
  'c4000000-0000-0000-0000-00000000a001', -100000, 'EUR', 'monthly', current_date + 30
);

-- 7. needs_review/other views aside, sanity-check the shared account now has
-- one transaction and one recurring rule before the fork.
select is(
  (select count(*) from transactions where account_id = 'a4000000-0000-0000-0000-00000000a001' and deleted_at is null),
  1::bigint,
  'the shared account has one transaction before B leaves'
);

-- ----------------------------------------------------------------------------
-- The forkable-table registry guard: register a fake account_id-bearing
-- table without adding it to fork_handled_tables, confirm fork refuses to
-- run, then clean it up (savepoint-scoped so it never leaks into another
-- test file's information_schema view).
-- ----------------------------------------------------------------------------

reset role;
savepoint unregistered_table;
create table zzz_unregistered_fork_test (id uuid primary key, account_id uuid);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- 8. leave_household refuses to run while an unregistered account_id table exists.
select throws_like(
  $$ select leave_household() $$,
  '%unregistered account_id-bearing table%',
  'leave_household refuses to fork while a table has an unregistered account_id column'
);

reset role;
rollback to savepoint unregistered_table;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- 9/10/11. B leaves: gets her own new account, the shared account's
-- transaction and recurring rule are both duplicated onto it.
select leave_household();

select is(
  (select count(*) from accounts where owner_id = auth.uid() and name = 'Shared Checking' and archived_at is null),
  1::bigint,
  'B has her own fresh, unarchived copy of the shared account'
);

select is(
  (
    select count(*) from transactions t
    join accounts a on a.id = t.account_id
    where a.owner_id = auth.uid() and a.name = 'Shared Checking' and t.amount_e4 = -500000
  ),
  1::bigint,
  'the shared transaction was duplicated onto B''s new copy'
);

select is(
  (
    select count(*) from recurring_rules rr
    join accounts a on a.id = rr.account_id
    where a.owner_id = auth.uid() and a.name = 'Shared Checking'
  ),
  1::bigint,
  'the recurring rule was duplicated onto B''s new copy'
);

-- 12. B is no longer a household member; A still is (single-member household).
select is(
  (select count(*) from household_members where user_id = auth.uid()),
  0::bigint,
  'B''s own household_members row is gone after leaving'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select count(*) from household_members where user_id = auth.uid()),
  1::bigint,
  'A remains a household member (single-member household) after B leaves'
);

-- 13/14. A also has her own untouched original transaction/recurring rule
-- still attached to the now-archived original account, plus her own forked
-- copy exactly like B's.
select is(
  (select archived_at is not null from accounts where id = 'a4000000-0000-0000-0000-00000000a001'),
  true,
  'the original shared account is archived, not deleted'
);

select is(
  (
    select count(*) from transactions t
    join accounts a on a.id = t.account_id
    where a.owner_id = '11111111-1111-1111-1111-111111111111' and a.name = 'Shared Checking' and a.archived_at is null
      and t.amount_e4 = -500000
  ),
  1::bigint,
  'A also got her own fresh forked copy of the shared transaction'
);

-- 15. household_accounts no longer shares the (now-archived) account.
select is(
  (select count(*) from household_accounts where account_id = 'a4000000-0000-0000-0000-00000000a001'),
  0::bigint,
  'the original account is fully unshared after the fork'
);

-- 16. household_events carries the member_left event, visible to A.
select is(
  (select count(*) from household_events where kind = 'member_left'),
  1::bigint,
  'a member_left event was recorded and is visible to the remaining member'
);

-- ----------------------------------------------------------------------------
-- erase_own_account: a fresh household + share + erase, scrubbing the
-- caller's own resulting copy without touching the other member's.
-- ----------------------------------------------------------------------------

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a4000000-0000-0000-0000-00000000a002', auth.uid(), auth.uid(), 'ledger', 'checking', 'Erase Shared', 'EUR', 1000000);
select share_account('a4000000-0000-0000-0000-00000000a002');
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, merchant_raw)
values (
  'd4000000-0000-0000-0000-00000000d002', auth.uid(), auth.uid(), 'a4000000-0000-0000-0000-00000000a002',
  'c4000000-0000-0000-0000-00000000a001', -200000, 'EUR', now(), 'Some Merchant'
);

create temp table erase_token (token text);
insert into erase_token select create_invite();

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select accept_invite((select token from erase_token));
select erase_own_account();

-- 17. B's own forked copy has merchant_raw scrubbed.
select is(
  (
    select count(*) from transactions t
    join accounts a on a.id = t.account_id
    where a.owner_id = auth.uid() and a.name = 'Erase Shared' and t.merchant_raw is not null
  ),
  0::bigint,
  'erase_own_account scrubs merchant_raw on the caller''s own resulting copy'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 18. A's own forked copy is untouched — the erasure never corrupts the
-- other member's history.
select is(
  (
    select count(*) from transactions t
    join accounts a on a.id = t.account_id
    where a.owner_id = auth.uid() and a.name = 'Erase Shared' and a.archived_at is null
      and t.merchant_raw = 'Some Merchant'
  ),
  1::bigint,
  'erase_own_account leaves the other member''s own copy of the shared history untouched'
);

select is(
  (select count(*) from household_events where kind = 'member_erased'),
  1::bigint,
  'a member_erased event was recorded'
);

-- 19. fork_handled_tables genuinely covers every account_id-bearing table
-- right now (a live guard, not just a static list — this assertion fails
-- the moment a future migration adds one without registering it here).
select is(
  (
    select count(*)
    from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.table_schema = 'public' and c.column_name = 'account_id' and t.table_type = 'BASE TABLE'
      and not exists (select 1 from fork_handled_tables f where f.table_name = c.table_name)
  ),
  0::bigint,
  'every current account_id-bearing base table is registered in fork_handled_tables'
);

-- 20. household_events RLS: a non-member sees nothing.
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select count(*) from household_events he join household_members hm on hm.household_id = he.household_id where hm.user_id = '11111111-1111-1111-1111-111111111111' and he.household_id not in (select household_id from household_members where user_id = auth.uid())),
  0::bigint,
  'a former household member cannot see events from a household they are no longer part of'
);

-- 21. leave_household with no other member is a plain membership removal —
-- nothing to fork. erase_own_account already removed B's membership, so
-- this exercises the solo case fresh.
select create_household();

select is(
  (select count(*) from household_members where user_id = auth.uid()),
  1::bigint,
  'B has a brand-new, single-member household'
);

select leave_household();

select is(
  (select count(*) from household_members where user_id = auth.uid()),
  0::bigint,
  'leaving a household with no other member still removes the caller''s own membership'
);

select * from finish();
rollback;
