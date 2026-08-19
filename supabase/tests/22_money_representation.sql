-- Local-first L1 (migration 20260815100000_money_as_integers.sql): the
-- representation-specific guarantees that don't belong to any one feature
-- test — the rounding contract on a negative amount, a zero-minor-unit
-- currency (JPY) round-tripping through the same bigint column every other
-- currency uses, and the documented headroom below bigint's ceiling.
-- Fixture A = 11111111-...

\ir _helpers.psql

begin;
select plan(5);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

reset role;
delete from fx_rates where currency = 'USD';
set local role service_role;
select upsert_fx_rate('USD', current_date, 0.9231, 'ecb', now());
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 1. The rounding contract is "half away from zero," not "half up" — a
-- negative amount rounds away from zero (more negative), matching
-- Postgres's own round() and Swift Decimal's `.plain` mode. -100005 e4
-- (-10.0005) at a rate of 0.9231 divides to a value whose 5th digit is
-- exactly 5, the case where "half up" and "half away from zero" diverge
-- for a negative number.
select is(
  fx_convert(-100005, 'EUR', 'USD', current_date),
  round(-100005::numeric / fx_rate_on('EUR', current_date) * fx_rate_on('USD', current_date))::bigint,
  'fx_convert rounds a negative amount half away from zero, matching Postgres round() exactly'
);

-- 2. A zero-minor-unit currency (JPY — no display decimals) is stored at
-- the same fixed scale 4 as every other currency; the money layer itself
-- never special-cases it; only display (KeepoCore MoneyFormatter, Swift
-- side) divides by 10^minor_unit instead of a constant 10^4.
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a9000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'JPY Wallet', 'JPY', 1000000000);

insert into categories (id, owner_id, kind, name)
values ('c9000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Test Expense');

insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (auth.uid(), auth.uid(), 'a9000000-0000-0000-0000-000000000001', 'c9000000-0000-0000-0000-000000000001', -300000000, 'JPY', now());

select is(
  account_balance_on('a9000000-0000-0000-0000-000000000001', current_date),
  700000000::bigint,
  'a JPY (zero-minor-unit) account balances via the exact same bigint arithmetic as every other currency'
);

select is(
  (select minor_unit from currencies where code = 'JPY'),
  0::smallint,
  'JPY is seeded with minor_unit = 0 — the display divisor 10^minor_unit is 1, not the constant 10^4 storage scale'
);

-- 3. Documented headroom: a mid-eight-figure balance (tens of millions in
-- major-currency units) round-trips through account_balance_on with no
-- precision loss — bigint's ceiling (~9.2e18) is not reachable by any
-- balance this app will ever hold, only by the FX-conversion multiply at
-- the extreme end documented in keepo-local-first-plan.md (LH7).
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a9000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'regular', 'Large Balance', 'EUR', 999999999990000);

select is(
  account_balance_on('a9000000-0000-0000-0000-000000000002', current_date),
  999999999990000::bigint,
  'a large balance (≈€100bn at e4) round-trips exactly — nowhere near bigint''s ~9.2e18 ceiling'
);

-- 4. fx_convert at that same large balance stays exact to the rounding
-- contract — the multiply/divide intermediate is done in `numeric`
-- (arbitrary precision), only the final result is cast to bigint.
select is(
  fx_convert(999999999990000, 'EUR', 'USD', current_date),
  round(999999999990000::numeric / fx_rate_on('EUR', current_date) * fx_rate_on('USD', current_date))::bigint,
  'fx_convert stays exact to the rounding contract even at a large balance'
);

select * from finish();
rollback;
