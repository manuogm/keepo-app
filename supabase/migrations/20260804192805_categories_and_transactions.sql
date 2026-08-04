-- Phase 2: categories and transactions. Also fixes three defects found while
-- planning this phase against the actual Phase 1 schema (not the design
-- doc's description of it):
--   1. account_balances' valuation branch was missing "+ SUM(transfers
--      dated after the snapshot)" — money rule 1 requires it, and it only
--      looked correct before because zero transactions existed yet.
--   2. accounts.version shipped with no trigger ever incrementing it.
--   3. handle_new_user()/ensure_user_bootstrap() never seeded the default
--      "Other" categories the app-architecture.md doc said they did.

-- ============================================================================
-- Enums
-- ============================================================================

create type category_kind as enum ('expense', 'income');
create type transaction_source as enum ('manual', 'capture', 'recurring', 'adjustment', 'csv_import');
create type transaction_status as enum ('pending', 'confirmed');

-- ============================================================================
-- Shared: version bump trigger (defect 2 — also retrofitted onto accounts,
-- which shipped in Phase 1 with the column but no trigger).
-- ============================================================================

create function bump_version()
returns trigger
language plpgsql
as $$
begin
  new.version = old.version + 1;
  return new;
end;
$$;

create trigger accounts_bump_version
  before update on accounts
  for each row execute function bump_version();

-- ============================================================================
-- categories
-- ============================================================================

create table categories (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  kind category_kind not null,
  name text not null check (length(trim(name)) > 0),
  is_default boolean not null default false,
  version integer not null default 1,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, kind)
);

-- Exactly one is_default row per (owner, kind) — the arbiter handle_new_user()
-- and ensure_user_bootstrap() below insert against with ON CONFLICT.
create unique index categories_one_default_per_kind
  on categories (owner_id, kind)
  where is_default and deleted_at is null;

create index categories_owner_kind_idx on categories (owner_id, kind);

alter table categories enable row level security;

create policy categories_select on categories
  for select to authenticated
  using (owner_id = (select auth.uid()));

create policy categories_insert on categories
  for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy categories_update on categories
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

grant select, insert, update on categories to authenticated, service_role;

create trigger categories_set_updated_at
  before update on categories
  for each row execute function set_updated_at();

create trigger categories_bump_version
  before update on categories
  for each row execute function bump_version();

create trigger categories_prevent_owner_id_change
  before update on categories
  for each row execute function prevent_owner_id_change();

-- Server-side enforcement of "the two Other rows have no delete affordance"
-- (spec) — not just a hidden button. deleted_at is the soft-delete tombstone;
-- a default category may never carry one.
create function prevent_default_category_deletion()
returns trigger
language plpgsql
as $$
begin
  if new.is_default and new.deleted_at is not null then
    raise exception 'the default category cannot be deleted';
  end if;
  return new;
end;
$$;

create trigger categories_prevent_default_deletion
  before update on categories
  for each row execute function prevent_default_category_deletion();

