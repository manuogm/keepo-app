-- A device holds one cursor; `sync_domain_id` can move a user to a different
-- ticket sequence (migration 20260919100000).
--
-- The bug: a brand-new household domain starts at `next_ticket = 1`, while
-- the member's cursor is the high-water mark of their own history. Every
-- category twin, merge and tag prune the household writes is stamped below
-- that cursor, so `pull_changes` matches none of them and returns an empty
-- payload **with no error** — the household's own writes are invisible to
-- its own members. Invisible on a seeded account, instant on a real one,
-- which is why it survived two rounds of two-device testing.
--
-- Fixture A = 11111111-... (owner, given real history below),
-- fixture B = 22222222-... (guest).

\ir _helpers.psql

begin;
select plan(7);

-- A is a long-standing user: their private domain has issued ~5,000 tickets
-- and their rows carry them. This is the whole precondition — on a fresh
-- account the household's sequence overtakes the cursor within the ceremony
-- and nothing is ever seen to break.
insert into sync_tickets (domain_id, next_ticket)
values ('11111111-1111-1111-1111-111111111111', 5000)
on conflict (domain_id) do update set next_ticket = 5000;

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a1000000-0000-0000-0000-00000000e001', auth.uid(), auth.uid(), 'regular', 'A Current', 'EUR', 5000000);

insert into categories (id, owner_id, kind, name, icon, color)
values ('c1000000-0000-0000-0000-00000000e001', auth.uid(), 'expense', 'Dine Out', 'fork.knife', '#FF0000');

reset role;
create temporary table before_join on commit drop as select max(sync_seq) as cursor from categories;
grant select on before_join to authenticated;

select cmp_ok(
  (select cursor from before_join), '>=', 5000::bigint,
  'the owner arrives holding a cursor in the thousands'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select create_household();

create temporary table join_token on commit drop as
select create_invite(
  array['a1000000-0000-0000-0000-00000000e001']::uuid[],
  array['c1000000-0000-0000-0000-00000000e001']::uuid[]
) as token;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into categories (id, owner_id, kind, name, icon, color)
values ('c2000000-0000-0000-0000-00000000e001', auth.uid(), 'expense', 'Dining Out', 'cart.fill', '#0000FF');

select accept_invite((select token from join_token), '{}'::uuid[],
  array['c2000000-0000-0000-0000-00000000e001']::uuid[]);

-- ============================================================================
-- The regression
-- ============================================================================

reset role;
create temporary table house on commit drop as
select household_id as id from household_members
where user_id = '11111111-1111-1111-1111-111111111111' and deleted_at is null;
grant select on house to authenticated;

select cmp_ok(
  (select next_ticket from sync_tickets where domain_id = (select id from house)),
  '>', (select cursor from before_join),
  'the household domain starts ahead of the cursor its members already hold'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  apply_category_merges(
    '[{"mine":"c1000000-0000-0000-0000-00000000e001","theirs":"c2000000-0000-0000-0000-00000000e001"}]'::jsonb,
    true
  ),
  1,
  'the owner merges the two near-misses'
);

select cmp_ok(
  (select min(sync_seq) from categories
   where id in ('c1000000-0000-0000-0000-00000000e001','c2000000-0000-0000-0000-00000000e001')),
  '>', (select cursor from before_join),
  'and both merged rows are stamped above that cursor, not below it'
);

-- The assertion the whole migration exists for. Before it this returned 0.
select cmp_ok(
  (select jsonb_array_length(payload->'categories') from pull_changes((select cursor from before_join), 0)),
  '>', 0,
  'so the owner''s own pull actually carries the merge it just made'
);

-- ============================================================================
-- Leaving strands the cursor in the other direction
--
-- The departing member goes back to their own sequence, which stopped the day
-- they joined while their rows climbed into the household's.
-- ============================================================================

select leave_household();

reset role;

select cmp_ok(
  (select next_ticket from sync_tickets
   where domain_id = '11111111-1111-1111-1111-111111111111'),
  '>', (select max(sync_seq) from categories),
  'leaving lifts the member''s own domain back above everything they can see'
);

-- A domain already ahead has stranded nobody, and saying otherwise would cost
-- its members a full re-pull for nothing.
select ok(
  not raise_sync_domain('11111111-1111-1111-1111-111111111111'),
  'a domain that is already ahead is left alone'
);

select * from finish();
rollback;
