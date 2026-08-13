-- create_transfer's client-supplied leg ids (migration
-- 20260807140000_idempotent_transfer_ids.sql) — the offline outbox's
-- retry-safety depends on a repeated call with the SAME ids failing loudly
-- (a PK violation) rather than silently duplicating the transfer. Fixture
-- A = 11111111-....

\ir _helpers.psql

begin;
select plan(5);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a2000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'checking', 'From', 'EUR', 1000);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a2000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'ledger', 'checking', 'To', 'EUR', 0);

-- 1. Omitting the id params still works exactly as before (backward
-- compatible — every existing online caller never passes them).
select is(
  (select count(*)::int from create_transfer(
    'a2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 10
  )),
  2,
  'create_transfer with no explicit ids still inserts exactly 2 legs'
);

-- 2. Explicit ids are honored — the two legs carry exactly the ids passed.
select create_transfer(
  'a2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 20, null, now(),
  'd2000000-0000-0000-0000-00000000f001', 'd2000000-0000-0000-0000-00000000f002'
);

select is(
  (select count(*)::int from transactions
   where id in ('d2000000-0000-0000-0000-00000000f001', 'd2000000-0000-0000-0000-00000000f002')),
  2,
  'explicit p_from_id/p_to_id are used as the legs'' actual ids'
);

-- 3. Retrying with the SAME ids (the outbox's exact retry scenario) raises
-- a primary-key violation, not a silent duplicate.
select throws_ok(
  $$ select create_transfer(
       'a2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 20, null, now(),
       'd2000000-0000-0000-0000-00000000f001', 'd2000000-0000-0000-0000-00000000f002'
     ) $$,
  '23505',
  null,
  'retrying create_transfer with the same ids raises a PK violation, not a duplicate'
);

-- 4. That failed retry left exactly the original 2 legs — no partial or
-- duplicate rows from the aborted second attempt.
select is(
  (select count(*)::int from transactions
   where id in ('d2000000-0000-0000-0000-00000000f001', 'd2000000-0000-0000-0000-00000000f002')),
  2,
  'the failed retry left exactly the original two legs, nothing extra'
);

-- 5. A DIFFERENT pair of explicit ids for a new transfer still works
-- normally — the PK guard only fires on an actual repeat.
select is(
  (select count(*)::int from create_transfer(
    'a2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 30, null, now(),
    'd2000000-0000-0000-0000-00000000f003', 'd2000000-0000-0000-0000-00000000f004'
  )),
  2,
  'a fresh pair of explicit ids for a different transfer succeeds normally'
);

select * from finish();
rollback;