-- ============================================================================
-- accounts: add the unique targets the composite FKs from transactions need
-- (Postgres requires a unique constraint on the exact referenced column
-- tuple even though `id` alone is already unique — same reasoning as
-- Phase 1's UNIQUE (id, currency)). (id, owner_id) is the one Phase 1 should
-- have added already — its own migration comment describes the FK this
-- enables ("closes a hole RLS doesn't cover") but never actually created
-- the constraint the FK needs; caught here by db reset failing outright
-- rather than by inspection.
-- ============================================================================

alter table accounts add constraint accounts_id_owner_id_key unique (id, owner_id);
alter table accounts add constraint accounts_id_kind_key unique (id, kind);

-- ============================================================================
-- Fifth defect, found only by testing INSERT ... RETURNING against a live
-- database (not by inspection — this one is genuinely subtle): accounts'
-- own SELECT/UPDATE policies routed through can_read_account/can_write_
-- account, which re-query `accounts` from inside a SECURITY DEFINER
-- function. That self-reference — the function querying the very table
-- whose policy is calling it — breaks specifically for RETURNING on a row
-- written earlier in the SAME command: Postgres does not consistently make
-- that row visible to the function's own fresh subquery, regardless of
-- STABLE/VOLATILE or SQL/plpgsql (both tried and ruled out empirically).
-- A bare inline expression needs no such lookup and is unaffected — proven
-- by testing INSERT ... RETURNING against transactions (which calls
-- can_read_account for a DIFFERENT, already-existing table row) succeeding
-- perfectly, isolating the bug to self-reference specifically. This is why
-- create_transfer()'s own `RETURNING`-via-`SELECT ... FROM transactions`
-- below is safe: it queries transactions, not accounts.
--
-- Fix: accounts' own two policies compare owner_id directly. This is the
-- one place the "every account-scoped policy calls the shared predicate"
-- design (so households upgrade every policy via one function-body edit)
-- has an exception — Phase 7 will need to also edit these two policies
-- directly, in addition to the function body, and that's an accepted,
-- documented cost of a real engine bug rather than a design mistake.
-- Migration 001 already shipped to the hosted project in Phase 1, so this
-- corrects it here rather than hand-editing an already-pushed migration.
-- ============================================================================

drop policy accounts_select on accounts;
create policy accounts_select on accounts
  for select to authenticated
  using (owner_id = (select auth.uid()));

drop policy accounts_update on accounts;
create policy accounts_update on accounts
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

-- ============================================================================
-- transactions
-- ============================================================================

create table transactions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  created_by uuid not null references auth.users (id) deferrable initially deferred,
  account_id uuid not null,
  -- Populated by set_transaction_derived_columns() below, never set by the
  -- client — this is what lets the composite FKs enforce "valuation accounts
  -- take transfers only" and "expense/income category kind matches sign"
  -- declaratively instead of trusting application code.
  account_kind account_kind,
  category_id uuid,
  category_kind category_kind,
  amount numeric(20, 4) not null,
  currency text not null,
  occurred_at timestamptz not null default now(),
  merchant_raw text,
  merchant_normalized text,
  transfer_group_id uuid,
  source transaction_source not null default 'manual',
  status transaction_status not null default 'confirmed',
  external_id text,
  version integer not null default 1,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Can't post to another user's account — RLS checks auth.uid() on the row
  -- being written, not on the account it references; this closes that gap.
  foreign key (account_id, owner_id) references accounts (id, owner_id) deferrable initially deferred,
  -- Transaction currency is locked to its account's.
  foreign key (account_id, currency) references accounts (id, currency) deferrable initially deferred,
  -- Valuation accounts take transfers only — enforced via the account_kind
  -- mirror column plus the CHECK below, not trusted to application code.
  foreign key (account_id, account_kind) references accounts (id, kind) deferrable initially deferred,
  -- An expense can't file under an income category (or vice versa). Both
  -- columns are NULL for transfers; MATCH SIMPLE (the default) skips the
  -- check whenever any referencing column is NULL.
  foreign key (category_id, category_kind) references categories (id, kind) deferrable initially deferred,

  constraint amount_not_zero check (amount <> 0),
  constraint transfer_xor_category check (
    (transfer_group_id is not null and category_id is null)
    or (transfer_group_id is null and category_id is not null)
  ),
  constraint sign_matches_category_kind check (
    transfer_group_id is not null
    or (category_kind = 'expense' and amount < 0)
    or (category_kind = 'income' and amount > 0)
  ),
  constraint valuation_transfers_only check (
    account_kind = 'ledger' or transfer_group_id is not null
  )
);

create index transactions_account_id_idx on transactions (account_id);
create index transactions_category_id_idx on transactions (category_id);
create index transactions_owner_occurred_idx on transactions (owner_id, occurred_at desc, id desc);
create index transactions_transfer_group_idx on transactions (transfer_group_id) where transfer_group_id is not null;
-- Capture/import idempotency (Phase 8): a re-fired automation or overlapping
-- import must be a no-op, never a duplicate.
create unique index transactions_external_id_idx
  on transactions (owner_id, source, external_id)
  where external_id is not null;

alter table transactions enable row level security;

create policy transactions_select on transactions
  for select to authenticated
  using (can_read_account(account_id));

create policy transactions_insert on transactions
  for insert to authenticated
  with check (can_write_account(account_id) and created_by = (select auth.uid()));

-- Full editing (Phase 3) isn't built yet — today the only client caller of
-- UPDATE is soft-delete (setting deleted_at). RLS can't restrict which
-- columns an UPDATE touches; that's acceptable for now since there's no UI
-- path that would misuse it, but worth remembering when Phase 3 adds one.
create policy transactions_update on transactions
  for update to authenticated
  using (can_write_account(account_id))
  with check (can_write_account(account_id));

grant select, insert, update on transactions to authenticated, service_role;

create trigger transactions_set_updated_at
  before update on transactions
  for each row execute function set_updated_at();

create trigger transactions_bump_version
  before update on transactions
  for each row execute function bump_version();

create trigger transactions_prevent_owner_id_change
  before update on transactions
  for each row execute function prevent_owner_id_change();

