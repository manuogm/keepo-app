-- Tags (migrations 20260907100000_tags.sql + 20260908100000_tags_without_
-- categories.sql): naming, the tag/transaction join, the soft-delete
-- cascade, and the derived household visibility that is the whole point of
-- the design.
--
-- A tag is **name-only** — the category link was removed the day after it
-- landed, so nothing here tests one, and a tag applies to any transaction of
-- any kind including a transfer.
--
-- Fixture A = 11111111-... (base EUR), fixture B = 22222222-... (base USD).
-- As in 07_households.sql, "B joins A's household" is simulated by inserting
-- the second household_members row as postgres — accept_invite needs a real
-- token and this file is testing tags, not invites.

\ir _helpers.psql

begin;
select plan(16);

-- ----------------------------------------------------------------------------
-- Setup: A has a household, one account to share and one to keep private,
-- one category, and a transaction in each account.
-- ----------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a7000000-0000-0000-0000-00000000a001', auth.uid(), auth.uid(), 'regular', 'A Shared', 'EUR', 10000000),
  ('a7000000-0000-0000-0000-00000000a002', auth.uid(), auth.uid(), 'regular', 'A Private', 'EUR', 5000000);

insert into categories (id, owner_id, kind, name)
values ('c7000000-0000-0000-0000-00000000a001', auth.uid(), 'expense', 'Food');

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values
  (
    '47000000-0000-0000-0000-00000000a001'::uuid, auth.uid(), auth.uid(),
    'a7000000-0000-0000-0000-00000000a001', 'c7000000-0000-0000-0000-00000000a001',
    -250000, 'EUR', now()
  ),
  (
    '47000000-0000-0000-0000-00000000a002'::uuid, auth.uid(), auth.uid(),
    'a7000000-0000-0000-0000-00000000a002', 'c7000000-0000-0000-0000-00000000a001',
    -180000, 'EUR', now()
  );

-- ----------------------------------------------------------------------------
-- A tag is name and nothing else
-- ----------------------------------------------------------------------------

-- 1. The category link is gone from the table, not merely unused.
select hasnt_column('public', 'tags', 'category_id', 'tags carries no category_id');

insert into tags (id, owner_id, name)
values ('e7000000-0000-0000-0000-00000000a001', auth.uid(), 'Coffee');

-- 2. A second tag with the same name, in any case, is refused for one owner.
select throws_ok(
  $$ insert into tags (owner_id, name) values (auth.uid(), 'coffee') $$,
  '23505',
  null,
  'a tag name is unique per owner, case-insensitively'
);

-- 3. ... and surrounding whitespace does not buy a second one either.
select throws_ok(
  $$ insert into tags (owner_id, name) values (auth.uid(), '  Coffee  ') $$,
  '23505',
  null,
  'a tag name is unique per owner after trimming'
);

-- 4. An empty (or whitespace-only) name is refused by the CHECK.
select throws_ok(
  $$ insert into tags (owner_id, name) values (auth.uid(), '   ') $$,
  '23514',
  null,
  'a whitespace-only tag name is refused'
);

