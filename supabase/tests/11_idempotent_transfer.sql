-- create_transfer's client-supplied leg ids (migration
-- 20260807140000_idempotent_transfer_ids.sql) — the offline outbox's
-- retry-safety depends on a repeated call with the SAME ids failing loudly
-- (a PK violation) rather than silently duplicating the transfer. Fixture
-- A = 11111111-....

\ir _helpers.psql

begin;
select plan(8);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a2000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'From', 'EUR', 1000);
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a2000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'regular', 'To', 'EUR', 0);

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

-- ============================================================================
-- 6-8. p_notes (migration 20260904100000) — a transfer can carry a note, and
-- it lands on BOTH legs, since either account's history read on its own must
-- still show what the user wrote.
-- ============================================================================

select is(
  (select count(*)::int from create_transfer(
    'a2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 40, null, now(),
    'd2000000-0000-0000-0000-00000000f005', 'd2000000-0000-0000-0000-00000000f006', 'Rent share'
  )),
  2,
  'create_transfer accepts a note'
);

select results_eq(
  $$ select notes from transactions
     where id in ('d2000000-0000-0000-0000-00000000f005', 'd2000000-0000-0000-0000-00000000f006')
     order by amount_e4 $$,
  $$ values ('Rent share'), ('Rent share') $$,
  'the note is written to both legs, not just the outgoing one'
);

select results_eq(
  $$ select notes from update_transfer(
       (select transfer_group_id from transactions where id = 'd2000000-0000-0000-0000-00000000f005'),
       1, 1, 45, 45, now(), 'Rent share, corrected'
     ) t, lateral (select (t.transaction).notes as notes) n $$,
  $$ values ('Rent share, corrected'), ('Rent share, corrected') $$,
  'update_transfer rewrites the note on both legs'
);

select * from finish();
rollback;
