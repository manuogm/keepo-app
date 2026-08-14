-- account_balance_on for a valuation account used to return NULL for any
-- date before its earliest balance_snapshots row, poisoning the whole
-- net_worth_series and blanking the client's chart (a real bug reported
-- against the app: net worth today computed fine, the trailing chart went
-- entirely blank). A ledger account in the same situation falls back to
-- opening_balance_e4 and stays computable, so a valuation account should
-- symmetrically fall back to its own earliest snapshot for any date before
-- it, rather than going unknown. Migration 20260818100000.
-- Fixture A = 11111111-... (base EUR).

\ir _helpers.psql

begin;
select plan(4);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values (
  'e8000000-0000-0000-0000-00000000e401', auth.uid(), auth.uid(), 'valuation', 'investment', 'Brokerage', 'EUR', 0
);

-- The account's only snapshot is dated 10 days ago.
insert into balance_snapshots (account_id, currency, as_of, value_e4, created_by, created_at)
values (
  'e8000000-0000-0000-0000-00000000e401', 'EUR', (current_date - 10), 5000000,
  auth.uid(), (now() - interval '10 days')
);

select is(
  account_balance_on('e8000000-0000-0000-0000-00000000e401', (current_date - 20)),
  5000000::bigint,
  'a date before the account''s only snapshot falls back to that snapshot''s value, not NULL'
);

select is(
  account_balance_on('e8000000-0000-0000-0000-00000000e401', (current_date - 10)),
  5000000::bigint,
  'the snapshot''s own as_of date still resolves via the normal at-or-before path'
);

-- A second, earlier snapshot makes the fallback prefer the true earliest
-- one, not just "the first row found".
insert into balance_snapshots (account_id, currency, as_of, value_e4, created_by, created_at)
values (
  'e8000000-0000-0000-0000-00000000e401', 'EUR', (current_date - 30), 4000000,
  auth.uid(), (now() - interval '30 days')
);

select is(
  account_balance_on('e8000000-0000-0000-0000-00000000e401', (current_date - 40)),
  4000000::bigint,
  'with two snapshots, a date before both falls back to the earliest one, not the first row'
);

-- An account with no snapshot at all is still exactly NULL (money rule 5) --
-- the fallback must never invent a value out of nothing.
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values (
  'e8000000-0000-0000-0000-00000000e402', auth.uid(), auth.uid(), 'valuation', 'investment', 'No Snapshot', 'EUR', 0
);

select is(
  account_balance_on('e8000000-0000-0000-0000-00000000e402', current_date),
  null::bigint,
  'a valuation account with no snapshot at all still renders NULL, never a fabricated value'
);

select * from finish();
rollback;
