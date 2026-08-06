-- Phase 7: households — access model & viewer-scoped money. Landed early
-- (before Home/Insights/Budgets exist) rather than as one late monolith,
-- because two hazards found while planning this phase would otherwise have
-- to be retrofitted across every screen built between now and whenever
-- households eventually shipped:
--
--   H1/H9: account_balances_base and transactions_with_details both joined
--   `profiles` on the ROW's owner_id, not the VIEWER's. Both views are
--   security_invoker, and profiles_select is `id = auth.uid()` — so the
--   moment a shared account is owned by the OTHER household member, that
--   inner join finds no visible profiles row and the row is silently
--   DROPPED from both views. Not a wrong conversion rate — a missing
--   account, no error. Fixed below by joining on the viewer's own id.
--
--   H10: transactions' composite FK (account_id, owner_id) references
--   accounts (id, owner_id) forces a transaction's owner_id to equal its
--   account's owner — by design, unchanged here. But check_transfer_
--   integrity()'s "exactly one owner per transfer" rule was written before
--   that FK's implication was fully felt: a transfer from a private account
--   into a partner-owned shared account produces two legs with two
--   genuinely different owners. Relaxed below to "one owner, or both legs'
--   accounts share a household."
--
-- Landing here also makes net_worth(scope) computable for the first time
-- (H5) and forces the two remaining documented exceptions — accounts'
-- own SELECT/UPDATE policies (H3, the Phase 2 SECURITY DEFINER/RETURNING
-- finding) and six hardcoded owner_id-equality checks across the write RPCs
-- (H2) — to be edited now, while there are five call sites, not fifteen.
--
-- Deliberately NOT built here: invites, accept, leave/fork, category merge,
-- APNs (Phase 19). `household_invites` exists as a table only, same
-- precedent as `sync_conflicts` landing in Phase 3 before anything read it.
-- The running app is single-member-household until Phase 19's accept_invite
-- admits a second member; two-member behaviour here is verified exclusively
-- by pgTAP with two fixture users, which is more thorough than manual
-- two-simulator testing would be and is fully re-runnable.

-- ============================================================================
-- Enums. `household_invite_status` is pulled forward from its originally
-- planned Phase 19 slot — the household_invites table below needs a typed
-- status column to exist at all (money rule 4: enums, not text + CHECK),
-- and a table can't be created with a column typed against an enum that
-- doesn't exist yet. Phase 19 consumes this enum; it doesn't (re)create it.
-- ============================================================================

create type account_scope as enum ('me', 'household', 'total');
create type household_invite_status as enum ('pending', 'accepted', 'revoked', 'expired');

-- ============================================================================
-- households / household_members. No INSERT/UPDATE/DELETE grant to
-- authenticated on either table — every write goes through create_household()
-- below (and, in Phase 19, accept_invite/leave_household), all SECURITY
-- DEFINER, same "write only through a vetted function" precedent as
-- sync_conflicts and fx_rates.
-- ============================================================================

create table households (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now()
);

alter table households enable row level security;

create table household_members (
  household_id uuid not null references households (id) deferrable initially deferred,
  user_id uuid not null references auth.users (id) deferrable initially deferred,
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id)
);

create index household_members_user_id_idx on household_members (user_id);

alter table household_members enable row level security;

-- SECURITY DEFINER so household_members' own RLS policy (below) can call
-- this without recursing through itself — identical reasoning to
-- can_read_account in migration 001: under INVOKER, the inner query would
-- itself be subject to household_members_select, which calls
-- my_household_id() again, forever.
create function my_household_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select household_id from public.household_members where user_id = (select auth.uid()) limit 1;
$$;

revoke all on function my_household_id() from public;
grant execute on function my_household_id() to authenticated;

create policy households_select on households
  for select to authenticated
  using (id = my_household_id());

create policy household_members_select on household_members
  for select to authenticated
  using (household_id = my_household_id());

grant select on households to authenticated, service_role;
grant select on household_members to authenticated, service_role;

-- Caps membership at 2 (spec). SECURITY DEFINER for the same reason as
-- set_transaction_derived_columns: the inner count query must not be
-- subject to household_members' own RLS policy.
create function enforce_household_member_cap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.household_members where household_id = new.household_id) >= 2 then
    raise exception 'a household cannot have more than 2 members';
  end if;
  return new;
end;
$$;

create trigger household_members_cap
  before insert on household_members
  for each row execute function enforce_household_member_cap();

-- ============================================================================
-- household_accounts — the join table share_account()/unshare_account()
-- write to. No second owner_id on accounts anywhere (app-architecture.md
-- §3): shared visibility routes exclusively through this table plus
-- household_members, never a column on accounts itself.
-- ============================================================================

create table household_accounts (
  household_id uuid not null references households (id) deferrable initially deferred,
  account_id uuid not null references accounts (id) deferrable initially deferred,
  shared_at timestamptz not null default now(),
  primary key (household_id, account_id)
);

