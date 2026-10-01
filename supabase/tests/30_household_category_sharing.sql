-- Household category sharing and the invite flow that chooses it
-- (migration 20260912100000_household_category_sharing.sql).
--
-- The thing being asserted is the invariant the whole design rests on: a
-- shared category is **one row per member** carrying the same
-- `shared_group_id`. Get that wrong and the failure is not a wrong number, it
-- is a member who can see a category in their list and cannot put anything in
-- it — `transactions`' composite FK refusing a category they do not own.
--
-- Fixture A = 11111111-... (inviter), fixture B = 22222222-... (invitee).

\ir _helpers.psql

begin;
select plan(18);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 0. Creating a household bumps the creator's epoch. `sync_domain_id` moves
-- them into the household's own ticket sequence, which starts at 1 — below
-- whatever cursor their device already holds — so without the bump the
-- creator's own phone never pulls the household it just made, and goes on
-- offering to create one. Every other door into or out of a household already
-- bumped; this was the one that did not.
select is(
  (select sync_epoch from profiles where id = auth.uid()),
  1::bigint,
  'a fresh profile starts at epoch 1'
);

select create_household();

select is(
  (select sync_epoch from profiles where id = auth.uid()),
  2::bigint,
  'creating a household bumps the creator''s sync epoch, so their device re-pulls'
);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('ab000000-0000-0000-0000-00000000a001', auth.uid(), auth.uid(), 'regular', 'A Shared', 'EUR', 5000000),
  ('ab000000-0000-0000-0000-00000000a002', auth.uid(), auth.uid(), 'regular', 'A Private', 'EUR', 1000000);

-- "Groceries" is the one B also has, under a different spelling — the match
-- has to be case- and whitespace-insensitive or the two become separate
-- categories that look identical in both lists.
insert into categories (id, owner_id, kind, name, icon, color)
values
  ('cb000000-0000-0000-0000-00000000a001', auth.uid(), 'expense', 'Groceries', 'cart.fill', '#FF0000'),
  ('cb000000-0000-0000-0000-00000000a002', auth.uid(), 'expense', 'Commute', 'car.fill', '#00FF00'),
  ('cb000000-0000-0000-0000-00000000a003', auth.uid(), 'expense', 'A Private Cat', 'tag.fill', '#0000FF');

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (
  'db000000-0000-0000-0000-00000000a001'::uuid, auth.uid(), auth.uid(),
  'ab000000-0000-0000-0000-00000000a001', 'cb000000-0000-0000-0000-00000000a001',
  -250000, 'EUR', now()
);

-- 1. Only your own things can be offered. A selection is a promise about what
-- the other member will get, so an id you do not own is refused rather than
-- silently dropped from a review screen that already showed it.
select throws_like(
  $$ select create_invite(array['ab000000-0000-0000-0000-0000000000ff']::uuid[], '{}'::uuid[]) $$,
  '%account you do not own%',
  'an account you do not own cannot be offered in an invite'
);

-- 2. The two "Other" rows are each member's own fallback; a mirror of one
-- would collide with the other member's default.
select throws_like(
  $$ select share_category((select id from categories where owner_id = auth.uid() and is_default and kind = 'expense')) $$,
  '%default category cannot be shared%',
  'the default category cannot be shared'
);

select share_account('ab000000-0000-0000-0000-00000000a001');

create temp table share_token (token text);
insert into share_token
select create_invite(
  array['ab000000-0000-0000-0000-00000000a001']::uuid[],
  array['cb000000-0000-0000-0000-00000000a001', 'cb000000-0000-0000-0000-00000000a002']::uuid[]
);

-- ----------------------------------------------------------------------------
-- B, before accepting
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into categories (id, owner_id, kind, name)
values ('cb000000-0000-0000-0000-00000000b001', auth.uid(), 'expense', '  groceries  ');

-- 3. The invitee can see what they are about to accept, by name, holding
-- nothing but the token.
select is(
  (select count(*) from preview_invite((select token from share_token)) where category_name is not null),
  2::bigint,
  'preview_invite names the categories the inviter chose, before accepting'
);

select accept_invite(
  (select token from share_token),
  '{}'::uuid[],
  array['cb000000-0000-0000-0000-00000000b001']::uuid[]
);

-- 4. **The invariant.** A's "Groceries" and B's "  groceries  " are one
-- category now — one group, one row each — not two that look alike.
select is(
  (
    select count(distinct shared_group_id) from categories
    where id in ('cb000000-0000-0000-0000-00000000a001', 'cb000000-0000-0000-0000-00000000b001')
      and shared_group_id is not null
  ),
  1::bigint,
  'categories matching by trimmed, case-insensitive name merge into one group'
);

