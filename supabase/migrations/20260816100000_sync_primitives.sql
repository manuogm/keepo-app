-- L2: sync primitives on the server (keepo-local-first-plan.md).
--
-- Ticket-based delta cursor (not timestamps — LH1: now() is transaction-
-- *start* time, so a slow write can commit behind a client's cursor and be
-- lost silently and permanently). One counter per *sync domain* — the
-- household id if the user is in one, otherwise the user id — held via
-- `select ... for update` on the domain's row in sync_tickets, so the row
-- lock is held until commit and a lower ticket is guaranteed to have
-- committed first.
--
-- Every syncable table gets a sync_seq bigint stamped by a BEFORE INSERT OR
-- UPDATE trigger. pull_changes(p_cursor) is SECURITY INVOKER on purpose —
-- an RPC runs as the calling user, so RLS filters every table for free,
-- and a second copy of the *access* model (in an Edge Function, running as
-- service_role) would be a worse bug than a second copy of the money model.
--
-- The access problem: under local-first, RLS becomes a download-time
-- filter, not a live one (LH2) — anything already on a device stays until
-- something tells it to drop. Two directions:
--   - Gaining access (share_account, accept_invite): the rows already
--     exist with old tickets, so a normal pull would never fetch them
--     (LH3). The affected rows are re-stamped with fresh tickets instead.
--   - Losing access (unshare_account with a fork, leave_household,
--     erase_own_account, accept_invite's own domain change): the losing
--     user's sync_epoch bumps. Their client sees the epoch move, drops all
--     server-derived tables (keeping the outbox) and re-pulls from 0.

-- ============================================================
-- 0. household_members / household_accounts gain deleted_at first —
--    sync_domain_id/my_household_id/can_read_account below all filter on
--    it, so it has to exist before those functions are (re)defined.
-- ============================================================

alter table public.household_members add column deleted_at timestamptz;
alter table public.household_accounts add column deleted_at timestamptz;

-- ============================================================
-- 1. sync_tickets + next_ticket() + sync_domain_id()
-- ============================================================

create table public.sync_tickets (
  domain_id uuid primary key,
  next_ticket bigint not null default 1
);

alter table public.sync_tickets enable row level security;
-- No policies: sync_tickets is an internal counter, never read directly by
-- a client — only through next_ticket()/pull_changes(), same posture as
-- ops_events and fork_handled_tables' internal-only siblings.

-- Every user with no household is their own domain; every user in a
-- household shares its domain with the other member. Trigger functions in
-- this migration are SECURITY DEFINER (matching set_transaction_derived_
-- columns' existing precedent), so this needs no grant to `authenticated`.
create or replace function public.sync_domain_id(p_user_id uuid)
returns uuid
language sql
security definer
stable
set search_path = ''
as $$
  select coalesce(
    (select hm.household_id from public.household_members hm
     where hm.user_id = p_user_id and hm.deleted_at is null limit 1),
    p_user_id
  );
$$;

-- Reference/global rows (currencies, fx_rates) share this one fixed
-- domain — nobody "owns" an exchange rate, but every client still needs a
-- cursor-comparable ticket to know whether it has the latest rates.
create or replace function public.sync_global_domain()
returns uuid
language sql
immutable
set search_path = ''
as $$
  select '00000000-0000-0000-0000-000000000000'::uuid;
$$;

create or replace function public.next_ticket(p_domain_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket bigint;
begin
  insert into public.sync_tickets (domain_id) values (p_domain_id)
  on conflict (domain_id) do nothing;

  -- The row lock below is held until the enclosing transaction commits —
  -- this is the entire ordering guarantee: whichever write's UPDATE
  -- commits first is the one whose ticket is actually lower, full stop.
  select next_ticket into v_ticket from public.sync_tickets
  where domain_id = p_domain_id for update;

  update public.sync_tickets set next_ticket = v_ticket + 1 where domain_id = p_domain_id;
  return v_ticket;
end;
$$;

grant execute on function public.sync_domain_id(uuid) to postgres;
grant execute on function public.sync_global_domain() to postgres, authenticated, service_role;
grant execute on function public.next_ticket(uuid) to postgres;

-- ============================================================
-- 2. sync_seq column + backfill-safe trigger functions
-- ============================================================

alter table public.accounts add column sync_seq bigint not null default 0;
alter table public.transactions add column sync_seq bigint not null default 0;
alter table public.balance_snapshots add column sync_seq bigint not null default 0;
alter table public.categories add column sync_seq bigint not null default 0;
alter table public.currencies add column sync_seq bigint not null default 0;
alter table public.fx_rates add column sync_seq bigint not null default 0;
alter table public.budgets add column sync_seq bigint not null default 0;
alter table public.fi_settings add column sync_seq bigint not null default 0;
alter table public.recurring_rules add column sync_seq bigint not null default 0;
alter table public.card_mappings add column sync_seq bigint not null default 0;
alter table public.merchant_category_map add column sync_seq bigint not null default 0;
alter table public.sync_conflicts add column sync_seq bigint not null default 0;
alter table public.households add column sync_seq bigint not null default 0;
alter table public.household_members add column sync_seq bigint not null default 0;
alter table public.household_accounts add column sync_seq bigint not null default 0;
alter table public.profiles add column sync_seq bigint not null default 0;

create index accounts_sync_seq_idx on public.accounts (sync_seq);
create index transactions_sync_seq_idx on public.transactions (sync_seq);
create index balance_snapshots_sync_seq_idx on public.balance_snapshots (sync_seq);
create index categories_sync_seq_idx on public.categories (sync_seq);
create index currencies_sync_seq_idx on public.currencies (sync_seq);
create index fx_rates_sync_seq_idx on public.fx_rates (sync_seq);
create index budgets_sync_seq_idx on public.budgets (sync_seq);
create index fi_settings_sync_seq_idx on public.fi_settings (sync_seq);
create index recurring_rules_sync_seq_idx on public.recurring_rules (sync_seq);
create index card_mappings_sync_seq_idx on public.card_mappings (sync_seq);
create index merchant_category_map_sync_seq_idx on public.merchant_category_map (sync_seq);
create index sync_conflicts_sync_seq_idx on public.sync_conflicts (sync_seq);
create index households_sync_seq_idx on public.households (sync_seq);
create index household_members_sync_seq_idx on public.household_members (sync_seq);
create index household_accounts_sync_seq_idx on public.household_accounts (sync_seq);
create index profiles_sync_seq_idx on public.profiles (sync_seq);

-- Tombstones (LH10) — deleted_at where the table didn't already have it.
-- accounts/transactions/categories already carry it. currencies/fx_rates
-- are append-only reference data with no delete path at all, so they stay
-- without one — nothing would ever set it.
alter table public.balance_snapshots add column deleted_at timestamptz;
alter table public.budgets add column deleted_at timestamptz;
alter table public.fi_settings add column deleted_at timestamptz;
alter table public.card_mappings add column deleted_at timestamptz;
alter table public.merchant_category_map add column deleted_at timestamptz;
alter table public.sync_conflicts add column deleted_at timestamptz;
alter table public.households add column deleted_at timestamptz;
alter table public.profiles add column deleted_at timestamptz;

-- Tables keyed by owner_id: stamp using the ROW's owner domain, not the
-- caller's — a household member writing to a shared account they don't
-- own still lands in the account owner's domain, which is the same
-- household domain either way (both members resolve to one household id).
create or replace function public.stamp_sync_seq_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.sync_seq = public.next_ticket(public.sync_domain_id(new.owner_id));
  return new;
end;
$$;

-- balance_snapshots has no owner_id of its own — resolve via its account.
create or replace function public.stamp_sync_seq_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner from public.accounts where id = new.account_id;
  new.sync_seq = public.next_ticket(public.sync_domain_id(v_owner));
  return new;
end;
$$;

-- A user's own profile row lives in their own (or household) domain.
create or replace function public.stamp_sync_seq_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.sync_seq = public.next_ticket(public.sync_domain_id(new.id));
  return new;
end;
$$;

-- A household is its own domain (its id IS the domain id).
create or replace function public.stamp_sync_seq_household()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.sync_seq = public.next_ticket(new.id);
  return new;
end;
$$;

-- household_members / household_accounts carry household_id directly.
create or replace function public.stamp_sync_seq_household_ref()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.sync_seq = public.next_ticket(new.household_id);
  return new;
end;
$$;

create or replace function public.stamp_sync_seq_global()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.sync_seq = public.next_ticket(public.sync_global_domain());
  return new;
end;
$$;

create trigger accounts_stamp_sync_seq before insert or update on public.accounts
  for each row execute function public.stamp_sync_seq_owner();
create trigger transactions_stamp_sync_seq before insert or update on public.transactions
  for each row execute function public.stamp_sync_seq_owner();
create trigger categories_stamp_sync_seq before insert or update on public.categories
  for each row execute function public.stamp_sync_seq_owner();
create trigger budgets_stamp_sync_seq before insert or update on public.budgets
  for each row execute function public.stamp_sync_seq_owner();
create trigger fi_settings_stamp_sync_seq before insert or update on public.fi_settings
  for each row execute function public.stamp_sync_seq_owner();
create trigger recurring_rules_stamp_sync_seq before insert or update on public.recurring_rules
  for each row execute function public.stamp_sync_seq_owner();
create trigger card_mappings_stamp_sync_seq before insert or update on public.card_mappings
  for each row execute function public.stamp_sync_seq_owner();
create trigger merchant_category_map_stamp_sync_seq before insert or update on public.merchant_category_map
  for each row execute function public.stamp_sync_seq_owner();
create trigger sync_conflicts_stamp_sync_seq before insert or update on public.sync_conflicts
  for each row execute function public.stamp_sync_seq_owner();

create trigger balance_snapshots_stamp_sync_seq before insert or update on public.balance_snapshots
  for each row execute function public.stamp_sync_seq_account();

create trigger profiles_stamp_sync_seq before insert or update on public.profiles
  for each row execute function public.stamp_sync_seq_profile();

create trigger households_stamp_sync_seq before insert or update on public.households
  for each row execute function public.stamp_sync_seq_household();

create trigger household_members_stamp_sync_seq before insert or update on public.household_members
  for each row execute function public.stamp_sync_seq_household_ref();
create trigger household_accounts_stamp_sync_seq before insert or update on public.household_accounts
  for each row execute function public.stamp_sync_seq_household_ref();

create trigger currencies_stamp_sync_seq before insert or update on public.currencies
  for each row execute function public.stamp_sync_seq_global();
create trigger fx_rates_stamp_sync_seq before insert or update on public.fx_rates
  for each row execute function public.stamp_sync_seq_global();

-- ============================================================
-- 3. Backfill existing rows
--
-- Tickets are one counter PER DOMAIN SHARED ACROSS EVERY TABLE, so a
-- per-table backfill (each restarting at 1) would corrupt the single-
-- integer-cursor guarantee immediately. Rank every existing row across
-- every syncable table together, then scatter the ranks back per table
-- with all other triggers (bump_version, set_updated_at — this must not
-- perturb version/updated_at for rows nobody actually touched) disabled
-- for the duration.
-- ============================================================

create temporary table backfill_sync_seq on commit drop as
with unified as (
  select 'accounts' as table_name, a.id::text as row_key,
         public.sync_domain_id(a.owner_id) as domain_id, a.created_at as ts
  from public.accounts a
  union all
  select 'transactions', t.id::text, public.sync_domain_id(t.owner_id), t.created_at
  from public.transactions t
  union all
  select 'balance_snapshots', bs.id::text, public.sync_domain_id(acc.owner_id), bs.created_at
  from public.balance_snapshots bs join public.accounts acc on acc.id = bs.account_id
  union all
  select 'categories', c.id::text, public.sync_domain_id(c.owner_id), c.created_at
  from public.categories c
  union all
  select 'currencies', cur.code, public.sync_global_domain(), now()
  from public.currencies cur
  union all
  select 'fx_rates', fr.currency || '|' || fr.rate_date::text, public.sync_global_domain(), fr.fetched_at
  from public.fx_rates fr
  union all
  select 'budgets', b.id::text, public.sync_domain_id(b.owner_id), b.created_at
  from public.budgets b
  union all
  select 'fi_settings', fs.owner_id::text, public.sync_domain_id(fs.owner_id), fs.updated_at
  from public.fi_settings fs
  union all
  select 'recurring_rules', rr.id::text, public.sync_domain_id(rr.owner_id), rr.created_at
  from public.recurring_rules rr
  union all
  select 'card_mappings', cm.id::text, public.sync_domain_id(cm.owner_id), cm.created_at
  from public.card_mappings cm
  union all
  select 'merchant_category_map', mcm.owner_id::text || '|' || mcm.merchant_pattern,
         public.sync_domain_id(mcm.owner_id), mcm.updated_at
  from public.merchant_category_map mcm
  union all
  select 'sync_conflicts', sc.id::text, public.sync_domain_id(sc.owner_id), sc.created_at
  from public.sync_conflicts sc
  union all
  select 'households', h.id::text, h.id, h.created_at
  from public.households h
  union all
  select 'household_members', hm.household_id::text || '|' || hm.user_id::text, hm.household_id, hm.joined_at
  from public.household_members hm
  union all
  select 'household_accounts', ha.household_id::text || '|' || ha.account_id::text, ha.household_id, ha.shared_at
  from public.household_accounts ha
  union all
  select 'profiles', p.id::text, public.sync_domain_id(p.id), p.created_at
  from public.profiles p
)
select table_name, row_key, domain_id,
       row_number() over (partition by domain_id order by ts, table_name, row_key) as seq
from unified;

alter table public.accounts disable trigger user;
update public.accounts a set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'accounts' and b.row_key = a.id::text;
alter table public.accounts enable trigger user;

alter table public.transactions disable trigger user;
update public.transactions t set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'transactions' and b.row_key = t.id::text;
alter table public.transactions enable trigger user;

alter table public.balance_snapshots disable trigger user;
update public.balance_snapshots bs set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'balance_snapshots' and b.row_key = bs.id::text;
alter table public.balance_snapshots enable trigger user;

alter table public.categories disable trigger user;
update public.categories c set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'categories' and b.row_key = c.id::text;
alter table public.categories enable trigger user;

alter table public.currencies disable trigger user;
update public.currencies cur set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'currencies' and b.row_key = cur.code;
alter table public.currencies enable trigger user;

alter table public.fx_rates disable trigger user;
update public.fx_rates fr set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'fx_rates' and b.row_key = fr.currency || '|' || fr.rate_date::text;
alter table public.fx_rates enable trigger user;

alter table public.budgets disable trigger user;
update public.budgets bud set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'budgets' and b.row_key = bud.id::text;
alter table public.budgets enable trigger user;

alter table public.fi_settings disable trigger user;
update public.fi_settings fs set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'fi_settings' and b.row_key = fs.owner_id::text;
alter table public.fi_settings enable trigger user;

alter table public.recurring_rules disable trigger user;
update public.recurring_rules rr set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'recurring_rules' and b.row_key = rr.id::text;
alter table public.recurring_rules enable trigger user;

alter table public.card_mappings disable trigger user;
update public.card_mappings cm set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'card_mappings' and b.row_key = cm.id::text;
alter table public.card_mappings enable trigger user;

alter table public.merchant_category_map disable trigger user;
update public.merchant_category_map mcm set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'merchant_category_map' and b.row_key = mcm.owner_id::text || '|' || mcm.merchant_pattern;
alter table public.merchant_category_map enable trigger user;

alter table public.sync_conflicts disable trigger user;
update public.sync_conflicts sc set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'sync_conflicts' and b.row_key = sc.id::text;
alter table public.sync_conflicts enable trigger user;

alter table public.households disable trigger user;
update public.households h set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'households' and b.row_key = h.id::text;
alter table public.households enable trigger user;

alter table public.household_members disable trigger user;
update public.household_members hm set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'household_members' and b.row_key = hm.household_id::text || '|' || hm.user_id::text;
alter table public.household_members enable trigger user;

alter table public.household_accounts disable trigger user;
update public.household_accounts ha set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'household_accounts' and b.row_key = ha.household_id::text || '|' || ha.account_id::text;
alter table public.household_accounts enable trigger user;

alter table public.profiles disable trigger user;
update public.profiles p set sync_seq = b.seq from backfill_sync_seq b
where b.table_name = 'profiles' and b.row_key = p.id::text;
alter table public.profiles enable trigger user;

insert into public.sync_tickets (domain_id, next_ticket)
select domain_id, max(seq) + 1 from backfill_sync_seq group by domain_id
on conflict (domain_id) do update set next_ticket = excluded.next_ticket;

-- ============================================================
-- 4. sync_epoch on profiles (LH2)
-- ============================================================

alter table public.profiles add column sync_epoch bigint not null default 1;

-- ============================================================
-- 5. Household soft-delete: my_household_id / can_read_account / RLS /
--    enforce_household_member_cap all need to stop counting a departed
--    member's tombstoned rows as live membership.
-- ============================================================

create or replace function public.my_household_id()
returns uuid
language sql
security definer
stable
set search_path = ''
as $$
  select household_id from public.household_members
  where user_id = (select auth.uid()) and deleted_at is null limit 1;
$$;

create or replace function public.can_read_account(p_account_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.accounts
    where id = p_account_id and owner_id = (select auth.uid())
  )
  or exists (
    select 1
    from public.household_accounts ha
    join public.household_members hm on hm.household_id = ha.household_id
    where ha.account_id = p_account_id and hm.user_id = (select auth.uid())
      and ha.deleted_at is null and hm.deleted_at is null
  );
$$;

drop policy accounts_select on public.accounts;
create policy accounts_select on public.accounts for select to authenticated
using (
  owner_id = (select auth.uid())
  or exists (
    select 1 from public.household_accounts ha
    join public.household_members hm on hm.household_id = ha.household_id
    where ha.account_id = accounts.id and hm.user_id = (select auth.uid())
      and ha.deleted_at is null and hm.deleted_at is null
  )
);

drop policy accounts_update on public.accounts;
create policy accounts_update on public.accounts for update to authenticated
using (
  owner_id = (select auth.uid())
  or exists (
    select 1 from public.household_accounts ha
    join public.household_members hm on hm.household_id = ha.household_id
    where ha.account_id = accounts.id and hm.user_id = (select auth.uid())
      and ha.deleted_at is null and hm.deleted_at is null
  )
)
with check (
  owner_id = (select auth.uid())
  or exists (
    select 1 from public.household_accounts ha
    join public.household_members hm on hm.household_id = ha.household_id
    where ha.account_id = accounts.id and hm.user_id = (select auth.uid())
      and ha.deleted_at is null and hm.deleted_at is null
  )
);

create or replace function public.enforce_household_member_cap()
returns trigger
language plpgsql
as $$
begin
  if (
    select count(*) from public.household_members
    where household_id = new.household_id and deleted_at is null
  ) >= 2 then
    raise exception 'a household cannot have more than 2 members';
  end if;
  return new;
end;
$$;

-- ============================================================
-- 6. fork_one_account — extracted from fork_household_accounts' loop body
--    so unshare_account (single account) and fork_household_accounts (all
--    of a household's accounts) share one implementation.
-- ============================================================

create or replace function public.fork_one_account(p_old_account_id uuid, p_member_a uuid, p_member_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new_for_a uuid;
  v_new_for_b uuid;
begin
  insert into public.accounts (
    owner_id, created_by, kind, subtype, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, counts_toward_fi
  )
  select p_member_a, p_member_a, kind, subtype, name, currency,
         opening_balance_e4, opening_balance_at, include_in_total, counts_toward_fi
  from public.accounts where id = p_old_account_id
  returning id into v_new_for_a;

  insert into public.accounts (
    owner_id, created_by, kind, subtype, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, counts_toward_fi
  )
  select p_member_b, p_member_b, kind, subtype, name, currency,
         opening_balance_e4, opening_balance_at, include_in_total, counts_toward_fi
  from public.accounts where id = p_old_account_id
  returning id into v_new_for_b;

  insert into public.transactions (
    owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, source, status
  )
  select
    fork.fork_owner, t.created_by, fork.fork_account_id,
    case
      when t.transfer_group_id is not null then (
        select id from public.categories
        where owner_id = fork.fork_owner
          and kind = case when t.amount_e4 < 0 then 'expense'::public.category_kind else 'income'::public.category_kind end
          and is_default and deleted_at is null
      )
      else public.fork_category_id(fork.fork_owner, t.category_id)
    end,
    t.amount_e4, t.currency, t.occurred_at, t.merchant_raw, t.merchant_normalized,
    case when t.transfer_group_id is not null then 'adjustment'::public.transaction_source else t.source end,
    t.status
  from public.transactions t
  cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
  where t.account_id = p_old_account_id and t.deleted_at is null;

  insert into public.balance_snapshots (account_id, currency, as_of, value_e4, created_by)
  select fork.fork_account_id, bs.currency, bs.as_of, bs.value_e4, bs.created_by
  from public.balance_snapshots bs
  cross join lateral (values (v_new_for_a), (v_new_for_b)) as fork (fork_account_id)
  where bs.account_id = p_old_account_id;

  insert into public.recurring_rules (created_by, account_id, category_id, amount_e4, currency, frequency, next_due_at, active)
  select rr.created_by, fork.fork_account_id, public.fork_category_id(fork.fork_owner, rr.category_id),
         rr.amount_e4, rr.currency, rr.frequency, rr.next_due_at, rr.active
  from public.recurring_rules rr
  cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
  where rr.account_id = p_old_account_id;

  update public.card_mappings
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  update public.csv_import_batches
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  update public.csv_import_candidates
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  delete from public.net_worth_daily where account_id = p_old_account_id;
  update public.household_accounts set deleted_at = now()
  where account_id = p_old_account_id and deleted_at is null;
  update public.accounts set archived_at = coalesce(archived_at, now()) where id = p_old_account_id;
end;
$$;

grant execute on function public.fork_one_account(uuid, uuid, uuid) to postgres;

create or replace function public.fork_household_accounts(p_household_id uuid, p_member_a uuid, p_member_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unregistered text;
  v_old_account_id uuid;
begin
  select string_agg(c.table_name, ', ') into v_unregistered
  from information_schema.columns c
  join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
  where c.table_schema = 'public' and c.column_name = 'account_id' and t.table_type = 'BASE TABLE'
    and not exists (select 1 from public.fork_handled_tables f where f.table_name = c.table_name);

  if v_unregistered is not null then
    raise exception 'fork_household_accounts: unregistered account_id-bearing table(s): %', v_unregistered;
  end if;

  for v_old_account_id in
    select account_id from public.household_accounts
    where household_id = p_household_id and deleted_at is null
  loop
    perform public.fork_one_account(v_old_account_id, p_member_a, p_member_b);
  end loop;
end;
$$;

-- ============================================================
-- 7. share_account / unshare_account: re-stamp on gain (LH3), fork +
--    epoch-bump the OTHER member on loss (LH4, LH12).
-- ============================================================

-- bump_version/set_updated_at gain a transaction-local escape hatch: a
-- restamp (below) needs to fire the ordinary sync_seq trigger without also
-- bumping version/updated_at — sharing an account shouldn't silently
-- invalidate the sharer's own cached expectedVersion on every transaction
-- underneath it. `set_config(..., true)` is transaction-scoped (resets
-- automatically at commit/rollback, including if restamp_account_for_sync
-- raises), so this can never leak into an unrelated statement.
create or replace function public.bump_version()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('keepo.restamp_only', true), 'false') = 'true' then
    new.version = old.version;
  else
    new.version = old.version + 1;
  end if;
  return new;
end;
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('keepo.restamp_only', true), 'false') = 'true' then
    new.updated_at = old.updated_at;
  else
    new.updated_at = now();
  end if;
  return new;
end;
$$;

-- Re-stamps an already-shared account and its existing transactions/
-- snapshots/recurring rules so a plain cursor-based pull actually delivers
-- rows that predate the share (LH3) — sharing doesn't change ownership, so
-- the ordinary per-row triggers already stamp in the correct (household)
-- domain; a harmless self-touch is enough to make them fire again and
-- issue fresh tickets. Deliberately NOT done via `alter table ... disable
-- trigger` + an explicit sync_seq write: that approach errors with
-- "cannot ALTER TABLE because it has pending trigger events" whenever the
-- account was created earlier in the same transaction (every pgTAP test
-- file is one transaction, and this is exactly the sequence share_account
-- tests use) because of the DEFERRABLE FK triggers on accounts/
-- transactions. A plain UPDATE has no such restriction, and the
-- keepo.restamp_only flag above keeps it from bumping version/updated_at.
create or replace function public.restamp_account_for_sync(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('keepo.restamp_only', 'true', true);
  update public.accounts set id = id where id = p_account_id;
  update public.transactions set id = id where account_id = p_account_id and deleted_at is null;
  update public.balance_snapshots set id = id where account_id = p_account_id;
  update public.recurring_rules set id = id where account_id = p_account_id;
  perform set_config('keepo.restamp_only', 'false', true);
end;
$$;

grant execute on function public.restamp_account_for_sync(uuid) to postgres;

create or replace function public.share_account(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_household_id uuid;
begin
  select owner_id into v_owner from public.accounts where id = p_account_id and deleted_at is null;
  if v_owner is null or v_owner <> (select auth.uid()) then
    raise exception 'account not found or not owned by you';
  end if;

  select household_id into v_household_id
  from public.household_members where user_id = (select auth.uid()) and deleted_at is null;
  if v_household_id is null then
    raise exception 'you do not belong to a household';
  end if;

  insert into public.household_accounts (household_id, account_id)
  values (v_household_id, p_account_id)
  on conflict (household_id, account_id) do update set deleted_at = null, shared_at = now();

  perform public.restamp_account_for_sync(p_account_id);
end;
$$;

create or replace function public.unshare_account(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_household_id uuid;
  v_other uuid;
begin
  select owner_id into v_owner from public.accounts where id = p_account_id and deleted_at is null;
  if v_owner is null or v_owner <> (select auth.uid()) then
    raise exception 'account not found or not owned by you';
  end if;

  select ha.household_id into v_household_id
  from public.household_accounts ha
  join public.household_members hm on hm.household_id = ha.household_id
  where ha.account_id = p_account_id and hm.user_id = (select auth.uid())
    and ha.deleted_at is null and hm.deleted_at is null
  limit 1;

  if v_household_id is null then
    return;
  end if;

  select user_id into v_other from public.household_members
  where household_id = v_household_id and user_id <> (select auth.uid()) and deleted_at is null;

  if v_other is not null then
    -- Fork first (LH4/LH12) so the other member keeps a full independent
    -- replica instead of simply losing the account — same posture as
    -- leave_household. Then bump only THEIR epoch: the sharer's own
    -- domain and cursor are unaffected, they never lost anything.
    perform public.fork_one_account(p_account_id, v_owner, v_other);
    update public.profiles set sync_epoch = sync_epoch + 1 where id = v_other;
  else
    update public.household_accounts set deleted_at = now()
    where account_id = p_account_id and household_id = v_household_id and deleted_at is null;
  end if;
end;
$$;

-- ============================================================
-- 8. accept_invite / leave_household / erase_own_account: soft-delete
--    household_members instead of a hard DELETE (a hard delete leaves the
--    remaining member's pull with no tombstone to learn the departure
--    from), and bump the acting user's own epoch — their domain changes
--    (solo <-> household), so their old cursor is meaningless afterward.
-- ============================================================

create or replace function public.accept_invite(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite record;
  v_event_id uuid;
begin
  if public.my_household_id() is not null then
    raise exception 'already a member of a household';
  end if;

  select * into v_invite from public.household_invites
  where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status = 'pending'
    and expires_at > now();

  if v_invite.id is null then
    raise exception 'invite not found, already used, or expired';
  end if;

  if v_invite.invited_by = (select auth.uid()) then
    raise exception 'cannot accept your own invite';
  end if;

  -- A user who previously left this exact household has a tombstoned
  -- (deleted_at not null) row still occupying the PK — reactivate it
  -- instead of a plain insert, or a rejoin collides on household_members_pkey.
  insert into public.household_members (household_id, user_id)
  values (v_invite.household_id, (select auth.uid()))
  on conflict (household_id, user_id) do update set deleted_at = null, joined_at = now();

  update public.household_invites set status = 'accepted' where id = v_invite.id;

  perform public.merge_household_categories(v_invite.invited_by, (select auth.uid()));

  update public.profiles set sync_epoch = sync_epoch + 1 where id = (select auth.uid());

  insert into public.household_events (household_id, actor_id, kind)
  values (v_invite.household_id, (select auth.uid()), 'member_joined')
  returning id into v_event_id;

  perform public.notify_household(v_event_id);

  return v_invite.household_id;
end;
$$;

create or replace function public.leave_household()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_other uuid;
  v_event_id uuid;
begin
  if v_household_id is null then
    raise exception 'not a member of a household';
  end if;

  select user_id into v_other from public.household_members
  where household_id = v_household_id and user_id <> v_me and deleted_at is null;

  if v_other is not null then
    perform public.fork_household_accounts(v_household_id, v_me, v_other);
  end if;

  update public.household_members set deleted_at = now()
  where household_id = v_household_id and user_id = v_me and deleted_at is null;

  update public.profiles set sync_epoch = sync_epoch + 1 where id = v_me;

  insert into public.household_events (household_id, actor_id, kind)
  values (v_household_id, v_me, 'member_left')
  returning id into v_event_id;

  perform public.notify_household(v_event_id);
end;
$$;

create or replace function public.erase_own_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_other uuid;
  v_event_id uuid;
begin
  if v_household_id is not null then
    select user_id into v_other from public.household_members
    where household_id = v_household_id and user_id <> v_me and deleted_at is null;

    if v_other is not null then
      perform public.fork_household_accounts(v_household_id, v_me, v_other);
    end if;

    update public.household_members set deleted_at = now()
    where household_id = v_household_id and user_id = v_me and deleted_at is null;

    update public.profiles set sync_epoch = sync_epoch + 1 where id = v_me;

    insert into public.household_events (household_id, actor_id, kind)
    values (v_household_id, v_me, 'member_erased')
    returning id into v_event_id;

    perform public.notify_household(v_event_id);
  end if;

  update public.transactions set merchant_raw = null, merchant_normalized = null
  where owner_id = v_me and (merchant_raw is not null or merchant_normalized is not null);

  update public.card_mappings set card_identifier = 'erased'
  where owner_id = v_me;

  update public.csv_import_batches set filename = 'erased'
  where owner_id = v_me;

  update public.csv_import_candidates set raw_row = '{}'::jsonb, merchant_raw = null, merchant_normalized = null
  where owner_id = v_me;
end;
$$;

-- ============================================================
-- 9. pull_changes — SECURITY INVOKER so RLS filters every table for free.
--
-- Two SEPARATE cursors, not one: currencies/fx_rates share ONE global
-- domain's ticket counter (every user reads them, so "who owns this
-- ticket" is meaningless for them), while every other table's ticket
-- comes from the caller's OWN domain (household or solo). Those two
-- counters are independent sequences that both start at 1 — the global
-- one accumulates across every user and grows far faster. A single
-- scalar cursor taking the max across both would be dominated by the
-- global counter, so a freshly re-stamped row in a quiet household domain
-- (LH3's whole point) could sit at ticket #6 while the client's cursor
-- was already past #500 from currencies/fx_rates alone — sync_seq > cursor
-- would be false forever, and the row would never actually deliver. Two
-- cursors, each only ever compared against its own counter, is the fix.
-- ============================================================

create or replace function public.pull_changes(p_cursor bigint default 0, p_global_cursor bigint default 0)
returns table (payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
language plpgsql
security invoker
stable
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());

  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.sync_seq > p_cursor), '[]'::jsonb),
    'transactions', coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where t.sync_seq > p_cursor), '[]'::jsonb),
    'balance_snapshots', coalesce((select jsonb_agg(to_jsonb(bs)) from public.balance_snapshots bs where bs.sync_seq > p_cursor), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(to_jsonb(c)) from public.categories c where c.sync_seq > p_cursor), '[]'::jsonb),
    'currencies', coalesce((select jsonb_agg(to_jsonb(cur)) from public.currencies cur where cur.sync_seq > p_global_cursor), '[]'::jsonb),
    'fx_rates', coalesce((select jsonb_agg(to_jsonb(fr)) from public.fx_rates fr where fr.sync_seq > p_global_cursor), '[]'::jsonb),
    'budgets', coalesce((select jsonb_agg(to_jsonb(bud)) from public.budgets bud where bud.sync_seq > p_cursor), '[]'::jsonb),
    'fi_settings', coalesce((select jsonb_agg(to_jsonb(fs)) from public.fi_settings fs where fs.sync_seq > p_cursor), '[]'::jsonb),
    'recurring_rules', coalesce((select jsonb_agg(to_jsonb(rr)) from public.recurring_rules rr where rr.sync_seq > p_cursor), '[]'::jsonb),
    'card_mappings', coalesce((select jsonb_agg(to_jsonb(cm)) from public.card_mappings cm where cm.sync_seq > p_cursor), '[]'::jsonb),
    'merchant_category_map', coalesce((select jsonb_agg(to_jsonb(mcm)) from public.merchant_category_map mcm where mcm.sync_seq > p_cursor), '[]'::jsonb),
    'sync_conflicts', coalesce((select jsonb_agg(to_jsonb(sc)) from public.sync_conflicts sc where sc.sync_seq > p_cursor), '[]'::jsonb),
    'households', coalesce((select jsonb_agg(to_jsonb(h)) from public.households h where h.sync_seq > p_cursor), '[]'::jsonb),
    'household_members', coalesce((select jsonb_agg(to_jsonb(hm)) from public.household_members hm where hm.sync_seq > p_cursor), '[]'::jsonb),
    'household_accounts', coalesce((select jsonb_agg(to_jsonb(ha)) from public.household_accounts ha where ha.sync_seq > p_cursor), '[]'::jsonb),
    'profiles', coalesce((select jsonb_agg(to_jsonb(p)) from public.profiles p where p.sync_seq > p_cursor), '[]'::jsonb)
  ) into v_payload;

  select coalesce(max(m), p_cursor) into v_next_cursor from (
    select max(sync_seq) as m from public.accounts where sync_seq > p_cursor
    union all select max(sync_seq) from public.transactions where sync_seq > p_cursor
    union all select max(sync_seq) from public.balance_snapshots where sync_seq > p_cursor
    union all select max(sync_seq) from public.categories where sync_seq > p_cursor
    union all select max(sync_seq) from public.budgets where sync_seq > p_cursor
    union all select max(sync_seq) from public.fi_settings where sync_seq > p_cursor
    union all select max(sync_seq) from public.recurring_rules where sync_seq > p_cursor
    union all select max(sync_seq) from public.card_mappings where sync_seq > p_cursor
    union all select max(sync_seq) from public.merchant_category_map where sync_seq > p_cursor
    union all select max(sync_seq) from public.sync_conflicts where sync_seq > p_cursor
    union all select max(sync_seq) from public.households where sync_seq > p_cursor
    union all select max(sync_seq) from public.household_members where sync_seq > p_cursor
    union all select max(sync_seq) from public.household_accounts where sync_seq > p_cursor
    union all select max(sync_seq) from public.profiles where sync_seq > p_cursor
  ) s;

  select coalesce(max(m), p_global_cursor) into v_next_global_cursor from (
    select max(sync_seq) as m from public.currencies where sync_seq > p_global_cursor
    union all select max(sync_seq) from public.fx_rates where sync_seq > p_global_cursor
  ) g;

  return query select v_payload, v_next_cursor, v_next_global_cursor, v_epoch;
end;
$$;

grant execute on function public.pull_changes(bigint, bigint) to authenticated;

-- ============================================================
-- 10. create_household's own-membership guard used a raw EXISTS against
--     household_members with no deleted_at filter, so a former member (a
--     tombstoned row from a past leave/erase) was permanently blocked from
--     ever creating a fresh household. Route it through my_household_id()
--     like every other membership check in this migration.
-- ============================================================

create or replace function public.create_household()
returns public.households
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_result public.households;
begin
  if public.my_household_id() is not null then
    raise exception 'you already belong to a household';
  end if;

  insert into public.households (id) values (v_id) returning * into v_result;
  insert into public.household_members (household_id, user_id) values (v_id, (select auth.uid()));

  return v_result;
end;
$$;
