-- A merge keeps a copy of the two categories it was made of, and Unmerge
-- puts them back (migration 20260920100000).
--
-- Before this, `apply_category_merges` wrote the resultant identity onto both
-- rows and nothing anywhere remembered the originals — so the report's merge
-- sheet drew the same tile twice, and Unmerge released two rows still wearing
-- a name neither of them started with.
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (guest).

\ir _helpers.psql

begin;
select plan(10);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

insert into categories (id, owner_id, kind, name, icon, color) values
  ('c1000000-0000-0000-0000-00000000f001', auth.uid(), 'expense', 'Dine Out',  'icon-fork', '#FF0000'),
  ('c1000000-0000-0000-0000-00000000f002', auth.uid(), 'expense', 'Groceries', 'icon-cart', '#00FF00');

create temporary table merge_memory_token on commit drop as
select create_invite(
  '{}'::uuid[],
  array['c1000000-0000-0000-0000-00000000f001', 'c1000000-0000-0000-0000-00000000f002']::uuid[]
) as token;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into categories (id, owner_id, kind, name, icon, color) values
  ('c2000000-0000-0000-0000-00000000f001', auth.uid(), 'expense', 'Dining Out', 'icon-plate',  '#0000FF'),
  ('c2000000-0000-0000-0000-00000000f002', auth.uid(), 'expense', 'Groceries',  'icon-basket', '#0044FF');

select accept_invite(
  (select token from merge_memory_token), '{}'::uuid[],
  array['c2000000-0000-0000-0000-00000000f001', 'c2000000-0000-0000-0000-00000000f002']::uuid[]
);

-- ============================================================================
-- The exact-name merge happens inside `accept_invite`, via
-- `ensure_category_twin`'s second branch. The names match by definition
-- there; the icons do not, and losing one to the propagate trigger is exactly
-- what the capture is for.
-- ============================================================================

reset role;

select is(
  (select pre_merge_icon from categories where id = 'c2000000-0000-0000-0000-00000000f002'),
  'icon-basket',
  'an exact-name automatic merge still remembers the icon it overwrote'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  apply_category_merges(
    '[{"mine":"c1000000-0000-0000-0000-00000000f001","theirs":"c2000000-0000-0000-0000-00000000f001",
       "name":"Nights Out","icon":"icon-moon","color":"#123456"}]'::jsonb,
    false
  ),
  1,
  'the owner merges Dine Out with Dining Out under a name of their own'
);

reset role;

select results_eq(
  $$ select name, pre_merge_name, pre_merge_icon, pre_merge_color from categories
     where id = 'c1000000-0000-0000-0000-00000000f001' $$,
  $$ values ('Nights Out'::text, 'Dine Out'::text, 'icon-fork'::text, '#FF0000'::text) $$,
  'the owner''s row reads the resultant and remembers its own'
);

select results_eq(
  $$ select name, pre_merge_name, pre_merge_icon, pre_merge_color from categories
     where id = 'c2000000-0000-0000-0000-00000000f001' $$,
  $$ values ('Nights Out'::text, 'Dining Out'::text, 'icon-plate'::text, '#0000FF'::text) $$,
  'and so does theirs — which is what the report''s two tiles finally have to show'
);

-- Merging again must not overwrite the capture with the intermediate name:
-- what the user wants back is the category they started with.
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  apply_category_merges(
    '[{"mine":"c1000000-0000-0000-0000-00000000f001","theirs":"c2000000-0000-0000-0000-00000000f001",
       "name":"Going Out"}]'::jsonb,
    false
  ),
  1,
  'the owner renames the merge by applying it again'
);

reset role;

select is(
  (select pre_merge_name from categories where id = 'c1000000-0000-0000-0000-00000000f001'),
  'Dine Out',
  'a second merge over the same row keeps the first capture, not the intermediate name'
);

-- ============================================================================
-- Unmerge is an undo
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select unmerge_category_group(
  (select shared_group_id from categories where id = 'c1000000-0000-0000-0000-00000000f001')
);

reset role;

select results_eq(
  $$ select name, icon, color, pre_merge_name from categories
     where id in ('c1000000-0000-0000-0000-00000000f001', 'c2000000-0000-0000-0000-00000000f001')
     order by name $$,
  $$ values ('Dine Out'::text,   'icon-fork'::text,  '#FF0000'::text, null::text),
            ('Dining Out'::text, 'icon-plate'::text, '#0000FF'::text, null::text) $$,
  'unmerging restores both identities and drops the capture with them'
);

-- Each original back in a shared group of its own, one row per member: the
-- shape the report draws under Extra, which is where they were before.
select is(
  (select count(*) from (
     select shared_group_id from categories
     where shared_group_id is not null and deleted_at is null
       and name in ('Dine Out', 'Dining Out')
     group by shared_group_id having count(*) = 2
   ) g),
  2::bigint,
  'and re-shares each one separately, so both land back under Extra'
);

-- ============================================================================
-- Two rows that were always called the same thing were never twinned, so
-- there is no Extra shape to go back to — and re-sharing them would walk
-- straight into the exact-name branch and merge them again.
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select unmerge_category_group(
  (select shared_group_id from categories where id = 'c1000000-0000-0000-0000-00000000f002')
);

reset role;

select is(
  (select count(*) from categories
   where id in ('c1000000-0000-0000-0000-00000000f002', 'c2000000-0000-0000-0000-00000000f002')
     and shared_group_id is null and merge_origin is null),
  2::bigint,
  'unmerging an exact-name pair leaves both private rather than re-merging them'
);

select is(
  (select icon from categories where id = 'c2000000-0000-0000-0000-00000000f002'),
  'icon-basket',
  'with the icon it arrived with restored'
);

select * from finish();
rollback;
