-- A soft delete has to stay readable to whoever needs to hear about it
-- (migration 20260916100000_merge_tombstones_reach_the_other_phone.sql).
--
-- The bug: `apply_category_merges` retired each redundant twin with
-- `deleted_at = now(), shared_group_id = null`, and `can_read_category`
-- admits another member's category only while `shared_group_id is not null`.
-- So the statement that deleted the row was the same statement that hid it
-- from the member who had to be told. `pull_changes` is incremental and
-- RLS-scoped — a tombstone you cannot see is a tombstone you never receive —
-- and the other phone kept the twin, live, inside the merged group. On
-- screen that is a merge that "did nothing".
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (guest).

\ir _helpers.psql

begin;
select plan(7);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a1000000-0000-0000-0000-00000000c001', auth.uid(), auth.uid(), 'regular', 'A Current', 'EUR', 5000000);

insert into categories (id, owner_id, kind, name, icon, color)
values ('c1000000-0000-0000-0000-00000000c001', auth.uid(), 'expense', 'Dine Out', 'fork.knife', '#FF0000');

create temporary table merge_token on commit drop as
select create_invite(
  array['a1000000-0000-0000-0000-00000000c001']::uuid[],
  array['c1000000-0000-0000-0000-00000000c001']::uuid[]
) as token;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into categories (id, owner_id, kind, name, icon, color)
values ('c2000000-0000-0000-0000-00000000c001', auth.uid(), 'expense', 'Dining Out', 'cart.fill', '#0000FF');

select accept_invite(
  (select token from merge_token), '{}'::uuid[],
  array['c2000000-0000-0000-0000-00000000c001']::uuid[]
);

-- Both spellings differ, so `ensure_category_twin` created a copy on each
-- side: four rows, two groups, and the merge below is the statement that
-- they were only ever two categories.
reset role;
create temporary table twins on commit drop as
select id, owner_id from categories
where id not in ('c1000000-0000-0000-0000-00000000c001', 'c2000000-0000-0000-0000-00000000c001')
  and shared_group_id is not null and deleted_at is null;
-- Temp tables belong to the superuser that made them; the assertions below
-- read them back as `authenticated`.
grant select on twins to authenticated;

select is((select count(*) from twins), 2::bigint, 'sharing two near-miss names mints one twin each');

-- The epochs as they stand before the merge. The common path must not move
-- them: a full re-pull per merge would make the owner's report stutter
-- through a wipe on every tap.
create temporary table epochs_before on commit drop as
select id, sync_epoch from profiles
where id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
grant select on epochs_before to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  apply_category_merges(
    '[{"mine":"c1000000-0000-0000-0000-00000000c001","theirs":"c2000000-0000-0000-0000-00000000c001"}]'::jsonb,
    true
  ),
  1,
  'the owner merges the two originals'
);

-- ============================================================================
-- The regression
-- ============================================================================

-- Still the owner: this is the caller's own view, under RLS, and the twin in
-- question belongs to the *guest*. Before the fix `can_read_category` said
-- false and this returned 0.
select is(
  (select count(*) from categories c
   join twins t on t.id = c.id
   where c.owner_id = '22222222-2222-2222-2222-222222222222' and c.deleted_at is not null),
  1::bigint,
  'the owner can still read the guest''s retired twin — the delete they have to be told about'
);

select is(
  (select count(*) from jsonb_array_elements(payload->'categories') as e
   where (e->>'deleted_at') is not null
     and (e->>'owner_id')::uuid = '22222222-2222-2222-2222-222222222222'),
  1::bigint,
  'and pull_changes carries that tombstone to their phone'
)
from pull_changes(0, 0);

reset role;

select is(
  (select count(*) from categories c join twins t on t.id = c.id where c.deleted_at is null),
  0::bigint,
  'both twins are retired, not released — neither member keeps a private copy of the other''s spelling'
);

select results_eq(
  $$ select p.sync_epoch from profiles p join epochs_before b on b.id = p.id order by p.id $$,
  $$ select b.sync_epoch from epochs_before b order by b.id $$,
  'a merge whose twins all retired cleanly leaves both epochs alone'
);

-- ============================================================================
-- Unmerging is a revocation, and there is no tombstone that can say so
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select unmerge_category_group(
  (select shared_group_id from categories where id = 'c1000000-0000-0000-0000-00000000c001')
);

reset role;

select results_eq(
  $$ select p.sync_epoch - b.sync_epoch from profiles p join epochs_before b on b.id = p.id order by p.id $$,
  $$ values (1::bigint), (1::bigint) $$,
  'unmerging takes a live row out of both members'' sight, so both are forced to re-pull in full'
);

select * from finish();
rollback;
