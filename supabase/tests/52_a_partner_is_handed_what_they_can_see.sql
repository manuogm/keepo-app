-- A partner is handed what they can see
-- (20261010100000_a_partner_is_handed_what_they_can_see.sql).
--
-- Pull completeness, asserted on what `pull_changes` actually returns, never
-- on `sync_seq` arithmetic:
--
--   1. A partner's copy of an account shared from a start date opens on the
--      balance carried into it, so the device's one formula lands on the true
--      balance; the owner's copy is untouched.
--   2. A change before the start date re-sends the account with the new
--      figure; a change after it does not.
--   3. Sharing an account re-sends what its transactions wear (#9), and so
--      do a tag and a category starting to label a household transaction.
--   4. Re-stamping never bumps a version, and restores the flag it found.
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (partner).

\ir _helpers.psql

begin;
select plan(17);

-- ============================================================================
-- Setup, as postgres
-- ============================================================================

insert into households (id) values ('52000000-0000-0000-0000-000000000001');
insert into household_members (household_id, user_id)
values
  ('52000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('52000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a5200000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Shared From A Date', 'EUR', 1000000),
  ('a5200000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Shared Later', 'EUR', 0);

insert into household_accounts (household_id, account_id, history_from)
values ('52000000-0000-0000-0000-000000000001', 'a5200000-0000-0000-0000-000000000001', now() - interval '30 days');

insert into categories (id, owner_id, kind, name)
values
  ('c5200000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Everyday'),
  ('c5200000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'expense', 'Worn Later'),
  ('c5200000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'expense', 'On The Later Share');

insert into tags (id, owner_id, name)
values
  ('e5200000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'On The Later Share'),
  ('e5200000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'B Old Tag');

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values
  ('d5200000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5200000-0000-0000-0000-000000000001',
   'c5200000-0000-0000-0000-000000000001', -100000, 'EUR', now() - interval '60 days'),
  ('d5200000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5200000-0000-0000-0000-000000000001',
   'c5200000-0000-0000-0000-000000000001', -200000, 'EUR', now() - interval '10 days'),
  ('d5200000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5200000-0000-0000-0000-000000000002',
   'c5200000-0000-0000-0000-000000000003', -30000, 'EUR', now() - interval '5 days');

insert into transaction_tags (transaction_id, tag_id)
values ('d5200000-0000-0000-0000-000000000003', 'e5200000-0000-0000-0000-000000000001');

create temp table pulls (label text primary key, payload jsonb, next_cursor bigint);
grant all on pulls to authenticated;

-- ============================================================================
-- 1. The carried opening
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
insert into pulls select 'b1', payload, next_cursor from pull_changes(0, 0);

select is(
  (select (e->>'opening_balance_e4')::bigint
   from pulls, jsonb_array_elements(payload->'accounts') e
   where label = 'b1' and e->>'id' = 'a5200000-0000-0000-0000-000000000001'),
  900000::bigint,
  'the partner''s copy opens on the balance carried into the start date'
);

select is(
  (select (e->>'opening_balance_at')::date
   from pulls, jsonb_array_elements(payload->'accounts') e
   where label = 'b1' and e->>'id' = 'a5200000-0000-0000-0000-000000000001'),
  ((now() - interval '30 days') at time zone 'UTC')::date,
  'dated on the owner''s calendar day the share began'
);

select is(
  (select (e->>'opening_balance_e4')::bigint
   from pulls, jsonb_array_elements(payload->'accounts') e
   where label = 'b1' and e->>'id' = 'a5200000-0000-0000-0000-000000000001')
  + (select sum((e->>'amount_e4')::bigint)::bigint
     from pulls, jsonb_array_elements(payload->'transactions') e
     where label = 'b1' and e->>'account_id' = 'a5200000-0000-0000-0000-000000000001'
       and e->>'status' = 'confirmed' and e->>'deleted_at' is null),
  account_balance_on('a5200000-0000-0000-0000-000000000001', current_date),
  'so the device''s one formula over what it was sent is the true balance'
);

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
insert into pulls select 'a1', payload, next_cursor from pull_changes(0, 0);

select is(
  (select (e->>'opening_balance_e4')::bigint
   from pulls, jsonb_array_elements(payload->'accounts') e
   where label = 'a1' and e->>'id' = 'a5200000-0000-0000-0000-000000000001'),
  1000000::bigint,
  'the owner''s copy keeps the stored opening'
);

-- ============================================================================
-- 2. What re-sends the account
-- ============================================================================

select update_transaction('d5200000-0000-0000-0000-000000000001', 1,
  'a5200000-0000-0000-0000-000000000001', 'c5200000-0000-0000-0000-000000000001',
  -150000, 'EUR', now() - interval '60 days');

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
insert into pulls select 'b2', payload, next_cursor
from pull_changes((select next_cursor from pulls where label = 'b1'), 0);

select is(
  (select (e->>'opening_balance_e4')::bigint
   from pulls, jsonb_array_elements(payload->'accounts') e
   where label = 'b2' and e->>'id' = 'a5200000-0000-0000-0000-000000000001'),
  850000::bigint,
  'an owner''s edit before the start date re-sends the account with the new carried opening'
);

select is(
  (select count(*) from pulls, jsonb_array_elements(payload->'transactions') e
   where label = 'b2' and e->>'id' = 'd5200000-0000-0000-0000-000000000001'),
  0::bigint,
  'without sending the edited row itself'
);

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select update_transaction('d5200000-0000-0000-0000-000000000002', 1,
  'a5200000-0000-0000-0000-000000000001', 'c5200000-0000-0000-0000-000000000001',
  -250000, 'EUR', now() - interval '10 days');

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
insert into pulls select 'b3', payload, next_cursor
from pull_changes((select next_cursor from pulls where label = 'b2'), 0);

select is(
  (select array_agg(e->>'id') from pulls, jsonb_array_elements(payload->'transactions') e where label = 'b3'),
  array['d5200000-0000-0000-0000-000000000002'],
  'an edit after the start date reaches the partner as the row itself'
);

select is(
  (select count(*) from pulls, jsonb_array_elements(payload->'accounts') e where label = 'b3'),
  0::bigint,
  'and does not re-send the account'
);

select is(
  (select version from accounts where id = 'a5200000-0000-0000-0000-000000000001'),
  1,
  'a re-stamped account keeps its version'
);

select is(
  current_setting('keepo.restamp_only', true),
  'false',
  'and the re-stamp flag is off again afterwards'
);

-- ============================================================================
-- 3. What a share, a tag and a category reveal (#9)
-- ============================================================================

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select share_account('a5200000-0000-0000-0000-000000000002');

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
insert into pulls select 'b4', payload, next_cursor
from pull_changes((select next_cursor from pulls where label = 'b3'), 0);

select is(
  (select array_agg(e->>'name') from pulls, jsonb_array_elements(payload->'tags') e where label = 'b4'),
  array['On The Later Share'],
  'sharing an account later sends the tags its transactions wear'
);

select is(
  (select count(*) from pulls, jsonb_array_elements(payload->'transaction_tags') e
   where label = 'b4' and e->>'transaction_id' = 'd5200000-0000-0000-0000-000000000003'),
  1::bigint,
  'and the links that put them there'
);

select is(
  (select array_agg(e->>'name') from pulls, jsonb_array_elements(payload->'categories') e where label = 'b4'),
  array['On The Later Share'],
  'and the categories'
);

-- B puts an old tag of their own on the owner's shared transaction.
insert into transaction_tags (transaction_id, tag_id)
values ('d5200000-0000-0000-0000-000000000002', 'e5200000-0000-0000-0000-000000000002');

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
insert into pulls select 'a2', payload, next_cursor
from pull_changes((select next_cursor from pulls where label = 'a1'), 0);

select is(
  (select count(*) from pulls, jsonb_array_elements(payload->'tags') e
   where label = 'a2' and e->>'id' = 'e5200000-0000-0000-0000-000000000002'),
  1::bigint,
  'a partner''s old tag reaches the owner once it labels a household transaction'
);

-- A puts an old category on a shared transaction for the first time.
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values ('d5200000-0000-0000-0000-000000000004', auth.uid(), auth.uid(),
        'a5200000-0000-0000-0000-000000000001', 'c5200000-0000-0000-0000-000000000002',
        -1000, 'EUR', now() - interval '1 day');

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
insert into pulls select 'b5', payload, next_cursor
from pull_changes((select next_cursor from pulls where label = 'b4'), 0);

select is(
  (select count(*) from pulls, jsonb_array_elements(payload->'categories') e
   where label = 'b5' and e->>'id' = 'c5200000-0000-0000-0000-000000000002'),
  1::bigint,
  'an old category reaches the partner once it labels a household transaction'
);

-- ============================================================================
-- 4. A re-stamp inside a re-stamp
-- ============================================================================

reset role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('keepo.restamp_only', 'true', true);
select restamp_account_for_sync('a5200000-0000-0000-0000-000000000001');

select is(
  current_setting('keepo.restamp_only', true),
  'true',
  'restamp_account_for_sync puts back the flag it found rather than switching it off'
);
select set_config('keepo.restamp_only', 'false', true);

select is(
  (select version from categories where id = 'c5200000-0000-0000-0000-000000000003'),
  1,
  'a category re-sent by a share keeps its version'
);

select finish();
rollback;