create index household_accounts_account_id_idx on household_accounts (account_id);

alter table household_accounts enable row level security;

create policy household_accounts_select on household_accounts
  for select to authenticated
  using (household_id = my_household_id());

grant select on household_accounts to authenticated, service_role;

-- ============================================================================
-- household_invites — table only, per this migration's header. No RPC
-- writes to it yet; Phase 19 adds create_invite/accept_invite.
-- ============================================================================

create table household_invites (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households (id) deferrable initially deferred,
  invited_by uuid not null references auth.users (id) deferrable initially deferred,
  token_hash text not null unique,
  status household_invite_status not null default 'pending',
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

alter table household_invites enable row level security;

create policy household_invites_select on household_invites
  for select to authenticated
  using (household_id = my_household_id());

grant select on household_invites to authenticated, service_role;

-- ============================================================================
-- can_read_account: gains the household clause. can_write_account is
-- unchanged — it already just delegates to can_read_account ("household
-- members get equal read/write on shared accounts", migration 001's own
-- comment), so this one edit is the whole upgrade for every policy that
-- calls either predicate (balance_snapshots' two policies, transactions'
-- select/insert, transactions_update — dormant since Phase 3's grant
-- revocation, kept in sync regardless).
-- ============================================================================

create or replace function can_read_account(p_account_id uuid)
returns boolean
language sql
stable
security definer
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
  );
$$;

-- ============================================================================
-- accounts' own SELECT/UPDATE policies — the documented exception (migration
-- 002's comment on why these two inline owner_id instead of calling
-- can_read_account/can_write_account: a SECURITY DEFINER self-reference
-- breaks INSERT ... RETURNING for a row written earlier in the same
-- command). Edited directly here, exactly as that comment predicted Phase 7
-- would need to. accounts_update is dormant (raw UPDATE grant revoked in
-- Phase 6) but kept in sync regardless, same reasoning as
-- transactions_update.
-- ============================================================================

drop policy accounts_select on accounts;
create policy accounts_select on accounts
  for select to authenticated
  using (
    owner_id = (select auth.uid())
    or exists (
      select 1
      from household_accounts ha
      join household_members hm on hm.household_id = ha.household_id
      where ha.account_id = accounts.id and hm.user_id = (select auth.uid())
    )
  );

drop policy accounts_update on accounts;
create policy accounts_update on accounts
  for update to authenticated
  using (
    owner_id = (select auth.uid())
    or exists (
      select 1
      from household_accounts ha
      join household_members hm on hm.household_id = ha.household_id
      where ha.account_id = accounts.id and hm.user_id = (select auth.uid())
    )
  )
  with check (
    owner_id = (select auth.uid())
    or exists (
      select 1
      from household_accounts ha
      join household_members hm on hm.household_id = ha.household_id
      where ha.account_id = accounts.id and hm.user_id = (select auth.uid())
    )
  );

-- ============================================================================
-- check_transfer_integrity: relax "exactly one owner" to "one owner, or both
-- legs' accounts share a household" (H10). Everything else about the
-- function — the 0-or-2-legs rule, distinct-accounts rule, same-currency
-- nets-to-zero rule — is unchanged.
-- ============================================================================

create or replace function check_transfer_integrity()
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
  v_account_ids uuid[];
begin
  v_group := coalesce(new.transfer_group_id, old.transfer_group_id);
  if v_group is null then
    return null;
  end if;

  select
    count(*), count(distinct account_id), count(distinct owner_id), count(distinct currency), sum(amount),
    array_agg(distinct account_id)
  into v_leg_count, v_distinct_accounts, v_distinct_owners, v_distinct_currencies, v_sum, v_account_ids
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
      if not exists (
        select 1
        from public.household_accounts ha1
        join public.household_accounts ha2 on ha1.household_id = ha2.household_id
        where ha1.account_id = v_account_ids[1] and ha2.account_id = v_account_ids[2]
      ) then
        raise exception 'transfer % legs must share one owner or one household', v_group;
      end if;
    end if;

    if v_distinct_currencies = 1 and v_sum <> 0 then
      raise exception 'transfer % same-currency legs must net to zero', v_group;
    end if;
  end if;

  return null;
end;
$$;

-- ============================================================================
-- The six hardcoded owner_id-equality checks (H2) — all six re-pointed at
-- can_write_account, which already understands households after the edit
-- above. create_transfer needed NO change: it never hardcoded an ownership
-- check at all — it relies entirely on accounts_select's own RLS visibility
-- ("a NULL result means not found or not accessible", migration 002's own
-- comment) to gate which accounts a caller can read owner_id/currency from,
-- and on transactions_insert's WITH CHECK (can_write_account) to gate the
-- actual write. Both already upgrade for free once the predicate functions
-- and accounts_select do. Confirmed by inspection and by this migration's
-- own pgTAP suite (07_households.sql) exercising a cross-owner transfer.
-- ============================================================================