-- Populates account_kind from account_id and category_kind from category_id
-- before every insert/update, so the client never sets — and can never
-- desync — either mirror column. SECURITY DEFINER so the lookup isn't
-- itself subject to RLS, same reasoning as can_read_account in Phase 1.
create function set_transaction_derived_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select kind into new.account_kind from public.accounts where id = new.account_id;

  if new.category_id is not null then
    select kind into new.category_kind from public.categories where id = new.category_id;
  else
    new.category_kind := null;
  end if;

  return new;
end;
$$;

revoke all on function set_transaction_derived_columns() from public;

create trigger transactions_set_derived_columns
  before insert or update on transactions
  for each row execute function set_transaction_derived_columns();

-- Transfer integrity: deferred to end-of-statement so both legs of a
-- transfer can be inserted independently within one transaction (as
-- create_transfer() below does). Per transfer_group_id: exactly 0 or 2
-- non-deleted legs (never 1 — soft-deleting one leg can't orphan the
-- other), distinct accounts, one owner, and nets to zero only when both
-- legs share a currency (a cross-currency difference is the real spread,
-- not an error).
create function check_transfer_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
  v_leg_count integer;
  v_distinct_accounts integer;
  v_distinct_owners integer;
  v_distinct_currencies integer;
  v_sum numeric(20, 4);
begin
  v_group := coalesce(new.transfer_group_id, old.transfer_group_id);
  if v_group is null then
    return null;
  end if;

  select
    count(*), count(distinct account_id), count(distinct owner_id), count(distinct currency), sum(amount)
  into v_leg_count, v_distinct_accounts, v_distinct_owners, v_distinct_currencies, v_sum
  from public.transactions
  where transfer_group_id = v_group and deleted_at is null;

  if v_leg_count not in (0, 2) then
    raise exception 'transfer % must have exactly 2 legs, found %', v_group, v_leg_count;
  end if;

  if v_leg_count = 2 then
    if v_distinct_accounts <> 2 then
      raise exception 'transfer % legs must reference distinct accounts', v_group;
    end if;
    if v_distinct_owners <> 1 then
      raise exception 'transfer % legs must share one owner', v_group;
    end if;
    if v_distinct_currencies = 1 and v_sum <> 0 then
      raise exception 'transfer % same-currency legs must net to zero', v_group;
    end if;
  end if;

  return null;
end;
$$;

create constraint trigger transactions_check_transfer_integrity
  after insert or update or delete on transactions
  deferrable initially deferred
  for each row execute function check_transfer_integrity();

-- ============================================================================
-- account_balances — CREATE OR REPLACE extends BOTH branches from Phase 1's
-- partial version (defect 1). Ledger: opening_balance + SUM(amount). Both
-- branches filter deleted_at is null, status = 'confirmed' (a pending
-- capture must not move a balance until reviewed — see Phase 2 plan's
-- "flagged for Phase 8" note), and occurred_at <= now() (so a future-dated
-- recurring row, once Phase-later adds those, can never corrupt today's
-- balance).
-- ============================================================================

