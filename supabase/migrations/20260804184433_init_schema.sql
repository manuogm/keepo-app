-- Phase 1 walking skeleton: currencies, profiles, accounts, balance_snapshots.
-- See app-architecture.md §3 for the full v1 schema design this migration is
-- the first slice of. Transactions land in Phase 2 — the ledger branch of
-- account_balances is deliberately partial here (see its comment below) and
-- extended via CREATE OR REPLACE VIEW once transactions exists.

create extension if not exists pgcrypto;

-- ============================================================================
-- Baseline privilege policy for schema public — must run before any table is
-- created below. Supabase's local cluster init grants TRUNCATE/REFERENCES/
-- TRIGGER/MAINTAIN to anon AND authenticated on every future table by
-- default (visible via pg_default_acl; confirmed anon can actually issue
-- TRUNCATE against a freshly created table). TRUNCATE bypasses RLS entirely,
-- so this is a live gap, not a cosmetic one. Fixed once here, at the schema
-- level, rather than per-table in every migration: ALTER DEFAULT PRIVILEGES
-- only affects objects created after it runs, by the same role (postgres —
-- confirmed migrations run as postgres, which owns the leaky default), so
-- placing this first means every table below is created clean.
-- ============================================================================

alter default privileges in schema public
  revoke truncate, references, trigger, maintain on tables from anon, authenticated;

-- ============================================================================
-- Enums (money rule 4 — enums, not text + CHECK)
-- ============================================================================

create type account_kind as enum ('ledger', 'valuation');

create type account_subtype as enum ('checking', 'cash', 'credit_card', 'loan', 'investment');

-- ============================================================================
-- Shared trigger functions (reused across tables; see CLAUDE.md Engineering
-- Principles — one place, called by every table that needs it)
-- ============================================================================

create function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Ownership is immutable after insert. Enforced by trigger rather than an RLS
-- WITH CHECK expression: a WITH CHECK on UPDATE only sees the incoming row,
-- not the pre-update row, so it cannot reliably compare "did owner_id change"
-- without a fragile self-referencing subquery. A BEFORE UPDATE trigger can
-- compare NEW to OLD directly. Reused by every owner_id-bearing table.
create function prevent_owner_id_change()
returns trigger
language plpgsql
as $$
begin
  if new.owner_id is distinct from old.owner_id then
    raise exception 'owner_id is immutable; use the household fork/leave path to reassign ownership';
  end if;
  return new;
end;
$$;

-- ============================================================================
-- currencies — reference table, the ECB/Frankfurter set. The client's
-- currency picker can only offer rows from here, so an account in a currency
-- Keepo cannot price can never be created.
-- ============================================================================

create table currencies (
  code text primary key check (code = upper(code) and length(code) = 3),
  minor_unit smallint not null check (minor_unit >= 0)
);

insert into currencies (code, minor_unit) values
  ('AUD', 2), ('BGN', 2), ('BRL', 2), ('CAD', 2), ('CHF', 2), ('CNY', 2),
  ('CZK', 2), ('DKK', 2), ('EUR', 2), ('GBP', 2), ('HKD', 2), ('HUF', 2),
  ('IDR', 2), ('ILS', 2), ('INR', 2), ('ISK', 0), ('JPY', 0), ('KRW', 0),
  ('MXN', 2), ('MYR', 2), ('NOK', 2), ('NZD', 2), ('PHP', 2), ('PLN', 2),
  ('RON', 2), ('SEK', 2), ('SGD', 2), ('THB', 2), ('TRY', 2), ('USD', 2),
  ('ZAR', 2);

alter table currencies enable row level security;

create policy currencies_select on currencies
  for select to authenticated
  using (true);

grant select on currencies to authenticated, service_role;

-- ============================================================================
-- profiles — one row per auth.users row, created by handle_new_user().
-- base_currency is nullable until onboarding chooses it; the CHECK stops
-- onboarding from ever being marked complete without one.
-- ============================================================================

create table profiles (
  id uuid primary key references auth.users (id) deferrable initially deferred,
  base_currency text references currencies (code),
  onboarded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint onboarded_requires_base_currency
    check (onboarded_at is null or base_currency is not null)
);

alter table profiles enable row level security;

create policy profiles_select on profiles
  for select to authenticated
  using (id = (select auth.uid()));

create policy profiles_update on profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

grant select, update on profiles to authenticated, service_role;

create trigger profiles_set_updated_at
  before update on profiles
  for each row execute function set_updated_at();

-- SECURITY DEFINER, search_path pinned empty: deliberately minimal, any
-- exception here aborts signup with an opaque error. ensure_user_bootstrap()
-- below is the idempotent self-heal for when it doesn't fire cleanly.
create function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

create function ensure_user_bootstrap()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (auth.uid())
  on conflict (id) do nothing;
end;
$$;

grant execute on function ensure_user_bootstrap() to authenticated;

-- ============================================================================
-- accounts
-- ============================================================================

