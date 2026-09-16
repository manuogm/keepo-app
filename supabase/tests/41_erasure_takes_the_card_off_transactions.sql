-- Erasure destroys the card token everywhere it is written, not just in the
-- table that indexes it (20260925100000).
--
-- `erase_own_account` scrubbed `card_mappings.card_identifier` and the two
-- merchant columns, and left the identical token sitting on every captured
-- transaction. Invisible through `delete_own_account`, which deletes those
-- rows anyway — which is exactly why it went unnoticed, and exactly why
-- these assertions target `erase_own_account` directly, as the separate
-- `authenticated`-grantable function it is.

\ir _helpers.psql

begin;
select plan(5);

-- Seeded as postgres: `authenticated` holds no direct INSERT grant on
-- card_mappings, and capture_transaction would drag a rate-limit window and
-- an FX lookup into a test about a scrub.
reset role;

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a4100000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        '11111111-1111-1111-1111-111111111111', 'regular', 'Cards', 'EUR', 0);

insert into categories (id, owner_id, kind, name, icon, color)
values ('c4100000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'expense', 'Groceries', 'cart.fill', '#00FF00');

insert into card_mappings (owner_id, card_identifier, account_id)
values ('11111111-1111-1111-1111-111111111111', 'card-alpha',
        'a4100000-0000-0000-0000-000000000001');

-- `category_kind` is derived by set_transaction_derived_columns, never set
-- by a writer — same reason no test in this suite passes it.
insert into transactions (
  id, owner_id, created_by, account_id, currency, category_id,
  amount_e4, occurred_at, source, status, card_identifier, merchant_raw, merchant_normalized
) values (
  '44100000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
  '11111111-1111-1111-1111-111111111111', 'a4100000-0000-0000-0000-000000000001', 'EUR',
  'c4100000-0000-0000-0000-000000000001',
  -1500, now(), 'capture', 'confirmed', 'card-alpha', 'MERCADONA 4821', 'mercadona'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select lives_ok(
  $$ select erase_own_account() $$,
  'erase_own_account completes with a captured transaction present'
);

-- 1. The gap this migration closes.
select is(
  (select card_identifier from transactions where id = '44100000-0000-0000-0000-000000000001'),
  null,
  'the card token is gone from the transaction, not only from the mapping'
);

-- 2/3. The scrubs that already worked keep working — a restated function is
--      the easiest place in this codebase to lose a line by accident.
select is(
  (select merchant_raw from transactions where id = '44100000-0000-0000-0000-000000000001'),
  null,
  'merchant_raw is still scrubbed'
);

select is(
  (select merchant_normalized from transactions where id = '44100000-0000-0000-0000-000000000001'),
  null,
  'merchant_normalized is still scrubbed'
);

-- 4. Erasure destroys what identifies the person, never the money. The
--    amount is the record of what happened and is not the caller's to be
--    rid of by erasing — `delete_own_account` is what removes the row.
select is(
  (select amount_e4 from transactions where id = '44100000-0000-0000-0000-000000000001'),
  -1500::bigint,
  'the amount survives the scrub untouched'
);

rollback;