create or replace view account_balances
with (security_invoker = true) as
select
  a.id as account_id,
  a.currency,
  case a.kind
    when 'ledger' then a.opening_balance + coalesce((
      select sum(t.amount)
      from transactions t
      where t.account_id = a.id
        and t.deleted_at is null
        and t.status = 'confirmed'
        and t.occurred_at <= now()
    ), 0)
    when 'valuation' then (
      -- "Transfers after the snapshot" compares against bs.created_at (the
      -- real timestamp the snapshot was recorded), not bs.as_of::date
      -- truncated to a day — found by live-testing the exact common case
      -- this exists for: fund a brand-new investment account same-day.
      -- as_of is a date (backdating-friendly for Phase 5's Sync Ritual);
      -- occurred_at is a full timestamp. Comparing occurred_at::date >
      -- as_of made "today > today" false, silently dropping every
      -- same-day transfer. created_at has no such precision gap. Once
      -- Phase 5 allows entering a snapshot for a past as_of, created_at
      -- (when it was actually recorded) remains the right anchor — it's
      -- still "everything that moved since this reconciliation happened,"
      -- not "everything after the date the user typed."
      select bs.value + coalesce((
        select sum(t2.amount)
        from transactions t2
        where t2.account_id = a.id
          and t2.deleted_at is null
          and t2.status = 'confirmed'
          and t2.occurred_at <= now()
          and t2.occurred_at > bs.created_at
      ), 0)
      from balance_snapshots bs
      where bs.account_id = a.id and bs.as_of <= current_date
      order by bs.as_of desc
      limit 1
    )
  end as balance
from accounts a
where a.deleted_at is null;

-- ============================================================================
-- transactions_with_details — one join for every screen that lists
-- transactions, mirroring accounts_with_balances' role for accounts. `kind`
-- is derived here rather than stored: a GENERATED ALWAYS column would need
-- an IMMUTABLE cast to the account_kind/category_kind enums, and enum_in is
-- only STABLE (confirmed via pg_proc while planning this phase) — deriving
-- in the view gives the same can-never-disagree guarantee with no stored
-- denormalization and no fragile generation expression.
-- ============================================================================

create view transactions_with_details
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
  t.created_at
from transactions t
join accounts a on a.id = t.account_id
left join categories c on c.id = t.category_id
join currencies cur on cur.code = t.currency
where t.deleted_at is null;

grant select on transactions_with_details to authenticated, service_role;

-- ============================================================================
-- create_transfer — the only transaction kind that needs an RPC. Expense and
-- income are a plain insert: the sign_matches_category_kind CHECK above
-- makes a wrong sign impossible without any application code enforcing it.
-- A transfer needs both legs inserted atomically with signs applied here in
-- SQL (money rule: never re-sign in application code), so it gets a
-- narrow RPC instead. SECURITY INVOKER (the default, made explicit) — this
-- is a convenience wrapper around ordinary inserts, not a privilege
-- escalation, so RLS and every constraint above still fully apply.
-- ============================================================================

create function create_transfer(
  p_from_account_id uuid,
  p_to_account_id uuid,
  p_from_amount numeric,
  p_to_amount numeric default null,
  p_occurred_at timestamptz default now()
)
returns setof transactions
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_from_owner uuid;
  v_from_currency text;
  v_to_owner uuid;
  v_to_currency text;
  v_to_amount numeric(20, 4);
  v_group uuid := gen_random_uuid();
begin
  if p_from_amount is null or p_from_amount <= 0 then
    raise exception 'from_amount must be a positive magnitude';
  end if;

  -- RLS on accounts.select filters what these can see; a NULL result means
  -- "not found or not accessible" and is treated identically either way.
  select owner_id, currency into v_from_owner, v_from_currency
  from public.accounts where id = p_from_account_id;
  select owner_id, currency into v_to_owner, v_to_currency
  from public.accounts where id = p_to_account_id;

  if v_from_currency is null or v_to_currency is null then
    raise exception 'one or both accounts were not found or are not accessible';
  end if;

  v_to_amount := coalesce(
    p_to_amount,
    case when v_from_currency = v_to_currency then p_from_amount end
  );
  if v_to_amount is null or v_to_amount <= 0 then
    raise exception 'to_amount is required for cross-currency transfers and must be a positive magnitude';
  end if;

  insert into public.transactions (
    id, owner_id, created_by, account_id, amount, currency, occurred_at, transfer_group_id, source
  )
  values
    (
      gen_random_uuid(), v_from_owner, (select auth.uid()), p_from_account_id,
      -p_from_amount, v_from_currency, p_occurred_at, v_group, 'manual'
    ),
    (
      gen_random_uuid(), v_to_owner, (select auth.uid()), p_to_account_id,
      v_to_amount, v_to_currency, p_occurred_at, v_group, 'manual'
    );

  return query select * from public.transactions where transfer_group_id = v_group;
end;
$$;

grant execute on function create_transfer(uuid, uuid, numeric, numeric, timestamptz) to authenticated;

-- ============================================================================
-- handle_new_user() / ensure_user_bootstrap() — extended to seed the two
-- default "Other" categories (defect 3: app-architecture.md already said
-- they did this; they didn't). Backfilled for any existing profile missing
-- one, so this migration is correct regardless of what already has users —
-- a no-op today (no real signups exist yet: hosted has none, and local dev
-- data doesn't survive `supabase db reset`), but that's migration hygiene,
-- not a today-only fix.
-- ============================================================================

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;

  insert into public.categories (owner_id, kind, name, is_default)
  values (new.id, 'expense', 'Other', true), (new.id, 'income', 'Other', true)
  on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;

  return new;
end;
$$;

create or replace function ensure_user_bootstrap()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (auth.uid())
  on conflict (id) do nothing;

  insert into public.categories (owner_id, kind, name, is_default)
  values (auth.uid(), 'expense', 'Other', true), (auth.uid(), 'income', 'Other', true)
  on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;
end;
$$;

insert into categories (owner_id, kind, name, is_default)
select p.id, k.kind, 'Other', true
from profiles p
cross join (values ('expense'::category_kind), ('income'::category_kind)) as k (kind)
on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;