create table accounts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  created_by uuid not null references auth.users (id) deferrable initially deferred,
  kind account_kind not null,
  subtype account_subtype not null,
  name text not null check (length(trim(name)) > 0),
  currency text not null references currencies (code),
  opening_balance numeric(20, 4) not null default 0,
  opening_balance_at date not null default current_date,
  include_in_total boolean not null default true,
  counts_toward_fi boolean not null default true,
  archived_at timestamptz,
  version integer not null default 1,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, currency),
  constraint subtype_matches_kind check (
    (kind = 'ledger' and subtype in ('checking', 'cash', 'credit_card', 'loan'))
    or (kind = 'valuation' and subtype = 'investment')
  )
);

create index accounts_owner_id_idx on accounts (owner_id);

alter table accounts enable row level security;

-- can_read_account / can_write_account are the ONLY predicates any RLS policy
-- calls for account-scoped tables. v1 body is ownership-only; when households
-- ship, can_read_account gains one OR EXISTS(household membership) clause and
-- every policy below upgrades in that same migration — no policy rewrite.
--
-- SECURITY DEFINER, not INVOKER: this function is called FROM the accounts
-- RLS policy, and its own body queries accounts. Under SECURITY INVOKER that
-- inner query is itself subject to RLS — re-triggering accounts_select,
-- which calls can_read_account again — infinite recursion (confirmed via
-- "stack depth limit exceeded" against a live query while building this
-- migration). SECURITY DEFINER makes the inner lookup bypass RLS, which is
-- exactly what a trusted predicate function is for; search_path is pinned
-- empty and the table is schema-qualified per standard SECURITY DEFINER
-- hygiene. EXECUTE is revoked from PUBLIC and granted explicitly, rather
-- than relying on the implicit PUBLIC-execute default — the same lesson as
-- the anon/TRUNCATE fix above: don't rely on implicit grants.
create function can_read_account(p_account_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.accounts
    where id = p_account_id and owner_id = (select auth.uid())
  );
$$;

revoke all on function can_read_account(uuid) from public;
grant execute on function can_read_account(uuid) to authenticated;

-- Symmetric with can_read_account in v1 (household members get equal
-- read/write on shared accounts). Calls can_read_account rather than
-- duplicating the check, so "same access" stays true in one place.
create function can_write_account(p_account_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.can_read_account(p_account_id);
$$;

revoke all on function can_write_account(uuid) from public;
grant execute on function can_write_account(uuid) to authenticated;

create policy accounts_select on accounts
  for select to authenticated
  using (can_read_account(id));

create policy accounts_insert on accounts
  for insert to authenticated
  with check (owner_id = (select auth.uid()) and created_by = (select auth.uid()));

create policy accounts_update on accounts
  for update to authenticated
  using (can_write_account(id))
  with check (can_write_account(id));

grant select, insert, update on accounts to authenticated, service_role;

create trigger accounts_set_updated_at
  before update on accounts
  for each row execute function set_updated_at();

create trigger accounts_prevent_owner_id_change
  before update on accounts
  for each row execute function prevent_owner_id_change();

-- ============================================================================
-- balance_snapshots — valuation accounts only. Append-only, like fx_rates:
-- no UPDATE/DELETE policy, a correction is a new snapshot, not an edit.
-- ============================================================================

create table balance_snapshots (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  currency text not null,
  as_of date not null,
  value numeric(20, 4) not null,
  created_by uuid not null references auth.users (id) deferrable initially deferred,
  created_at timestamptz not null default now(),
  foreign key (account_id, currency) references accounts (id, currency)
);

create index balance_snapshots_account_as_of_idx on balance_snapshots (account_id, as_of desc);

alter table balance_snapshots enable row level security;

create policy balance_snapshots_select on balance_snapshots
  for select to authenticated
  using (can_read_account(account_id));

create policy balance_snapshots_insert on balance_snapshots
  for insert to authenticated
  with check (can_write_account(account_id) and created_by = (select auth.uid()));

grant select, insert on balance_snapshots to authenticated, service_role;

-- ============================================================================
-- account_balances — no balance is ever stored on accounts (money rule 1).
--
-- PARTIAL FOR NOW: the ledger branch is opening_balance alone because
-- transactions doesn't exist until Phase 2. This is correct, not a stopgap —
-- a freshly created schema genuinely has zero transactions, so the formula
-- and its result agree. Phase 2's migration extends the ledger branch via
-- CREATE OR REPLACE VIEW to add "+ SUM(transactions.amount)"; the valuation
-- branch below is already complete and won't change.
-- ============================================================================

create view account_balances
with (security_invoker = true) as
select
  a.id as account_id,
  a.currency,
  case a.kind
    when 'ledger' then a.opening_balance
    when 'valuation' then (
      select bs.value
      from balance_snapshots bs
      where bs.account_id = a.id and bs.as_of <= current_date
      order by bs.as_of desc
      limit 1
    )
  end as balance
from accounts a
where a.deleted_at is null;

grant select on account_balances to authenticated, service_role;

-- Convenience join for screens that list accounts (Home, Accounts, Sync
-- Ritual per app-architecture.md §2's shared-component table) — one place
-- for the name+balance join instead of every screen re-deriving it.
create view accounts_with_balances
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
  ab.balance
from accounts a
join account_balances ab on ab.account_id = a.id
join currencies c on c.code = a.currency;

grant select on accounts_with_balances to authenticated, service_role;
