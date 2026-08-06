-- Phase 18: CSV import & export.
--
-- Import: client parses the file and sends every row in one call
-- (import_csv_rows) rather than one RPC per row — a statement's worth of
-- round trips for what could be a hundred-row statement. Matching (exact
-- amount, +/-3 days, same account) happens inline at insert time, per
-- app-architecture.md §4. CSV carries no bank-assigned id, so nothing is
-- ever blind-inserted: every row becomes a review candidate, matched or
-- not, and only accept_import_candidate ever writes to transactions.
--
-- Export: the client already has everything it needs to build a CSV from
-- existing reads (transactions_with_details etc.) — no new read RPC. What's
-- missing is the audit trail the spec requires ("every export writes an
-- audit row: account, timestamp, what was exported") and the step-up gate
-- immediately before generation, which is enforced client-side
-- (StepUpAuthenticator, Phase 17) since Postgres has no way to observe
-- "the app just asked for Face ID."
--
-- Also here: the cross-currency transfer rate-divergence guard flagged in
-- the master plan as "if not already landed with transfers" — it wasn't.
-- A pure read RPC the client calls before create_transfer, never inside
-- it: create_transfer's signature/behavior stays untouched for every
-- existing caller, and "warn, don't block" (spec's own framing) is a
-- client-side confirmation dialog, not a server-side rejection.

create type import_candidate_status as enum ('pending', 'accepted', 'rejected');

-- ============================================================================
-- csv_import_batches / csv_import_candidates. owner_id is the ACCOUNT's
-- owner (derived by trigger, same pattern recurring_rules used in Phase 14
-- for the identical reason), not necessarily the importing household
-- member — the resulting transactions must satisfy transactions' existing
-- (account_id, owner_id) composite FK regardless of who ran the import.
-- RLS keys off can_write_account(account_id), not owner_id equality, so
-- both household members can import against and review a shared account
-- from day one — no H2/H3-style retrofit later since this table is new.
-- ============================================================================

create table csv_import_batches (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  account_id uuid not null,
  filename text not null,
  created_at timestamptz not null default now(),
  foreign key (account_id, owner_id) references accounts (id, owner_id) deferrable initially deferred
);

alter table csv_import_batches enable row level security;

create policy csv_import_batches_select on csv_import_batches
  for select to authenticated
  using (can_write_account(account_id));

create policy csv_import_batches_insert on csv_import_batches
  for insert to authenticated
  with check (can_write_account(account_id));

grant select, insert on csv_import_batches to authenticated, service_role;

create function set_csv_import_batch_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select owner_id into new.owner_id from public.accounts where id = new.account_id;
  return new;
end;
$$;

create trigger csv_import_batches_set_owner
  before insert on csv_import_batches
  for each row execute function set_csv_import_batch_owner();

create table csv_import_candidates (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references csv_import_batches (id) deferrable initially deferred,
  account_id uuid not null,
  owner_id uuid not null,
  raw_row jsonb not null,
  occurred_at timestamptz not null,
  amount numeric(20, 4) not null,
  currency text not null,
  merchant_raw text,
  merchant_normalized text,
  matched_transaction_id uuid references transactions (id) deferrable initially deferred,
  status import_candidate_status not null default 'pending',
  created_at timestamptz not null default now(),
  foreign key (account_id, owner_id) references accounts (id, owner_id) deferrable initially deferred
);

create index csv_import_candidates_batch_idx on csv_import_candidates (batch_id);
create index csv_import_candidates_pending_idx on csv_import_candidates (account_id) where status = 'pending';

alter table csv_import_candidates enable row level security;

create policy csv_import_candidates_select on csv_import_candidates
  for select to authenticated
  using (can_write_account(account_id));

create policy csv_import_candidates_insert on csv_import_candidates
  for insert to authenticated
  with check (can_write_account(account_id));

create policy csv_import_candidates_update on csv_import_candidates
  for update to authenticated
  using (can_write_account(account_id))
  with check (can_write_account(account_id));

grant select, insert, update on csv_import_candidates to authenticated, service_role;

-- ============================================================================
-- resolve_category_for_merchant — factored out of Phase 12's
-- capture_transaction, which had this exact lookup inlined. Both capture
-- and CSV import need "a learned merchant mapping, else this owner's
-- fallback for the row's kind" — one place, per CLAUDE.md's reuse
-- principle, now that a second caller genuinely exists (the extraction
-- threshold this project applies throughout: two call sites stay
-- duplicated, a third is the signal — capture already existed, so this
-- is the second, and the moment to extract rather than copy again).
-- Expense fallback is the system 'uncategorized_expense' category
-- (unchanged capture behavior); income has no such system category, so it
-- falls back to the kind's own is_default row instead.
-- ============================================================================

create function resolve_category_for_merchant(p_owner uuid, p_merchant_normalized text, p_kind category_kind)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select m.category_id
      from public.merchant_category_map m
      join public.categories c on c.id = m.category_id
      where m.owner_id = p_owner and m.merchant_pattern = p_merchant_normalized and c.kind = p_kind
    ),
    (
      select id from public.categories
      where owner_id = p_owner
        and deleted_at is null
        and (
          (p_kind = 'expense' and system_key = 'uncategorized_expense')
          or (p_kind = 'income' and kind = 'income' and is_default)
        )
      limit 1
    )
  );
