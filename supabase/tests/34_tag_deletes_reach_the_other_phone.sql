-- Deleting a tag revokes the other member's sight of it, and a revocation
-- has to be announced (migration 20260918100000).
--
-- The bug: `can_read_tag` admits somebody else's tag only while it sits on a
-- live transaction of a shared account. `delete_tag_retagging` empties that
-- set and *then* tombstones the tag — so the member who pressed the button
-- can no longer see the row they just deleted, `pull_changes` never carries
-- the tombstone, and the report goes on listing a tag the server has
-- retired. Two devices, reproduced: server clean, phone unchanged.
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (guest).

\ir _helpers.psql

begin;
select plan(9);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a1000000-0000-0000-0000-00000000d001', auth.uid(), auth.uid(), 'regular', 'A Current', 'EUR', 5000000);

insert into tags (id, owner_id, name)
values ('7a900000-0000-0000-0000-00000000d001', auth.uid(), 'Holiday');

create temporary table tag_token on commit drop as
select create_invite(array['a1000000-0000-0000-0000-00000000d001']::uuid[], '{}'::uuid[]) as token;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a2000000-0000-0000-0000-00000000d001', auth.uid(), auth.uid(), 'regular', 'B Current', 'USD', 3000000);

insert into categories (id, owner_id, kind, name, icon, color)
values ('c2000000-0000-0000-0000-00000000d001', auth.uid(), 'expense', 'B Dining', 'fork', '#0000FF');

insert into tags (id, owner_id, name)
values ('7b900000-0000-0000-0000-00000000d001', auth.uid(), 'Holidays');

-- Two transactions on the guest's account, so the move has something to move
-- and the "revive a colliding tombstone" branch is exercised alongside it.
insert into transactions (
  id, owner_id, created_by, account_id, category_id, category_kind, currency,
  amount_e4, occurred_at, merchant_raw
) values
  ('7c000000-0000-0000-0000-00000000d001', auth.uid(), auth.uid(),
   'a2000000-0000-0000-0000-00000000d001', 'c2000000-0000-0000-0000-00000000d001',
   'expense', 'USD', -12300, now(), 'Pizza'),
  ('7c000000-0000-0000-0000-00000000d002', auth.uid(), auth.uid(),
   'a2000000-0000-0000-0000-00000000d001', 'c2000000-0000-0000-0000-00000000d001',
   'expense', 'USD', -45600, now(), 'Hotel');

insert into transaction_tags (transaction_id, tag_id, owner_id) values
  ('7c000000-0000-0000-0000-00000000d001', '7b900000-0000-0000-0000-00000000d001', auth.uid()),
  ('7c000000-0000-0000-0000-00000000d002', '7b900000-0000-0000-0000-00000000d001', auth.uid());

select accept_invite(
  (select token from tag_token),
  array['a2000000-0000-0000-0000-00000000d001']::uuid[],
  '{}'::uuid[]
);

-- ============================================================================
-- The guest's tag is visible to the owner *because* it sits on a shared
-- transaction — the whole basis the delete is about to remove.
-- ============================================================================

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select ok(
  can_read_tag('7b900000-0000-0000-0000-00000000d001'),
  'the owner can read the guest''s tag while it is on a shared transaction'
);

-- `household_sharing_tag` is an internal helper — granted to nobody, called
-- only from the two SECURITY DEFINER bodies that need it — so it is asked as
-- the superuser, with the household id carried over from the caller's view.
create temporary table my_house on commit drop as select my_household_id() as id;

reset role;

select is(
  household_sharing_tag('7b900000-0000-0000-0000-00000000d001'),
  (select id from my_house),
  'household_sharing_tag names the household that can currently see it'
);

create temporary table epochs_before on commit drop as
select id, sync_epoch from profiles
where id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
grant select on epochs_before to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  delete_tag_retagging(
    '7b900000-0000-0000-0000-00000000d001', '7a900000-0000-0000-0000-00000000d001'
  ),
  2,
  'both of the guest''s transactions move onto the owner''s tag'
);

-- ============================================================================
-- The regression
-- ============================================================================

select ok(
  not can_read_tag('7b900000-0000-0000-0000-00000000d001'),
  'and the owner immediately loses sight of the tag they just deleted — which is why no incremental pull can carry its tombstone'
);

select is(
  (select count(*) from jsonb_array_elements(payload->'tags') as e
   where (e->>'id')::uuid = '7b900000-0000-0000-0000-00000000d001'),
  0::bigint,
  'pull_changes confirms it: the tombstone is not in the owner''s payload'
)
from pull_changes(0, 0);

reset role;

select results_ne(
  $$ select p.sync_epoch from profiles p join epochs_before b on b.id = p.id order by p.id $$,
  $$ select b.sync_epoch from epochs_before b order by b.id $$,
  'so both members'' epochs move instead, and their devices re-pull in full'
);

select is(
  (select count(*) from transaction_tags
   where tag_id = '7a900000-0000-0000-0000-00000000d001' and deleted_at is null),
  2::bigint,
  'the transactions kept a label — re-tagging is not a way to lose one'
);

-- ============================================================================
-- The other road to the same revocation: a plain soft delete, which is what
-- the Tags screen writes. The cascade trigger is the one that must announce
-- it there.
-- ============================================================================

create temporary table epochs_mid on commit drop as
select id, sync_epoch from profiles
where id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');

update tags set deleted_at = now() where id = '7a900000-0000-0000-0000-00000000d001';

select results_ne(
  $$ select p.sync_epoch from profiles p join epochs_mid m on m.id = p.id order by p.id $$,
  $$ select m.sync_epoch from epochs_mid m order by m.id $$,
  'deleting your own shared tag outright bumps both epochs too — the guest''s device would otherwise keep it'
);

-- A tag nobody else could see revokes nothing, and must not cost two devices
-- a full re-pull.
create temporary table epochs_private on commit drop as
select id, sync_epoch from profiles
where id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');

insert into tags (id, owner_id, name)
values ('7a900000-0000-0000-0000-00000000d002', '11111111-1111-1111-1111-111111111111', 'Private');
update tags set deleted_at = now() where id = '7a900000-0000-0000-0000-00000000d002';

select results_eq(
  $$ select p.sync_epoch from profiles p join epochs_private v on v.id = p.id order by p.id $$,
  $$ select v.sync_epoch from epochs_private v order by v.id $$,
  'a tag no other member could see leaves both epochs alone'
);

select * from finish();
rollback;
