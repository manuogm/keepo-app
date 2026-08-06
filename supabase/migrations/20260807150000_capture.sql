-- Phase 12: Apple Pay capture & merchant learning.
--
-- Two new owner-scoped tables plus one DEFINER RPC. Both tables are
-- deliberately never joined into any household-visible view — card
-- mappings and merchant learning are per-device/per-user facts, not shared
-- money (app-architecture.md's explicit call for merchant_category_map,
-- extended here to card_mappings for the same reason: a joint card's
-- *mapping* is still each member's own record of which of their accounts
-- that card charges).

-- ============================================================================
-- card_mappings
-- ============================================================================

create table card_mappings (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  card_identifier text not null,
  -- null means unmapped — routes into needs_review until the user assigns
  -- an account. Composite FK (not a bare accounts(id)) so a mapping can
  -- never point at another owner's account even if account_id were ever
  -- set by anything other than map_card() below.
  account_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, card_identifier),
  foreign key (account_id, owner_id) references accounts (id, owner_id) deferrable initially deferred
);

alter table card_mappings enable row level security;

create policy card_mappings_select on card_mappings
  for select to authenticated
  using (owner_id = (select auth.uid()));

create policy card_mappings_insert on card_mappings
  for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy card_mappings_update on card_mappings
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

grant select, insert, update on card_mappings to authenticated, service_role;

create trigger card_mappings_set_updated_at
  before update on card_mappings
  for each row execute function set_updated_at();

create index card_mappings_unmapped_idx on card_mappings (owner_id) where account_id is null;

-- ============================================================================
-- merchant_category_map — per-user merchant learning (spec: never joined
-- into any household-visible view; built from all of a user's own
-- transactions, private and shared, but the mapping itself stays private).
-- ============================================================================

create table merchant_category_map (
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  merchant_pattern text not null,
  category_id uuid not null,
  updated_at timestamptz not null default now(),
  primary key (owner_id, merchant_pattern),
  foreign key (category_id, owner_id) references categories (id, owner_id) deferrable initially deferred
);

alter table merchant_category_map enable row level security;

create policy merchant_category_map_select on merchant_category_map
  for select to authenticated
  using (owner_id = (select auth.uid()));

create policy merchant_category_map_insert on merchant_category_map
  for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy merchant_category_map_update on merchant_category_map
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

grant select, insert, update on merchant_category_map to authenticated, service_role;

create trigger merchant_category_map_set_updated_at
  before update on merchant_category_map
  for each row execute function set_updated_at();

-- ============================================================================
-- A system "Uncategorized" expense category — the fallback for a captured
-- transaction whose merchant has no learned mapping yet. Same H14 pattern
-- as the Adjustment categories: system_key, never a second is_default row,
-- seeded for new signups and backfilled for existing users.
-- ============================================================================

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  insert into public.categories (owner_id, kind, name, system_key)
  values
    (new.id, 'expense', 'Adjustment', 'adjustment_expense'),
    (new.id, 'income', 'Adjustment', 'adjustment_income'),
    (new.id, 'expense', 'Uncategorized', 'uncategorized_expense')
  on conflict (owner_id, system_key) do nothing;
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
  insert into public.profiles (id)
  values (auth.uid())
  on conflict (id) do nothing;

  insert into public.categories (owner_id, kind, name, system_key)
  values
    (auth.uid(), 'expense', 'Adjustment', 'adjustment_expense'),
    (auth.uid(), 'income', 'Adjustment', 'adjustment_income'),
    (auth.uid(), 'expense', 'Uncategorized', 'uncategorized_expense')
  on conflict (owner_id, system_key) do nothing;
end;
$$;

insert into categories (owner_id, kind, name, system_key)
select p.id, 'expense', 'Uncategorized', 'uncategorized_expense'
from profiles p
on conflict (owner_id, system_key) do nothing;

-- ============================================================================
-- capture_transaction — the App Intent's one write. Rate-guarded (per spec:
-- "rate limiting on every ... ingestion path" — a forged or looping
-- automation is a cost-abuse vector, not just a UX bug). `external_id` and
-- `merchant_normalized` are computed client-side (KeepoCore.CaptureIdentity/
-- MerchantNormalizer) — no duplicate normalization logic here, matching
-- money rule "one place" and the existing external_id-is-client-computed
-- precedent. No ON CONFLICT: a retried call with the same client-generated
-- id hits transactions_pkey (23505), which the sender already treats as
-- "already applied," exactly like create_transaction/create_transfer.
--
-- An unmapped card is never silently dropped, but the purchase itself
-- cannot be recorded without an account — there is nowhere to attach a
-- signed amount. `card_mappings` gets its unmapped placeholder row (surfaces
-- in needs_review), and the RPC returns mapped = false without touching
-- transactions at all. The user maps the card once (map_card), and every
-- capture on it from then on succeeds.
-- ============================================================================