create or replace function update_transaction(
  p_id uuid,
  p_expected_version integer,
  p_account_id uuid,
  p_category_id uuid,
  p_amount numeric,
  p_currency text,
  p_occurred_at timestamptz,
  p_merchant_raw text default null
)
returns table (conflict boolean, transaction public.transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.transactions;
begin
  select id, version, account_id, transfer_group_id, deleted_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(v_current.account_id) then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  if not public.can_write_account(p_account_id)
     or exists (select 1 from public.accounts where id = p_account_id and deleted_at is not null) then
    raise exception 'account not found or not accessible';
  end if;

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount = p_amount,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.transactions;
    return;
  end if;

  return query select false, v_result;
end;
$$;

create or replace function update_transfer(
  p_transfer_group_id uuid,
  p_from_expected_version integer,
  p_to_expected_version integer,
  p_from_amount numeric,
  p_to_amount numeric,
  p_occurred_at timestamptz
)
returns table (conflict boolean, transaction public.transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_from record;
  v_to record;
  v_conflict boolean := false;
begin
  if p_from_amount is null or p_from_amount <= 0 or p_to_amount is null or p_to_amount <= 0 then
    raise exception 'from_amount and to_amount must be positive magnitudes';
  end if;

  select id, version, account_id into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount < 0;

  select id, version, account_id into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount > 0;

  if v_from.id is null or v_to.id is null
     or not public.can_write_account(v_from.account_id)
     or not public.can_write_account(v_to.account_id) then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  if v_from.version <> p_from_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_from.id, v_owner, p_from_expected_version, v_from.version);
    v_conflict := true;
  end if;

  if v_to.version <> p_to_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_to.id, v_owner, p_to_expected_version, v_to.version);
    v_conflict := true;
  end if;

  if v_conflict then
    return query select true, null::public.transactions;
    return;
  end if;

  update public.transactions set amount = -p_from_amount, occurred_at = p_occurred_at
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set amount = p_to_amount, occurred_at = p_occurred_at
  where id = v_to.id and version = p_to_expected_version;

  return query select false, t from public.transactions t where t.transfer_group_id = p_transfer_group_id;
end;
$$;

create or replace function delete_transaction(p_id uuid, p_expected_version integer)
returns table (conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_updated integer;
begin
  select id, version, account_id, transfer_group_id, deleted_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(v_current.account_id) then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use delete_transfer', p_id;
  end if;

  update public.transactions
  set deleted_at = now()
  where id = p_id and version = p_expected_version;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);

    return query select true;
    return;
  end if;

  return query select false;
end;
$$;

create or replace function delete_transfer(
  p_transfer_group_id uuid,
  p_from_expected_version integer,
  p_to_expected_version integer
)
returns table (conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_from record;
  v_to record;
  v_conflict boolean := false;
begin
  select id, version, account_id into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount < 0;

  select id, version, account_id into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount > 0;

  if v_from.id is null or v_to.id is null
     or not public.can_write_account(v_from.account_id)
     or not public.can_write_account(v_to.account_id) then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  if v_from.version <> p_from_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_from.id, v_owner, p_from_expected_version, v_from.version);
    v_conflict := true;
  end if;

  if v_to.version <> p_to_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_to.id, v_owner, p_to_expected_version, v_to.version);
    v_conflict := true;
  end if;

  if v_conflict then
    return query select true;
    return;
  end if;

  update public.transactions set deleted_at = now()
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set deleted_at = now()
  where id = v_to.id and version = p_to_expected_version;

  return query select false;
end;
$$;

