-- The owner chooses how much history to share
-- (20261013100000_the_owner_chooses_how_much_history_to_share.sql).
--
--   1. An invite carries each account's choice, on both sides, and a dated
--      share starts on the acceptance day in the owner's own time zone.
--   2. A transfer between the two members is dated where both see it.
--   3. A partner's recurring rule starts where they can see it.
--   4. share_account: full history by default, never narrows while live,
--      starts afresh after it ended.
--   5. Widening re-sends what was held back.
--
-- Fixture A = 11111111-... (inviter, New York), fixture B = 22222222-...
-- (invitee, Tokyo).

\ir _helpers.psql

begin;
select plan(26);

-- ============================================================================
-- Setup, as postgres
-- ============================================================================

update profiles set time_zone = 'America/New_York' where id = '11111111-1111-1111-1111-111111111111';
update profiles set time_zone = 'Asia/Tokyo' where id = '22222222-2222-2222-2222-222222222222';

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a5500000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Full', 'EUR', 0),
  ('a5500000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Dated', 'EUR', 1000000),
  ('a5500000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Later', 'EUR', 0),
  ('a5500000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Private', 'EUR', 0),
  ('a5500000-0000-0000-0000-000000000011', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'regular', 'B Full', 'EUR', 0),
  ('a5500000-0000-0000-0000-000000000012', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'regular', 'B Dated', 'EUR', 0);

insert into categories (id, owner_id, kind, name)
values ('c5500000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Groceries');

-- A row on A's dated account from before the day it is shared.
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values ('d5500000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '11111111-1111-1111-1111-111111111111', 'a5500000-0000-0000-0000-000000000002',
        'c5500000-0000-0000-0000-000000000001', -40000, 'EUR', now() - interval '10 days');

create temp table saved (label text primary key, value text);
create temp table pulls (label text primary key, payload jsonb, next_cursor bigint);
grant all on saved, pulls to authenticated;

-- ============================================================================
-- 1. Invites
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select create_household();

insert into saved select 'token', create_invite(
  array['a5500000-0000-0000-0000-000000000001', 'a5500000-0000-0000-0000-000000000002']::uuid[],
  '{}'::uuid[],
  array['a5500000-0000-0000-0000-000000000001']::uuid[]
);

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select array_agg(account_name || ':' || full_history order by account_name)
   from preview_invite((select value from saved where label = 'token'))),
  array['A Dated:false', 'A Full:true'],
  'the invitee sees which accounts come with their full history'
);

select accept_invite(
  (select value from saved where label = 'token'),
  array['a5500000-0000-0000-0000-000000000011', 'a5500000-0000-0000-0000-000000000012']::uuid[],
  '{}'::uuid[],
  array['a5500000-0000-0000-0000-000000000011']::uuid[]
);

reset role;

select is(
  (select history_from from household_accounts where account_id = 'a5500000-0000-0000-0000-000000000001'),
  null::timestamptz,
  'the inviter''s account shared with full history has no start date'
);

select is(
  (select history_from from household_accounts where account_id = 'a5500000-0000-0000-0000-000000000002'),
  ((now() at time zone 'America/New_York')::date)::timestamp at time zone 'America/New_York',
  'the inviter''s other account starts at the beginning of the acceptance day, in the inviter''s time zone'
);

select is(
  (select history_from from household_accounts where account_id = 'a5500000-0000-0000-0000-000000000011'),
  null::timestamptz,
  'the invitee''s own choices apply to their accounts: full history'
);

