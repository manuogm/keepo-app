-- Phase 4: FX conversion. Deferred from Phase 2 ("FX conversion of the
-- list → Phase 4") and fully specified already in app-architecture.md §3/§4
-- — this migration implements that existing design rather than redesigning
-- it: fx_rates, fx_rate_on(), fx_convert(), and account_balances_base,
-- applied to the two screens that exist today (Accounts, Transactions).
-- pg_cron/pg_net scheduling, vault secret provisioning, and the
-- 400-day-backfill-on-first-use trigger are deliberately deferred — no
-- automation/ops infrastructure exists anywhere in this codebase yet, and
-- bundling scheduling in here would mix "build FX conversion" with "build
-- the ops platform." See version-logs/phase-4-log.md.

-- ============================================================================
-- fx_source — currently just 'ecb', per app-architecture.md §3. An enum
-- (money rule 4) so a future second source is a type addition, not a text
-- column that silently accepts anything.
-- ============================================================================

create type fx_source as enum ('ecb');

-- ============================================================================
-- fx_rates — append-only-in-spirit (see money rule 6), upserted rather than
-- blind-inserted: a later fetched_at for the same (currency, rate_date) wins,
-- which is how an ECB revision to a recent value gets picked up without
-- destructively rewriting history. EUR itself never gets a row — its rate is
-- structurally 1, enforced in fx_rate_on below, not stored here.
-- No insert/update grant to anyone, not even service_role directly — every
-- write goes through upsert_fx_rate() so the "later fetched_at wins" rule
-- can never be bypassed by a naive upsert from the Edge Function.
-- ============================================================================

create table fx_rates (
  currency text not null references currencies (code),
  rate_date date not null,
  rate_to_eur numeric(20, 4) not null,
  source fx_source not null,
  fetched_at timestamptz not null default now(),
  primary key (currency, rate_date)
);

alter table fx_rates enable row level security;

create policy fx_rates_select on fx_rates
  for select to authenticated
  using (true);

grant select on fx_rates to authenticated, service_role;

-- ============================================================================
-- upsert_fx_rate — the only way any row is ever written to fx_rates.
-- Encapsulates the "later fetched_at wins" rule as a real WHERE clause on
-- the upsert, something a raw client-side upsert can't express
-- conditionally. SECURITY DEFINER so it can write despite fx_rates having
-- no INSERT/UPDATE grant. Only service_role gets EXECUTE — the app never
-- holds service_role (CLAUDE.md), so this is unreachable from the client
-- even if attempted; only the sync-fx-rates Edge Function calls it.
-- ============================================================================

create function upsert_fx_rate(
  p_currency text,
  p_rate_date date,
  p_rate_to_eur numeric,
  p_source fx_source default 'ecb',
  p_fetched_at timestamptz default now()
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.fx_rates (currency, rate_date, rate_to_eur, source, fetched_at)
  values (p_currency, p_rate_date, p_rate_to_eur, p_source, p_fetched_at)
  on conflict (currency, rate_date) do update
  set rate_to_eur = excluded.rate_to_eur,
      source = excluded.source,
      fetched_at = excluded.fetched_at
  where excluded.fetched_at > public.fx_rates.fetched_at;
$$;

revoke all on function upsert_fx_rate(text, date, numeric, fx_source, timestamptz) from public;
grant execute on function upsert_fx_rate(text, date, numeric, fx_source, timestamptz) to service_role;

-- ============================================================================
-- fx_rate_on — resolves the most recent fx_rates row at or before p_date,
-- carrying forward over weekends/holidays. SECURITY INVOKER (the default,
-- made explicit, same reasoning create_transfer's own comment gives): this
-- is a read helper over a table authenticated already has SELECT on, no
-- privilege bypass needed.
-- ============================================================================

create function fx_rate_on(p_currency text, p_date date)
returns numeric
language sql
stable
security invoker
set search_path = ''
as $$
  select case
    when p_currency = 'EUR' then 1
    else (
      select fr.rate_to_eur
      from public.fx_rates fr
      where fr.currency = p_currency and fr.rate_date <= p_date
      order by fr.rate_date desc
      limit 1
    )
  end;
$$;

revoke all on function fx_rate_on(text, date) from public;
grant execute on function fx_rate_on(text, date) to authenticated, service_role;

-- ============================================================================
-- fx_convert — the only place currency conversion happens
-- (app-architecture.md §3), never duplicated. NULL propagates through
-- Postgres arithmetic on its own: no CASE needed to return NULL (not 0,
-- money rule 5) when either rate is missing.
-- ============================================================================

create function fx_convert(p_amount numeric, p_from text, p_to text, p_date date)
returns numeric
language sql
stable
security invoker
set search_path = ''
as $$
  select p_amount / public.fx_rate_on(p_from, p_date) * public.fx_rate_on(p_to, p_date);
$$;

revoke all on function fx_convert(numeric, text, text, date) from public;
grant execute on function fx_convert(numeric, text, text, date) to authenticated, service_role;

-- ============================================================================
-- account_balances_base — a new view, not an extension of account_balances:
-- account_balances is ledger/valuation balance math unrelated to any
-- particular viewer's base currency, while this is inherently per-user and
-- is what net_worth() (future phase) will join. has_missing_rate is false,
-- not true, when balance itself is null (e.g. an unsnapshotted valuation
-- account) — that's a missing-balance state, distinct from a missing-rate
-- state; conflating them would mislabel the reason for the "—". No RLS
-- policy of its own needed: security_invoker plus accounts'/profiles' own
-- RLS already scope every row, same pattern as account_balances.
-- ============================================================================

create view account_balances_base
with (security_invoker = true) as
select
  ab.account_id,
  ab.currency,
  ab.balance,
  a.owner_id,
  p.base_currency,
  fx_convert(ab.balance, ab.currency, p.base_currency, current_date) as balance_base,
  (
    ab.balance is not null
    and fx_convert(ab.balance, ab.currency, p.base_currency, current_date) is null
  ) as has_missing_rate
from account_balances ab
join accounts a on a.id = ab.account_id
join profiles p on p.id = a.owner_id;

grant select on account_balances_base to authenticated, service_role;

-- ============================================================================
-- accounts_with_balances: append base-currency columns at the end (CREATE OR
-- REPLACE VIEW can't reorder or insert columns mid-list, per Phase 3's
-- finding). left join on bc since base_currency is nullable pre-onboarding.
-- ============================================================================

create or replace view accounts_with_balances
with (security_invoker = true) as
select
  a.id as account_id,
  a.name,
  a.kind,
  a.subtype,
  a.currency,
  c.minor_unit,
  a.include_in_total,
  a.counts_toward_fi,
  a.archived_at,
  ab.balance,
  abb.base_currency,
  bc.minor_unit as base_minor_unit,
  abb.balance_base,
  abb.has_missing_rate
from accounts a
join account_balances ab on ab.account_id = a.id
join currencies c on c.code = a.currency
join account_balances_base abb on abb.account_id = a.id
left join currencies bc on bc.code = abb.base_currency;

grant select on accounts_with_balances to authenticated, service_role;

-- ============================================================================
-- transactions_with_details: same append-only-columns treatment. t.amount
-- is not null in the schema, so has_missing_rate here is unambiguous — no
-- analogous "amount itself unknown" state exists for a transaction row.
-- ============================================================================

create or replace view transactions_with_details
with (security_invoker = true) as
select
  t.id as transaction_id,
  t.account_id,
  a.name as account_name,
  t.category_id,
  c.name as category_name,
  t.amount,
  t.currency,
  cur.minor_unit,
  t.occurred_at,
  t.merchant_raw,
  t.merchant_normalized,
  t.transfer_group_id,
  t.source,
  t.status,
  case
    when t.transfer_group_id is not null then 'transfer'
    when t.amount < 0 then 'expense'
    else 'income'
  end as kind,
  t.created_by,
  t.created_at,
  t.version,
  p.base_currency,
  bc.minor_unit as base_minor_unit,
  fx_convert(t.amount, t.currency, p.base_currency, t.occurred_at::date) as amount_base,
  (fx_convert(t.amount, t.currency, p.base_currency, t.occurred_at::date) is null) as has_missing_rate
from transactions t
join accounts a on a.id = t.account_id
left join categories c on c.id = t.category_id
join currencies cur on cur.code = t.currency
join profiles p on p.id = t.owner_id
left join currencies bc on bc.code = p.base_currency
where t.deleted_at is null;

grant select on transactions_with_details to authenticated, service_role;
