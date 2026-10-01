-- A transfer is found where the phone left it, and can be moved
-- (20261006100000_a_transfer_is_found_where_the_phone_left_it.sql).
--
--   1. create_transfer's group id is the sending leg's id — the value the
--      phone's optimistic write already uses — so an edit made before the
--      next pull addresses a group the server has.
--   2. update_transfer moves a leg to another account of the same owner,
--      taking that account's currency, and refuses every other move.
--
-- Every assertion that depends on check_transfer_integrity forces it with
-- `set constraints all immediate` — a deferred trigger never fires in a
-- file that always rolls back (lessons-learned, pgTAP section).
--
-- Fixture A = 11111111-..., fixture B = 22222222-....

\ir _helpers.psql

begin;
select plan(11);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a4900000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'A Euros', 'EUR', 0),
  ('a4900000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'regular', 'A More Euros', 'EUR', 0),
  ('a4900000-0000-0000-0000-000000000003', auth.uid(), auth.uid(), 'regular', 'A Dollars', 'USD', 0),
  ('a4900000-0000-0000-0000-000000000004', auth.uid(), auth.uid(), 'regular', 'A Closed', 'EUR', 0);

-- ============================================================================
-- 1. The group id is the sending leg's id
-- ============================================================================

select create_transfer(
  'a4900000-0000-0000-0000-000000000001', 'a4900000-0000-0000-0000-000000000003', 100000, 110000, now(),
  'b4900000-0000-0000-0000-000000000001', 'b4900000-0000-0000-0000-000000000002'
);
set constraints all immediate;
set constraints all deferred;

select is(
  (select array_agg(distinct transfer_group_id) from transactions
   where id in ('b4900000-0000-0000-0000-000000000001', 'b4900000-0000-0000-0000-000000000002')),
  array['b4900000-0000-0000-0000-000000000001'::uuid],
  'both legs share the sending leg''s id as their group — the phone''s own placeholder'
);

select is(
  (select conflict from update_transfer(
     'b4900000-0000-0000-0000-000000000001', 1, 1, 100000, 120000, now()) limit 1),
  false,
  'an edit addressed by the sending leg''s id finds the transfer'
);
set constraints all immediate;
set constraints all deferred;

select is(
  (select amount_e4 from transactions where id = 'b4900000-0000-0000-0000-000000000002'),
  120000::bigint,
  'and applies to it'
);

-- ============================================================================
-- 2. Moving a leg
-- ============================================================================

-- USD -> EUR destination: a cross-currency pair becomes a same-currency one,
-- so the two amounts have to agree, and do.
select is(
  (select conflict from update_transfer(
     'b4900000-0000-0000-0000-000000000001', 2, 2, 100000, 100000, now(), null, null,
     null, 'a4900000-0000-0000-0000-000000000002') limit 1),
  false,
  'the receiving leg moves to another of the owner''s accounts'
);
set constraints all immediate;
set constraints all deferred;

select results_eq(
  $$ select account_id, currency from transactions where id = 'b4900000-0000-0000-0000-000000000002' $$,
  $$ values ('a4900000-0000-0000-0000-000000000002'::uuid, 'EUR'::text) $$,
  'it lands on the new account in that account''s currency'
);

select is(
  (select coalesce(sum(amount_e4), 0) from transactions
   where account_id = 'a4900000-0000-0000-0000-000000000003' and deleted_at is null),
  0::numeric,
  'the account it left no longer carries it'
);

select throws_ok(
  $$ select * from update_transfer(
       'b4900000-0000-0000-0000-000000000001', 3, 3, 100000, 100000, now(), null, null,
       'a4900000-0000-0000-0000-000000000002', null) $$,
  'A transfer needs two different accounts.',
  'both legs cannot land on the same account'
);

reset role;
update accounts set deleted_at = now() where id = 'a4900000-0000-0000-0000-000000000004';
set local role authenticated;
select throws_ok(
  $$ select * from update_transfer(
       'b4900000-0000-0000-0000-000000000001', 3, 3, 100000, 100000, now(), null, null,
       null, 'a4900000-0000-0000-0000-000000000004') $$,
  'account not found or not accessible',
  'a deleted account is not a place a leg can move to'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a4900000-0000-0000-0000-000000000005', '22222222-2222-2222-2222-222222222222',
        '22222222-2222-2222-2222-222222222222', 'regular', 'B Euros', 'EUR', 0);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select throws_ok(
  $$ select * from update_transfer(
       'b4900000-0000-0000-0000-000000000001', 3, 3, 100000, 100000, now(), null, null,
       null, 'a4900000-0000-0000-0000-000000000005') $$,
  'account not found or not accessible',
  'somebody else''s account is not a place a leg can move to'
);

-- A move that leaves a same-currency pair unbalanced is the integrity
-- trigger's to refuse, at commit.
savepoint unbalanced;
select update_transfer(
  'b4900000-0000-0000-0000-000000000001', 3, 3, 100000, 90000, now());
select throws_like(
  $$ set constraints all immediate $$,
  '%same-currency legs must net to zero%',
  'a same-currency pair that no longer nets to zero is refused at commit'
);
rollback to savepoint unbalanced;

-- The version check still guards a move.
select is(
  (select conflict from update_transfer(
     'b4900000-0000-0000-0000-000000000001', 1, 1, 100000, 100000, now(), null, null,
     'a4900000-0000-0000-0000-000000000003', null) limit 1),
  true,
  'a stale version is a conflict, and moves nothing'
);

select * from finish();
rollback;