select is(
  (select history_from from household_accounts where account_id = 'a5500000-0000-0000-0000-000000000012'),
  ((now() at time zone 'Asia/Tokyo')::date)::timestamp at time zone 'Asia/Tokyo',
  'and a start date in the invitee''s own time zone'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
insert into saved select 'old_style', create_invite(array['a5500000-0000-0000-0000-000000000003']::uuid[], '{}'::uuid[]);
reset role;

select is(
  (select full_history_account_ids from household_invites where shared_account_ids = array['a5500000-0000-0000-0000-000000000003']::uuid[]),
  array['a5500000-0000-0000-0000-000000000003']::uuid[],
  'an invite from a build without the choice shares everything with full history, as today'
);

-- ============================================================================
-- 2. A transfer between the two members
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select throws_ok(
  $$ select create_transfer('a5500000-0000-0000-0000-000000000002', 'a5500000-0000-0000-0000-000000000011',
       5000, null, now() - interval '10 days', 'd5500000-0000-0000-0000-000000000021', 'd5500000-0000-0000-0000-000000000022') $$,
  'P0001',
  'This transfer is between your account and your partner''s, so it can''t be dated before both accounts were shared. Pick a later date.',
  'a transfer into the partner''s account cannot be dated before the start of the owner''s own account'
);

select lives_ok(
  $$ select create_transfer('a5500000-0000-0000-0000-000000000002', 'a5500000-0000-0000-0000-000000000011',
       5000, null, now(), 'd5500000-0000-0000-0000-000000000021', 'd5500000-0000-0000-0000-000000000022') $$,
  'but can from the start date on'
);

select throws_ok(
  $$ select update_transfer('d5500000-0000-0000-0000-000000000021', 1, 1, 5000, 5000, now() - interval '10 days') $$,
  'P0001',
  'This transfer is between your account and your partner''s, so it can''t be dated before both accounts were shared. Pick a later date.',
  'nor re-dated to before it'
);

select lives_ok(
  $$ select create_transfer('a5500000-0000-0000-0000-000000000002', 'a5500000-0000-0000-0000-000000000004',
       5000, null, now() - interval '10 days') $$,
  'a transfer between the owner''s own accounts is still hers to backdate'
);

select throws_ok(
  $$ select create_transfer('a5500000-0000-0000-0000-000000000001', 'a5500000-0000-0000-0000-000000000012',
       5000, null, now() - interval '10 days') $$,
  'P0001',
  'That date is before this account was shared with you. Pick a later date.',
  'and into the partner''s dated account, Phase 1''s refusal still speaks first'
);

-- ============================================================================
-- 3. A partner's recurring rule
-- ============================================================================

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select throws_ok(
  $$ insert into recurring_rules (id, created_by, account_id, category_id, amount_e4, currency, frequency, next_due_at)
     values ('b5500000-0000-0000-0000-000000000001', auth.uid(), 'a5500000-0000-0000-0000-000000000002',
             'c5500000-0000-0000-0000-000000000001', -1000, 'EUR', 'monthly',
             (now() at time zone 'America/New_York')::date - 5) $$,
  'P0001',
  'That date is before this account was shared with you. Pick a later date.',
  'a partner cannot start a rule on the owner''s account before the start date'
);

select lives_ok(
  $$ insert into recurring_rules (id, created_by, account_id, category_id, amount_e4, currency, frequency, next_due_at)
     values ('b5500000-0000-0000-0000-000000000001', auth.uid(), 'a5500000-0000-0000-0000-000000000002',
             'c5500000-0000-0000-0000-000000000001', -1000, 'EUR', 'monthly',
             (now() at time zone 'America/New_York')::date) $$,
  'but can on the start day, in the owner''s time zone'
);

select lives_ok(
  $$ update recurring_rules set amount_e4 = -2000 where id = 'b5500000-0000-0000-0000-000000000001' $$,
  'and can change what it charges'
);

select throws_ok(
  $$ update recurring_rules set next_due_at = next_due_at - 5 where id = 'b5500000-0000-0000-0000-000000000001' $$,
  'P0001',
  'That date is before this account was shared with you. Pick a later date.',
  'but not move its start earlier'
);

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select lives_ok(
  $$ update recurring_rules set next_due_at = next_due_at - 5 where id = 'b5500000-0000-0000-0000-000000000001' $$,
  'the owner may'
);

-- ============================================================================
-- 4. share_account
-- ============================================================================

select share_account('a5500000-0000-0000-0000-000000000003');

select is(
  (select history_from from household_accounts where account_id = 'a5500000-0000-0000-0000-000000000003'),
  null::timestamptz,
  'share_account shares full history when not told otherwise, as today'
);

select share_account('a5500000-0000-0000-0000-000000000003', false);

select is(
  (select history_from from household_accounts where account_id = 'a5500000-0000-0000-0000-000000000003'),
  null::timestamptz,
  'sharing it again with a start date does not narrow a live share'
);

select unshare_account('a5500000-0000-0000-0000-000000000003');
select share_account('a5500000-0000-0000-0000-000000000003', false);

select is(
  (select history_from from household_accounts where account_id = 'a5500000-0000-0000-0000-000000000003'),
  ((now() at time zone 'America/New_York')::date)::timestamp at time zone 'America/New_York',
  'a share that had ended starts afresh with the date asked for'
);

select unshare_account('a5500000-0000-0000-0000-000000000003');
select share_account('a5500000-0000-0000-0000-000000000003');

select is(
  (select history_from from household_accounts where account_id = 'a5500000-0000-0000-0000-000000000003'),
  null::timestamptz,
  'and one shared again with full history keeps no old start date'
);

-- ============================================================================
-- 5. Widening
-- ============================================================================

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
insert into pulls select 'b1', payload, next_cursor from pull_changes(0, 0);

select is(
  (select (e->>'opening_balance_e4')::bigint from pulls, jsonb_array_elements(payload->'accounts') e
   where label = 'b1' and e->>'id' = 'a5500000-0000-0000-0000-000000000002'),
  955000::bigint,
  'before widening, the partner''s copy opens on the carried balance'
);

select throws_ok(
  $$ select share_full_history('a5500000-0000-0000-0000-000000000002') $$,
  'P0001',
  'account not found or not owned by you',
  'only the owner can widen a share'
);

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select throws_ok(
  $$ select share_full_history('a5500000-0000-0000-0000-000000000004') $$,
  'P0001',
  'This account isn''t shared with your household.',
  'and only a share that exists'
);

select share_full_history('a5500000-0000-0000-0000-000000000002');

select is(
  (select history_from from household_accounts where account_id = 'a5500000-0000-0000-0000-000000000002'),
  null::timestamptz,
  'widening removes the start date'
);

select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
insert into pulls select 'b2', payload, next_cursor
from pull_changes((select next_cursor from pulls where label = 'b1'), 0);

select is(
  (select count(*) from pulls, jsonb_array_elements(payload->'transactions') e
   where label = 'b2' and e->>'id' = 'd5500000-0000-0000-0000-000000000001'),
  1::bigint,
  'and the partner''s next pull brings the earlier rows'
);

select is(
  (select (e->>'opening_balance_e4')::bigint from pulls, jsonb_array_elements(payload->'accounts') e
   where label = 'b2' and e->>'id' = 'a5500000-0000-0000-0000-000000000002'),
  1000000::bigint,
  'with the account''s true opening balance'
);

select finish();
rollback;
