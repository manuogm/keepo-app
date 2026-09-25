-- Backing out of a household gives both members back exactly what they had
-- (migration 20260921100000).
--
-- The bug: `abort()` undid the setup with `leave_household()`, which forks
-- every shared account into a private copy per member — right for dissolving
-- a household two people have kept together, wrong for one they abandoned
-- thirty seconds in. A few build-and-abort cycles left both phones listing
-- four accounts that were two.
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (guest).

\ir _helpers.psql

begin;
select plan(11);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a1000000-0000-0000-0000-000000000091', auth.uid(), auth.uid(), 'regular', 'A Current', 'EUR', 5000000);

insert into categories (id, owner_id, kind, name, icon, color) values
  ('c1000000-0000-0000-0000-000000000091', auth.uid(), 'expense', 'Dine Out',  'icon-fork', '#FF0000'),
  ('c1000000-0000-0000-0000-000000000092', auth.uid(), 'expense', 'Groceries', 'icon-cart', '#00FF00'),
  -- The trap. A real category of A's that they made and never used: it
  -- answers "no transactions, no rule, no mapping" exactly like a minted twin
  -- does, and a discard that leans on that proxy would delete it.
  ('c1000000-0000-0000-0000-000000000093', auth.uid(), 'expense', 'Nightlife', 'icon-moon', '#9B3DE0');

create temporary table abort_token on commit drop as
select create_invite(
  array['a1000000-0000-0000-0000-000000000091']::uuid[],
  array['c1000000-0000-0000-0000-000000000091', 'c1000000-0000-0000-0000-000000000092',
        'c1000000-0000-0000-0000-000000000093']::uuid[]
) as token;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a2000000-0000-0000-0000-000000000091', auth.uid(), auth.uid(), 'regular', 'B Current', 'USD', 3000000);

insert into categories (id, owner_id, kind, name, icon, color) values
  ('c2000000-0000-0000-0000-000000000091', auth.uid(), 'expense', 'Dining Out', 'icon-plate',  '#0000FF'),
  ('c2000000-0000-0000-0000-000000000092', auth.uid(), 'expense', 'Groceries',  'icon-basket', '#0044FF');

select accept_invite(
  (select token from abort_token),
  array['a2000000-0000-0000-0000-000000000091']::uuid[],
  array['c2000000-0000-0000-0000-000000000091', 'c2000000-0000-0000-0000-000000000092']::uuid[]
);

-- The fuzzy pass the ceremony runs, so the discard has a merge to undo as
-- well as a share.
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  apply_category_merges(
    '[{"mine":"c1000000-0000-0000-0000-000000000091","theirs":"c2000000-0000-0000-0000-000000000091"}]'::jsonb,
    true
  ),
  1,
  'the ceremony merges Dine Out with Dining Out'
);

reset role;

select is(
  (select count(*) from accounts where deleted_at is null
   and owner_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')),
  2::bigint,
  'two accounts between them while the household stands'
);

select cmp_ok(
  (select count(*) from categories where created_as_twin and deleted_at is null),
  '>', 0::bigint,
  'and at least one category exists only because the household shared it'
);

create temporary table epochs_before on commit drop as
select id, sync_epoch from profiles
where id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');

-- ============================================================================
-- The regression
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select discard_household();

reset role;

select is(
  (select count(*) from accounts where deleted_at is null
   and owner_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')),
  2::bigint,
  'discarding gives nobody a copy of the other member''s account'
);

select is(
  -- Only this file's accounts: the local database the suite runs against can
  -- hold a household of its own.
  (select count(*) from household_accounts ha
   join accounts a on a.id = ha.account_id
   where ha.deleted_at is null
     and a.owner_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')),
  0::bigint,
  'and takes the listing down with it'
);

select is(
  (select count(*) from categories
   where owner_id = '11111111-1111-1111-1111-111111111111'
     and lower(name) = 'dining out'),
  0::bigint,
  'the row the sharing step minted for the owner is gone outright, not tombstoned'
);

select results_eq(
  $$ select name, icon, color, shared_group_id, merge_origin, pre_merge_name
     from categories where id = 'c1000000-0000-0000-0000-000000000091' $$,
  $$ values ('Dine Out'::text, 'icon-fork'::text, '#FF0000'::text,
             null::uuid, null::public.category_merge_origin, null::text) $$,
  'the owner''s own category is back to exactly what it was'
);

select results_eq(
  $$ select name, icon, color, shared_group_id from categories
     where id = 'c2000000-0000-0000-0000-000000000092' $$,
  $$ values ('Groceries'::text, 'icon-basket'::text, '#0044FF'::text, null::uuid) $$,
  'including the icon an exact-name automatic merge had overwritten'
);

-- The trap, sprung.
select is(
  (select count(*) from categories
   where id = 'c1000000-0000-0000-0000-000000000093' and deleted_at is null),
  1::bigint,
  'a category its owner made and never used is not mistaken for a twin'
);

select is(
  (select count(*) from household_members where deleted_at is null
   and user_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')),
  0::bigint,
  'neither of them is in a household any more'
);

select results_ne(
  $$ select p.sync_epoch from profiles p join epochs_before b on b.id = p.id order by p.id $$,
  $$ select b.sync_epoch from epochs_before b order by b.id $$,
  'and both devices are told to start over, since none of this can be pulled incrementally'
);

select * from finish();
rollback;