-- 5. "Commute" had no match, so B was given a row of their own — without it
-- B could see the category and never file anything under it.
select is(
  (
    select count(*) from categories
    where owner_id = '22222222-2222-2222-2222-222222222222'
      and lower(name) = 'commute' and deleted_at is null
  ),
  1::bigint,
  'an unmatched shared category is mirrored into the other member''s own list'
);

-- 6. And the mirror carries the appearance, so the same category does not
-- look like two different things on the two phones.
select is(
  (
    select icon || ' ' || color from categories
    where owner_id = '22222222-2222-2222-2222-222222222222' and lower(name) = 'commute' and deleted_at is null
  ),
  'car.fill #00FF00',
  'a mirrored category keeps the icon and colour it was shared with'
);

-- 7. Every group holds exactly one row per member. This is the property that
-- makes the composite foreign key a non-issue.
select is(
  (
    select count(*) from (
      select shared_group_id from categories
      where shared_group_id is not null and deleted_at is null
      group by shared_group_id having count(*) <> 2
    ) bad
  ),
  0::bigint,
  'every shared group holds exactly one row per member'
);

-- 8. What A did not offer stays private.
select is(
  (select count(*) from categories where id = 'cb000000-0000-0000-0000-00000000a003'),
  0::bigint,
  'a category the inviter did not share stays invisible to the other member'
);

-- 9. The pre-existing hole, closed. Before this migration a member looking at
-- a shared account saw the amount, the account name, and `category_name` as
-- NULL — `transactions_with_details` is security_invoker and left-joins
-- categories, which owner-only visibility emptied out.
select is(
  (
    select category_name from transactions_with_details
    where transaction_id = 'db000000-0000-0000-0000-00000000a001'
  ),
  'Groceries',
  'a shared account''s transactions are legible: the partner sees the category name'
);

-- 10. B's own selection reached A in the other direction.
select is(
  (
    select count(*) from categories
    where owner_id = '11111111-1111-1111-1111-111111111111'
      and shared_group_id = (
        select shared_group_id from categories where id = 'cb000000-0000-0000-0000-00000000b001'
      )
  ),
  1::bigint,
  'the invitee''s own selection is shared back to the inviter'
);

-- 11. A's account came across with the invite.
select is(
  (
    select count(*) from household_accounts
    where account_id = 'ab000000-0000-0000-0000-00000000a001' and deleted_at is null
  ),
  1::bigint,
  'the inviter''s chosen account is shared when the invite is accepted'
);

-- ----------------------------------------------------------------------------
-- Editing, and changing your mind
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

update categories set name = 'Food & Drink', color = '#123456'
where id = 'cb000000-0000-0000-0000-00000000a001';

-- 12. One category, so renaming it renames it — on both phones.
select is(
  (select name || ' ' || color from categories where id = 'cb000000-0000-0000-0000-00000000b001'),
  'Food & Drink #123456',
  'renaming or recolouring a shared category writes through to the other member'
);

-- 13. A category B shares that A never chose is still B's to unshare.
select unshare_category('cb000000-0000-0000-0000-00000000a001');
select is(
  (
    select count(*) from categories
    where id in ('cb000000-0000-0000-0000-00000000a001', 'cb000000-0000-0000-0000-00000000b001')
      and shared_group_id is not null
  ),
  0::bigint,
  'unsharing unlinks every row in the group, not just the caller''s'
);

-- 14. ... and the other member keeps their row. Unsharing takes back the
-- link, never the data.
--
-- Asserted as postgres rather than as A: once the link is gone A cannot see
-- B's row at all, which is the point — reading it from A's session would
-- report the row missing when it is merely, correctly, private again.
reset role;
select set_config('request.jwt.claim.sub', '', true);
select is(
  (select count(*) from categories where id = 'cb000000-0000-0000-0000-00000000b001' and deleted_at is null),
  1::bigint,
  'unsharing leaves the other member''s row and everything filed under it'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- ----------------------------------------------------------------------------
-- Departing
-- ----------------------------------------------------------------------------

-- 15. Leaving unlinks whatever is left: a shared category with one member in
-- it is a private category wearing a badge.
select leave_household();

reset role;
select set_config('request.jwt.claim.sub', '', true);
select is(
  (select count(*) from categories where shared_group_id is not null
   and owner_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')),
  0::bigint,
  'leaving the household unlinks every category the departing member shared'
);

-- 16. And the guard from 20260911100000 still passes with the new column —
-- `shared_group_id` is a category link, not an identity, so nothing about
-- deletion changed.
select is(
  (select unregistered_identity_columns()),
  null,
  'the new column introduces no unregistered identity column'
);

select * from finish();
rollback;
