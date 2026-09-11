-- A tag pruned in the report comes back if the household is abandoned, with
-- its transactions (migration 20260922100000).
--
-- `delete_tag_retagging` moves every link off the doomed tag and onto the
-- destination. After the fact nothing on the server could say which of the
-- destination's transactions had arrived that way, so a discard gave both
-- members back their accounts and their categories and left one tag deleted
-- and somebody's history wearing a label they never chose.
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (guest).

\ir _helpers.psql

begin;
select plan(9);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a1000000-0000-0000-0000-000000008001', auth.uid(), auth.uid(), 'regular', 'A Current', 'EUR', 5000000);

insert into categories (id, owner_id, kind, name, icon, color)
values ('c1000000-0000-0000-0000-000000008001', auth.uid(), 'expense', 'A Dining', 'fork', '#FF0000');

insert into tags (id, owner_id, name) values
  ('7a900000-0000-0000-0000-000000008001', auth.uid(), 'Holiday');

-- Two of the owner's own transactions: one wears Holiday, one wears Holidays
-- *and* has a tombstoned Holiday link — the collision branch the prune has to
-- revive, and therefore the branch the undo has to re-tombstone.
insert into transactions (
  id, owner_id, created_by, account_id, category_id, category_kind, currency,
  amount_e4, occurred_at, merchant_raw
) values
  ('7c000000-0000-0000-0000-000000008001', auth.uid(), auth.uid(),
   'a1000000-0000-0000-0000-000000008001', 'c1000000-0000-0000-0000-000000008001',
   'expense', 'EUR', -12300, now(), 'Pizza'),
  ('7c000000-0000-0000-0000-000000008002', auth.uid(), auth.uid(),
   'a1000000-0000-0000-0000-000000008001', 'c1000000-0000-0000-0000-000000008001',
   'expense', 'EUR', -45600, now(), 'Hotel');

create temporary table prune_token on commit drop as
select create_invite(array['a1000000-0000-0000-0000-000000008001']::uuid[], '{}'::uuid[]) as token;

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into tags (id, owner_id, name) values
  ('7b900000-0000-0000-0000-000000008001', auth.uid(), 'Holidays');

select accept_invite((select token from prune_token), '{}'::uuid[], '{}'::uuid[]);

-- The account is shared now, so the guest can put *their* tag on the owner's
-- transactions — `transaction_tags_insert` wants `can_read_tag`, and a tag's
-- owner is the one person who can always read it. The owner cannot do this
-- for them: they may not read the guest's tag until it is already on a shared
-- transaction, which is the state being set up.
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into transaction_tags (transaction_id, tag_id, owner_id) values
  ('7c000000-0000-0000-0000-000000008001', '7b900000-0000-0000-0000-000000008001', auth.uid()),
  ('7c000000-0000-0000-0000-000000008002', '7b900000-0000-0000-0000-000000008001', auth.uid());

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into transaction_tags (transaction_id, tag_id, owner_id) values
  ('7c000000-0000-0000-0000-000000008002', '7a900000-0000-0000-0000-000000008001', auth.uid());

-- ...and then removes it again, leaving exactly the tombstone the prune's
-- first branch has to revive — and therefore the one the undo has to put back.
update transaction_tags set deleted_at = now()
where transaction_id = '7c000000-0000-0000-0000-000000008002'
  and tag_id = '7a900000-0000-0000-0000-000000008001';

reset role;
create temporary table links_before on commit drop as
select transaction_id, tag_id, deleted_at is null as live from transaction_tags;
grant select on links_before to authenticated;

select is(
  (select count(*) from links_before where live),
  2::bigint,
  'two live labels between the two transactions before the report touches anything'
);

-- ============================================================================
-- The prune
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  delete_tag_retagging(
    '7b900000-0000-0000-0000-000000008001', '7a900000-0000-0000-0000-000000008001'
  ),
  2,
  'pruning Holidays moves both of its transactions onto Holiday'
);

reset role;

select is(
  (select count(*) from transaction_tags
   where tag_id = '7a900000-0000-0000-0000-000000008001' and deleted_at is null),
  2::bigint,
  'both transactions now wear the surviving tag'
);

select cmp_ok(
  (select count(*) from household_retagged_links l
   join household_pruned_tags p on p.id = l.prune_id),
  '>=', 3::bigint,
  'and every row the prune touched was written down, collision included'
);

-- ============================================================================
-- The regression
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select discard_household();

reset role;

select is(
  (select deleted_at is null from tags where id = '7b900000-0000-0000-0000-000000008001'),
  true,
  'discarding the household brings the pruned tag back'
);

select results_eq(
  $$ select transaction_id, tag_id, deleted_at is null as live
     from transaction_tags order by transaction_id, tag_id $$,
  $$ select transaction_id, tag_id, live from links_before
     order by transaction_id, tag_id $$,
  'and every label is exactly where it was — moved back, revived tombstone re-tombstoned'
);

select is(
  (select count(*) from household_pruned_tags),
  0::bigint,
  'the log goes with the household it belonged to'
);

-- ============================================================================
-- Accepting the report is what makes it permanent
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- The owner's own tag this time: the household they just made is a household
-- of one, and pruning the other member's needs them to still be in it.
insert into tags (id, owner_id, name)
values ('7a900000-0000-0000-0000-000000008002', auth.uid(), 'Holidyas');

select create_household();
select delete_tag_retagging(
  '7a900000-0000-0000-0000-000000008002', '7a900000-0000-0000-0000-000000008001'
);
select finalize_household();

reset role;

select is(
  (select count(*) from household_pruned_tags),
  0::bigint,
  'finishing drops the log, so no later abort can reach back and revert this prune'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select discard_household();

reset role;

select is(
  (select deleted_at is not null from tags where id = '7a900000-0000-0000-0000-000000008002'),
  true,
  'and a prune the owner accepted stays accepted'
);

select * from finish();
rollback;
