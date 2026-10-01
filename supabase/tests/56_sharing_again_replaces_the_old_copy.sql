-- Sharing an account again replaces the old copy
-- (20261014100000_sharing_again_replaces_the_old_copy.sql).
--
--   1. A copy made when a share ends remembers the account it came from.
--   2. Sharing that account again retires the copy, with what was added to
--      it since, and keeps every transfer pair whole.
--   3. Only a copy of that account, held by a member of that household.
--   4. The invite path does the same.
--
-- Fixture A = 11111111-... (owner), fixture B = 22222222-... (partner).

\ir _helpers.psql

begin;
select plan(13);

-- ============================================================================
-- Setup, as postgres
-- ============================================================================

insert into households (id) values ('56000000-0000-0000-0000-000000000001');
insert into household_members (household_id, user_id)
values
  ('56000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('56000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a5600000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Joint', 'EUR', 100000),
  ('a5600000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Other', 'EUR', 0),
  ('a5600000-0000-0000-0000-000000000011', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'regular', 'B Own', 'EUR', 0);

insert into household_accounts (household_id, account_id)
values
  ('56000000-0000-0000-0000-000000000001', 'a5600000-0000-0000-0000-000000000001'),
  ('56000000-0000-0000-0000-000000000001', 'a5600000-0000-0000-0000-000000000002');

insert into categories (id, owner_id, kind, name)
values ('c5600000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Groceries');

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values ('d5600000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '11111111-1111-1111-1111-111111111111', 'a5600000-0000-0000-0000-000000000001',
        'c5600000-0000-0000-0000-000000000001', -1000, 'EUR', now() - interval '3 days');

-- ============================================================================
-- 1. The copy remembers
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select unshare_account('a5600000-0000-0000-0000-000000000001');
reset role;

select is(
  (select copied_from from accounts where owner_id = '22222222-2222-2222-2222-222222222222' and name = 'A Joint'),
  'a5600000-0000-0000-0000-000000000001'::uuid,
  'the member''s copy remembers the account it came from'
);

select is(
  (select copied_from from accounts where id = 'a5600000-0000-0000-0000-000000000001'),
  null::uuid,
  'an account someone created has no such link'
);

-- After the unshare, B uses the copy as their own: a purchase, and a
-- transfer into it from their own account.
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
select 'd5600000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
       '22222222-2222-2222-2222-222222222222', c.id,
       (select id from categories where owner_id = '22222222-2222-2222-2222-222222222222' and kind = 'expense' and is_default),
       -500, 'EUR', now() - interval '1 day'
from accounts c where c.owner_id = '22222222-2222-2222-2222-222222222222' and c.name = 'A Joint';

insert into transactions (id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, transfer_group_id)
select v.id, '22222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222',
       coalesce(v.account_id, c.id), v.amount_e4, 'EUR', now() - interval '1 day', 'd5600000-0000-0000-0000-000000000003'
from accounts c
cross join (values
  ('d5600000-0000-0000-0000-000000000003'::uuid, 'a5600000-0000-0000-0000-000000000011'::uuid, -2000::bigint),
  ('d5600000-0000-0000-0000-000000000004'::uuid, null::uuid, 2000::bigint)
) as v(id, account_id, amount_e4)
where c.owner_id = '22222222-2222-2222-2222-222222222222' and c.name = 'A Joint';

-- ============================================================================
-- 2. Sharing again
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select share_account('a5600000-0000-0000-0000-000000000001');
reset role;

select is(
  (select count(*) from accounts
   where owner_id = '22222222-2222-2222-2222-222222222222' and name = 'A Joint' and deleted_at is null),
  0::bigint,
  'sharing the account again retires the member''s copy'
);

select is(
  (select deleted_at is not null from transactions where id = 'd5600000-0000-0000-0000-000000000002'),
  true,
  'with what they added to it since'
);

select is(
  (select array_agg(transfer_group_id::text || ':' || (deleted_at is null) order by id) from transactions
   where id in ('d5600000-0000-0000-0000-000000000003', 'd5600000-0000-0000-0000-000000000004')),
  array['d5600000-0000-0000-0000-000000000003:true', 'd5600000-0000-0000-0000-000000000003:true'],
  'while a transfer from their own account keeps both halves, the copy''s as an anchor'
);

set constraints all immediate;
select pass('every transfer pair is whole');
set constraints all deferred;

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select count(*) from accounts where name = 'A Joint' and deleted_at is null),
  1::bigint,
  'the partner sees one "A Joint": the owner''s, shared again'
);

select is(
  (select id from accounts where name = 'A Joint' and deleted_at is null),
  'a5600000-0000-0000-0000-000000000001'::uuid,
  'and it is the original'
);

-- ============================================================================
-- 3. Only a copy of that account, in that household
-- ============================================================================

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select unshare_account('a5600000-0000-0000-0000-000000000002');
select unshare_account('a5600000-0000-0000-0000-000000000001');
select share_account('a5600000-0000-0000-0000-000000000002');
reset role;

select is(
  (select count(*) from accounts
   where owner_id = '22222222-2222-2222-2222-222222222222' and name = 'A Joint' and deleted_at is null),
  1::bigint,
  'sharing a different account leaves the copy of this one alone'
);

-- ============================================================================
-- 4. The invite path
-- ============================================================================

create temp table saved (token text);
grant all on saved to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select leave_household();

select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select create_household();
insert into saved select create_invite(array['a5600000-0000-0000-0000-000000000001']::uuid[], '{}'::uuid[]);

reset role;

select cmp_ok(
  (select count(*) from accounts
   where owner_id = '22222222-2222-2222-2222-222222222222' and copied_from = 'a5600000-0000-0000-0000-000000000001'
     and deleted_at is null),
  '>=',
  1::bigint,
  'before accepting, the partner holds a live copy of the account from an earlier share'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select accept_invite((select token from saved), '{}'::uuid[], '{}'::uuid[]);
reset role;

select is(
  (select count(*) from accounts
   where owner_id = '22222222-2222-2222-2222-222222222222' and copied_from = 'a5600000-0000-0000-0000-000000000001'
     and deleted_at is null),
  0::bigint,
  'accepting an invite that shares the account retires it'
);

select is(
  (select count(*) from accounts
   where owner_id = '22222222-2222-2222-2222-222222222222' and name = 'A Other' and deleted_at is null),
  1::bigint,
  'and leaves the copy of an account the invite does not share'
);

set constraints all immediate;
select pass('every transfer pair is whole after the invite');
set constraints all deferred;

select finish();
rollback;