create function capture_transaction(
  p_id uuid,
  p_card_identifier text,
  p_merchant_raw text,
  p_merchant_normalized text,
  p_amount numeric(20, 4),
  p_occurred_at timestamptz,
  p_external_id text
)
returns table (mapped boolean, account_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_account_id uuid;
  v_currency text;
  v_category_id uuid;
  v_recent_count int;
begin
  select count(*) into v_recent_count
  from public.transactions
  where owner_id = v_owner
    and source = 'capture'
    and created_at > now() - interval '1 minute';

  if v_recent_count >= 20 then
    raise exception 'capture rate limit exceeded';
  end if;

  insert into public.card_mappings (owner_id, card_identifier)
  values (v_owner, p_card_identifier)
  on conflict (owner_id, card_identifier) do nothing;

  select cm.account_id into v_account_id
  from public.card_mappings cm
  where cm.owner_id = v_owner and cm.card_identifier = p_card_identifier;

  if v_account_id is null then
    return query select false, null::uuid;
    return;
  end if;

  select a.currency into v_currency from public.accounts a where a.id = v_account_id;

  select m.category_id into v_category_id
  from public.merchant_category_map m
  join public.categories c on c.id = m.category_id
  where m.owner_id = v_owner and m.merchant_pattern = p_merchant_normalized and c.kind = 'expense';

  if v_category_id is null then
    select id into v_category_id from public.categories
    where owner_id = v_owner and system_key = 'uncategorized_expense';
  end if;

  insert into public.transactions (
    id, owner_id, created_by, account_id, category_id, amount, currency, occurred_at,
    merchant_raw, merchant_normalized, source, status, external_id
  ) values (
    p_id, v_owner, v_owner, v_account_id, v_category_id, -abs(p_amount), v_currency, p_occurred_at,
    p_merchant_raw, p_merchant_normalized, 'capture', 'pending', p_external_id
  );

  return query select true, v_account_id;
end;
$$;

revoke all on function capture_transaction(uuid, text, text, text, numeric, timestamptz, text) from public;
grant execute on function capture_transaction(uuid, text, text, text, numeric, timestamptz, text) to authenticated;

-- ============================================================================
-- map_card — resolves an "ambiguous_card" needs_review item. Idempotent:
-- mapping an already-mapped card just overwrites the mapping (last write
-- wins; there is no concurrent-edit hazard worth a version column on a
-- single (owner, card) row nobody else can touch).
-- ============================================================================

create function map_card(p_card_identifier text, p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
begin
  if not exists (
    select 1 from public.accounts
    where id = p_account_id and owner_id = v_owner and kind = 'ledger'
      and deleted_at is null and archived_at is null
  ) then
    raise exception 'account not found, not accessible, archived, or not a spendable (ledger) account';
  end if;

  insert into public.card_mappings (owner_id, card_identifier, account_id)
  values (v_owner, p_card_identifier, p_account_id)
  on conflict (owner_id, card_identifier) do update set account_id = excluded.account_id;
end;
$$;

revoke all on function map_card(text, uuid) from public;
grant execute on function map_card(text, uuid) to authenticated;

-- ============================================================================
-- confirm_capture_transaction — the review step. A pending capture becomes
-- confirmed; category/account/amount edits go through the existing
-- update_transaction (the review screen is TransactionFormView in edit
-- mode per app-architecture.md, not a bespoke capture-review screen), so
-- this RPC only ever flips status. Versioned like every other write.
-- ============================================================================

create function confirm_capture_transaction(p_id uuid, p_expected_version int)
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
  select id, version, owner_id into v_current from public.transactions where id = p_id;

  if v_current.id is null or v_current.owner_id <> v_owner then
    raise exception 'transaction not found or not accessible';
  end if;

  update public.transactions
  set status = 'confirmed'
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

revoke all on function confirm_capture_transaction(uuid, int) from public;
grant execute on function confirm_capture_transaction(uuid, int) to authenticated;

-- ============================================================================
-- needs_review — two new branches. "Low-confidence category suggestions"
-- (app-architecture.md's phrasing) folds into pending_capture's subtitle
-- rather than becoming a third UNION branch: merchant_category_map has no
-- confidence score anywhere in the schema, and every capture already
-- requires a review tap regardless of where its category guess came from.
-- See keepo-v1-master-plan.md's Phase 12 note for the full reasoning.
-- ============================================================================

create or replace view needs_review
with (security_invoker = true) as
select
  'sync_conflict'::text as kind,
  sc.id as item_id,
  case sc.table_name
    when 'accounts' then sc.row_id
    when 'transactions' then (select t.account_id from transactions t where t.id = sc.row_id)
  end as account_id,
  sc.created_at as occurred_at,
  'Sync conflict — ' || sc.table_name as title,
  'your version ' || sc.client_version || ' vs. the saved version ' || sc.server_version as subtitle,
  null::numeric(20, 4) as amount,
  null::text as currency
from sync_conflicts sc
where sc.resolved_at is null

union all

select
  'reconciliation_gap'::text as kind,
  a.account_id as item_id,
  a.account_id,
  a.last_verified_at as occurred_at,
  a.name || ' needs verifying' as title,
  null::text as subtitle,
  a.balance as amount,
  a.currency
from accounts_sync_status a
where a.is_stale and a.archived_at is null

union all

select
  'pending_capture'::text as kind,
  t.id as item_id,
  t.account_id,
  t.occurred_at,
  'Review capture — ' || coalesce(t.merchant_raw, 'Unknown merchant') as title,
  case when c.system_key = 'uncategorized_expense' then 'Uncategorized' else 'Suggested: ' || c.name end as subtitle,
  t.amount,
  t.currency
from transactions t
join categories c on c.id = t.category_id
where t.source = 'capture' and t.status = 'pending' and t.deleted_at is null

union all

select
  'ambiguous_card'::text as kind,
  cm.id as item_id,
  null::uuid as account_id,
  cm.created_at as occurred_at,
  'Unmapped card — ' || cm.card_identifier as title,
  null::text as subtitle,
  null::numeric(20, 4) as amount,
  null::text as currency
from card_mappings cm
where cm.account_id is null;

grant select on needs_review to authenticated, service_role;