$$;

revoke all on function resolve_category_for_merchant(uuid, text, category_kind) from public;
grant execute on function resolve_category_for_merchant(uuid, text, category_kind) to authenticated;

create or replace function capture_transaction(
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

  v_category_id := public.resolve_category_for_merchant(v_owner, p_merchant_normalized, 'expense');

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

-- ============================================================================
-- import_csv_rows — the one write for an entire statement. p_rows is a
-- jsonb array; each element carries occurred_at (ISO), amount (signed,
-- numeric-as-text), currency, merchant_raw, merchant_normalized, and the
-- original raw_row (kept verbatim for the review screen and for
-- ops_events-style debugging, per app-architecture.md's "raw_row jsonb").
-- Matching is exact amount + same account + occurred_at within 3 days of
-- an existing, non-deleted transaction on that account — informational
-- only: a match doesn't block the row, it surfaces as "possible duplicate"
-- so the reviewer can reject it instead of accept_import_candidate
-- creating a second, real transaction.
-- ============================================================================

create function import_csv_rows(p_account_id uuid, p_filename text, p_rows jsonb)
returns setof csv_import_candidates
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_batch_id uuid;
  v_row jsonb;
  v_occurred_at timestamptz;
  v_amount numeric(20, 4);
  v_currency text;
  v_matched uuid;
begin
  if not public.can_write_account(p_account_id) then
    raise exception 'account not found or not accessible';
  end if;

  insert into public.csv_import_batches (account_id, filename)
  values (p_account_id, p_filename)
  returning id into v_batch_id;

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_occurred_at := (v_row ->> 'occurred_at')::timestamptz;
    v_amount := (v_row ->> 'amount')::numeric(20, 4);
    v_currency := v_row ->> 'currency';

    select t.id into v_matched
    from public.transactions t
    where t.account_id = p_account_id
      and t.deleted_at is null
      and t.amount = v_amount
      and t.currency = v_currency
      and t.occurred_at between v_occurred_at - interval '3 days' and v_occurred_at + interval '3 days'
    limit 1;

    insert into public.csv_import_candidates (
      batch_id, account_id, owner_id, raw_row, occurred_at, amount, currency,
      merchant_raw, merchant_normalized, matched_transaction_id
    )
    select
      v_batch_id, p_account_id, b.owner_id, v_row, v_occurred_at, v_amount, v_currency,
      v_row ->> 'merchant_raw', v_row ->> 'merchant_normalized', v_matched
    from public.csv_import_batches b
    where b.id = v_batch_id;
  end loop;

  return query select * from public.csv_import_candidates where batch_id = v_batch_id;
end;
$$;

revoke all on function import_csv_rows(uuid, text, jsonb) from public;
grant execute on function import_csv_rows(uuid, text, jsonb) to authenticated;

-- ============================================================================
-- accept_import_candidate / reject_import_candidate — the only two writers
-- of csv_import_candidates.status. Accepting always inserts a NEW
-- transaction (source = 'csv_import', status 'confirmed' — the accept tap
-- IS the review, unlike a pending capture); a matched candidate is not
-- special-cased into a no-op, since the reviewer already saw the match and
-- chose to accept anyway (e.g. two genuinely separate purchases of the
-- same amount within the window). Category follows the row's sign via the
-- same kind-matching rule sign_matches_category_kind already enforces.
-- ============================================================================

create function accept_import_candidate(p_id uuid)
returns table (conflict boolean, transaction public.transactions)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_candidate record;
  v_kind public.category_kind;
  v_category_id uuid;
  v_result public.transactions;
begin
  select * into v_candidate from public.csv_import_candidates where id = p_id;

  if v_candidate.id is null or not public.can_write_account(v_candidate.account_id) then
    raise exception 'import candidate not found or not accessible';
  end if;

  if v_candidate.status <> 'pending' then
    raise exception 'import candidate already reviewed';
  end if;

  v_kind := case when v_candidate.amount < 0 then 'expense' else 'income' end;
  v_category_id := public.resolve_category_for_merchant(v_candidate.owner_id, v_candidate.merchant_normalized, v_kind);

  insert into public.transactions (
    owner_id, created_by, account_id, category_id, amount, currency, occurred_at,
    merchant_raw, merchant_normalized, source, status
  ) values (
    v_candidate.owner_id, v_owner, v_candidate.account_id, v_category_id, v_candidate.amount, v_candidate.currency,
    v_candidate.occurred_at, v_candidate.merchant_raw, v_candidate.merchant_normalized, 'csv_import', 'confirmed'
  )
  returning * into v_result;

  update public.csv_import_candidates set status = 'accepted' where id = p_id;

  return query select false, v_result;
end;
$$;

revoke all on function accept_import_candidate(uuid) from public;
grant execute on function accept_import_candidate(uuid) to authenticated;

create function reject_import_candidate(p_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.csv_import_candidates
  set status = 'rejected'
  where id = p_id and status = 'pending' and public.can_write_account(account_id);
end;
$$;

revoke all on function reject_import_candidate(uuid) from public;
grant execute on function reject_import_candidate(uuid) to authenticated;

-- ============================================================================
-- needs_review — the fifth and final planned branch (spec's own list:
-- sync_conflicts, reconciliation gaps, pending captures, ambiguous cards,
-- csv_import_candidates). Stable column contract, unchanged decoder.
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
where cm.account_id is null

union all

select
  'csv_import_candidate'::text as kind,
  ic.id as item_id,
  ic.account_id,
  ic.occurred_at,
  'Import row — ' || coalesce(ic.merchant_raw, 'no description') as title,
  case when ic.matched_transaction_id is not null then 'Possible duplicate of an existing transaction' end as subtitle,
  ic.amount,
  ic.currency
from csv_import_candidates ic
where ic.status = 'pending';

grant select on needs_review to authenticated, service_role;

-- ============================================================================
-- export_audit_log — append-only: no INSERT/UPDATE/DELETE grant to
-- authenticated at all, same "write only through a vetted function"
-- precedent as sync_conflicts/fx_rates. log_export is SECURITY DEFINER for
-- exactly that reason. Written immediately after the
-- client's step-up re-auth and immediately before it actually builds the
-- CSV — the row proves an export happened even though the export itself
-- can never be undone.
-- ============================================================================

create table export_audit_log (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  account_ids uuid[] not null,
  row_count int not null,
  exported_at timestamptz not null default now()
);

alter table export_audit_log enable row level security;

create policy export_audit_log_select on export_audit_log
  for select to authenticated
  using (owner_id = (select auth.uid()));

grant select on export_audit_log to authenticated, service_role;

create function log_export(p_account_ids uuid[], p_row_count int)
returns export_audit_log
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result public.export_audit_log;
begin
  insert into public.export_audit_log (owner_id, account_ids, row_count)
  values ((select auth.uid()), p_account_ids, p_row_count)
  returning * into v_result;
  return v_result;
end;
$$;

revoke all on function log_export(uuid[], int) from public;
grant execute on function log_export(uuid[], int) to authenticated;

-- ============================================================================
-- check_transfer_rate_divergence — read-only guard the client calls before
-- create_transfer on a cross-currency transfer, never inside it (keeps
-- create_transfer's own signature and every existing caller untouched).
-- Compares the transfer's own implied rate against the day's fx_rates-
-- derived market rate; >10% divergence is exactly what catches a "320"
-- typed as "3200" (spec's own example) without blocking a legitimately
-- unfavorable but real quote. Same-currency transfers never diverge by
-- definition and are not this function's concern (the client only calls
-- it when from_currency <> to_currency).
-- ============================================================================

create function check_transfer_rate_divergence(
  p_from_currency text,
  p_to_currency text,
  p_from_amount numeric,
  p_to_amount numeric,
  p_occurred_at timestamptz
)
returns table (diverges boolean, implied_rate numeric, market_rate numeric, pct_diff numeric)
language sql
stable
security invoker
set search_path = ''
as $$
  select
    abs(implied - market) / market > 0.10 as diverges,
    implied as implied_rate,
    market as market_rate,
    (implied - market) / market as pct_diff
  from (
    select
      p_to_amount / p_from_amount as implied,
      public.fx_convert(1, p_from_currency, p_to_currency, p_occurred_at::date) as market
  ) rates
  where market is not null;
$$;

revoke all on function check_transfer_rate_divergence(text, text, numeric, numeric, timestamptz) from public;
grant execute on function check_transfer_rate_divergence(text, text, numeric, numeric, timestamptz) to authenticated;