-- ============================================================================
-- Phase 6's three account-lifecycle RPCs weren't on the original H2 list
-- (they didn't exist yet when H2 was catalogued) but hardcode the identical
-- owner_id-equality pattern and need the identical fix.
-- ============================================================================

create or replace function update_account(
  p_id uuid,
  p_expected_version integer,
  p_name text,
  p_subtype account_subtype,
  p_opening_balance numeric,
  p_include_in_total boolean,
  p_counts_toward_fi boolean
)
returns table (conflict boolean, account public.accounts)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.accounts;
begin
  select id, version, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set
    name = p_name,
    subtype = p_subtype,
    opening_balance = p_opening_balance,
    include_in_total = p_include_in_total,
    counts_toward_fi = p_counts_toward_fi
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.accounts;
    return;
  end if;

  return query select false, v_result;
end;
$$;

create or replace function archive_account(p_id uuid, p_expected_version integer, p_archived boolean)
returns table (conflict boolean, account public.accounts)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.accounts;
begin
  select id, version, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set archived_at = case when p_archived then now() else null end
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.accounts;
    return;
  end if;

  return query select false, v_result;
end;
$$;

create or replace function delete_account(p_id uuid, p_expected_version integer)
returns table (conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_updated integer;
begin
  select id, version, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  if exists (select 1 from public.transactions where account_id = p_id and deleted_at is null) then
    raise exception 'account % has existing transactions — archive it instead of deleting', p_id;
  end if;

  update public.accounts
  set deleted_at = now()
  where id = p_id and version = p_expected_version;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true;
    return;
  end if;

  return query select false;
end;
$$;

-- ============================================================================
-- account_balances_base / transactions_with_details: the profiles join
-- rewritten to the VIEWER's own row (H1/H9), left join so a pre-onboarding
-- null base_currency still can't drop a row (Phase 4 already tested this
-- for the owner-scoped join; the same guarantee must hold for the
-- viewer-scoped one). Every other column is unchanged.
-- ============================================================================

create or replace view account_balances_base
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
left join profiles p on p.id = (select auth.uid());

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
left join profiles p on p.id = (select auth.uid())
left join currencies bc on bc.code = p.base_currency
where t.deleted_at is null;

-- accounts_with_balances: append is_shared (Phase 3's append-only column
-- ordering rule) — the client's shared/private indicator reads this instead
-- of a second round trip against household_accounts per screen.
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
  abb.has_missing_rate,
  a.version,
  exists (select 1 from household_accounts ha where ha.account_id = a.id) as is_shared
from accounts a
join account_balances ab on ab.account_id = a.id
join currencies c on c.code = a.currency
join account_balances_base abb on abb.account_id = a.id
left join currencies bc on bc.code = abb.base_currency;

-- ============================================================================
-- create_household / share_account / unshare_account. unshare_account is
-- NOT a fork — it deletes one household_accounts row; ownership never
-- moved, so there is nothing to copy. Fork is Phase 19's problem, once every
-- account-scoped table it has to copy actually exists.
-- ============================================================================

create function create_household()
returns public.households
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_result public.households;
begin
  if exists (select 1 from public.household_members where user_id = (select auth.uid())) then
    raise exception 'you already belong to a household';
  end if;

  insert into public.households (id) values (v_id) returning * into v_result;
  insert into public.household_members (household_id, user_id) values (v_id, (select auth.uid()));

  return v_result;
end;
$$;

revoke all on function create_household() from public;
grant execute on function create_household() to authenticated;

create function share_account(p_account_id uuid)
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
  from public.household_members where user_id = (select auth.uid());
  if v_household_id is null then
    raise exception 'you do not belong to a household';
  end if;

  insert into public.household_accounts (household_id, account_id)
  values (v_household_id, p_account_id)
  on conflict (household_id, account_id) do nothing;
end;
$$;

revoke all on function share_account(uuid) from public;
grant execute on function share_account(uuid) to authenticated;

create function unshare_account(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner from public.accounts where id = p_account_id and deleted_at is null;
  if v_owner is null or v_owner <> (select auth.uid()) then
    raise exception 'account not found or not owned by you';
  end if;

  delete from public.household_accounts
  where account_id = p_account_id
    and household_id in (
      select household_id from public.household_members where user_id = (select auth.uid())
    );
end;
$$;

revoke all on function unshare_account(uuid) from public;
grant execute on function unshare_account(uuid) to authenticated;

-- ============================================================================
-- net_worth(scope) — 'total' is always me + household, summed from
-- account_balances_base under two disjoint WHERE clauses, never subtraction
-- (H5): there is nothing client-visible to subtract from that RLS wouldn't
-- already have hidden. Each branch renders NULL (→ "—", never 0, money
-- rule 5) the instant any row in scope has a missing rate — a silent
-- partial SUM that dropped one unconvertible account would look like a
-- real total while quietly being wrong. An empty scope (no accounts at all)
-- is a legitimate, computable 0, not an unknown value — the two states are
-- deliberately not conflated.
-- ============================================================================

create function net_worth(p_scope account_scope)
returns numeric
language sql
stable
security invoker
set search_path = ''
as $$
  select case p_scope
    when 'me' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base is null) then null
        else sum(ab.balance_base)
      end
      from public.account_balances_base ab
      where not exists (select 1 from public.household_accounts ha where ha.account_id = ab.account_id)
    )
    when 'household' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base is null) then null
        else sum(ab.balance_base)
      end
      from public.account_balances_base ab
      where exists (select 1 from public.household_accounts ha where ha.account_id = ab.account_id)
    )
    when 'total' then (
      select case
        when count(*) = 0 then 0
        when bool_or(ab.balance_base is null) then null
        else sum(ab.balance_base)
      end
      from public.account_balances_base ab
    )
  end;
$$;

revoke all on function net_worth(account_scope) from public;
grant execute on function net_worth(account_scope) to authenticated, service_role;
