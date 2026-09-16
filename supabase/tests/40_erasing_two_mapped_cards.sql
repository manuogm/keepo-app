-- Deleting your account with more than one mapped card
-- (20260924100000_erase_scrubs_card_identifiers_uniquely.sql).
--
-- The defect was one statement deep and total in effect: `erase_own_account`
-- scrubbed every card identifier to the same literal `'erased'` against a
-- `unique (owner_id, card_identifier)`, so the second card collided with the
-- first. `delete_own_account` calls `erase_own_account` as its very first
-- act, so the whole deletion aborted — for every user who had mapped two
-- cards, which is to say everyone who had actually used capture.
--
-- Found in the hosted Edge Function logs, not by a test, which is why these
-- assertions exist: the old suite only ever erased a user holding **one**
-- mapping, and one is exactly the count at which the bug is invisible.

\ir _helpers.psql

begin;
select plan(6);

-- Seeded as postgres, not as the user: `authenticated` deliberately holds no
-- INSERT grant on card_mappings — every real row arrives through a SECURITY
-- DEFINER RPC (`map_card`, or `capture_transaction`'s unmapped placeholder).
-- What is under test is the scrub, not how a mapping comes to exist, so the
-- fixture takes the short way in.
reset role;

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a4000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'Cards', 'EUR', 0),
  ('a4000000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'regular', 'Cards', 'EUR', 0);

insert into card_mappings (owner_id, card_identifier, account_id) values
  ('11111111-1111-1111-1111-111111111111', 'card-one', 'a4000000-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111', 'card-two', 'a4000000-0000-0000-0000-000000000001'),
  ('22222222-2222-2222-2222-222222222222', 'card-three', 'a4000000-0000-0000-0000-000000000002'),
  ('22222222-2222-2222-2222-222222222222', 'card-four', 'a4000000-0000-0000-0000-000000000002');

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 1. The statement that used to abort the entire transaction.
select lives_ok(
  $$ select erase_own_account() $$,
  'erase_own_account survives a caller holding two mapped cards'
);

-- 2. Erasure destroys the identifier, not the mapping.
select is(
  (select count(*)::int from card_mappings where owner_id = auth.uid()),
  2,
  'both mappings survive the scrub'
);

-- 3. And it really did destroy it.
select is(
  (select count(*)::int from card_mappings
   where owner_id = auth.uid() and card_identifier in ('card-one', 'card-two')),
  0,
  'neither mapping still carries the identifier it was created with'
);

-- 4. The property the unique constraint actually needs. This is the
--    assertion that fails against the old function.
select is(
  (select count(distinct card_identifier)::int from card_mappings where owner_id = auth.uid()),
  2,
  'the scrubbed identifiers are distinct from one another'
);

-- 5. Idempotent: the replacement derives from each row's own primary key, so
--    a second pass rewrites every row to the value it already holds rather
--    than colliding all over again.
select lives_ok(
  $$ select erase_own_account() $$,
  'a second erase is a no-op, not a fresh collision'
);

-- 6. End to end, as the Edge Function calls it, on a second identity with
--    its own two cards — the actual reported failure.
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select lives_ok(
  $$ select delete_own_account() $$,
  'delete_own_account completes for a user with two mapped cards'
);

rollback;