-- 5. Fixture B may reuse a name fixture A has taken — uniqueness is per owner.
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
insert into tags (id, owner_id, name)
values ('e7000000-0000-0000-0000-00000000b001', auth.uid(), 'Coffee');
select is(
  (select count(*) from tags where lower(name) = 'coffee' and owner_id = auth.uid()),
  1::bigint,
  'two users can each have a tag of the same name'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- ----------------------------------------------------------------------------
-- Applying tags
-- ----------------------------------------------------------------------------

insert into tags (id, owner_id, name)
values ('e7000000-0000-0000-0000-00000000a002', auth.uid(), 'Holiday');

-- 6. Any tag goes on any transaction — there is no category rule left to
-- refuse one. The second row deliberately carries the WRONG owner_id, which
-- assertion 7 then checks was overwritten.
insert into transaction_tags (transaction_id, tag_id, owner_id)
values
  ('47000000-0000-0000-0000-00000000a001', 'e7000000-0000-0000-0000-00000000a001', auth.uid()),
  (
    '47000000-0000-0000-0000-00000000a001', 'e7000000-0000-0000-0000-00000000a002',
    '22222222-2222-2222-2222-222222222222'
  );
select is(
  (
    select count(*) from transaction_tags
    where transaction_id = '47000000-0000-0000-0000-00000000a001' and deleted_at is null
  ),
  2::bigint,
  'a transaction carries any number of tags'
);

-- 7. owner_id is derived from the transaction, never taken from the client —
-- a wrong one would file the row in the wrong sync domain, where the account
-- owner would never pull it.
select is(
  (
    select owner_id from transaction_tags
    where transaction_id = '47000000-0000-0000-0000-00000000a001'
      and tag_id = 'e7000000-0000-0000-0000-00000000a002'
  ),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'transaction_tags.owner_id is taken from the transaction, not from the client'
);

-- 8. Every link is stamped with a sync ticket.
select ok(
  (
    select bool_and(sync_seq > 0) from transaction_tags
    where transaction_id = '47000000-0000-0000-0000-00000000a001'
  ),
  'transaction_tags rows are stamped with a sync_seq'
);

-- 9. A tag that does not exist is refused, rather than leaving a dangling
-- link the client would render as a blank chip.
select throws_like(
  $$
    insert into transaction_tags (transaction_id, tag_id, owner_id)
    values (
      '47000000-0000-0000-0000-00000000a002', 'e7000000-0000-0000-0000-0000000000ff',
      '11111111-1111-1111-1111-111111111111'
    )
  $$,
  '%not found%',
  'applying a tag that does not exist is refused'
);

-- ----------------------------------------------------------------------------
-- Transfers — no category, and now no rule that could exclude them
-- ----------------------------------------------------------------------------

select create_transfer(
  p_from_account_id => 'a7000000-0000-0000-0000-00000000a001',
  p_to_account_id => 'a7000000-0000-0000-0000-00000000a002',
  p_from_amount_e4 => 250000,
  p_to_amount_e4 => 250000,
  p_occurred_at => now()
);

-- 10. A tag applies to a transfer leg exactly like any other transaction.
insert into transaction_tags (transaction_id, tag_id, owner_id)
select id, 'e7000000-0000-0000-0000-00000000a001', owner_id
from transactions where transfer_group_id is not null and amount_e4 < 0 limit 1;
select is(
  (
    select count(*) from transaction_tags tt
    join transactions t on t.id = tt.transaction_id
    where t.transfer_group_id is not null and tt.deleted_at is null
  ),
  1::bigint,
  'a tag applies to a transfer leg'
);

-- 11. Recategorising a transaction leaves its tags alone — the cascade that
-- used to drop them went with the category link.
select * from update_transaction(
  p_id => '47000000-0000-0000-0000-00000000a001',
  p_expected_version => (select version from transactions where id = '47000000-0000-0000-0000-00000000a001'),
  p_account_id => 'a7000000-0000-0000-0000-00000000a001',
  p_category_id => (select id from categories where owner_id = auth.uid() and is_default and kind = 'expense'),
  p_amount_e4 => -250000,
  p_currency => 'EUR',
  p_occurred_at => now()
);
select is(
  (
    select count(*) from transaction_tags
    where transaction_id = '47000000-0000-0000-0000-00000000a001' and deleted_at is null
  ),
  2::bigint,
  'recategorising a transaction keeps every tag on it'
);

-- ----------------------------------------------------------------------------
-- Deleting a tag
-- ----------------------------------------------------------------------------

-- 12. Soft-deleting a tag takes its links with it — a tombstone on the tag
-- alone would leave the other device rendering a chip for a gone tag.
update tags set deleted_at = now() where id = 'e7000000-0000-0000-0000-00000000a002';
select is(
  (
    select count(*) from transaction_tags
    where tag_id = 'e7000000-0000-0000-0000-00000000a002' and deleted_at is null
  ),
  0::bigint,
  'soft-deleting a tag cascades to every one of its transaction links'
);

-- 13. ... and the name is free again once it is gone.
insert into tags (owner_id, name) values (auth.uid(), 'Holiday');
select is(
  (select count(*) from tags where owner_id = auth.uid() and lower(name) = 'holiday' and deleted_at is null),
  1::bigint,
  'a deleted tag''s name can be reused'
);

-- ----------------------------------------------------------------------------
-- Household visibility — derived, never stored
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);

insert into household_members (household_id, user_id)
select household_id, '22222222-2222-2222-2222-222222222222'
from household_members where user_id = '11111111-1111-1111-1111-111111111111';

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- 14. A's Coffee tag lives on the shared account's transaction, but nothing
-- is shared yet, so B cannot see it.
select is(
  (select count(*) from tags where id = 'e7000000-0000-0000-0000-00000000a001'),
  0::bigint,
  'a tag on an unshared account''s transaction is invisible to the other member'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select share_account('a7000000-0000-0000-0000-00000000a001');

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- 15. Sharing the account makes the tag on it visible, with nothing written
-- to the tag itself.
select is(
  (select count(*) from tags where id = 'e7000000-0000-0000-0000-00000000a001'),
  1::bigint,
  'a tag becomes visible to the other member once its transaction''s account is shared'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select unshare_account('a7000000-0000-0000-0000-00000000a001');

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- 16. Revoking the share revokes the tag with it, again with nothing written
-- to the tag — this is the whole reason visibility is derived rather than a
-- stored is_shared flag that would have to be recomputed here.
select is(
  (select count(*) from tags where id = 'e7000000-0000-0000-0000-00000000a001'),
  0::bigint,
  'unsharing the account revokes the tag''s visibility with it'
);

select * from finish();
rollback;
