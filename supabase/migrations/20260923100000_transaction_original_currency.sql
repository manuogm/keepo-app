-- A purchase made in a currency other than its account's.
--
-- Two real cases, neither expressible before this. (a) Manual: travelling in
-- Europe with a USD account, there is no way to say a purchase was in euros.
-- (b) Capture: Wallet reports `€50.00` on a card mapped to a USD account and
-- the pipeline records **$50**. app-architecture.md §4 item 2 claimed the
-- symbol was "a mismatch check only" — it never was: the symbol was stripped
-- and discarded, so there was nowhere for a check to happen.
--
-- CLAUDE.md money rule 6 was amended before this migration was written, and
-- reading it first is not optional. The short version: a *display*
-- conversion (account currency → the viewer's base currency) is still never
-- stored, because the base currency can change. A *paid → account*
-- conversion is a fact about what happened, and it is stored — in
-- `amount_e4`, because `balance = opening_balance + SUM(amount)` requires
-- every row to be in its account's currency — with `original_amount_e4` and
-- `original_currency` recording what was actually paid.
--
-- THE PROPERTY THAT MAKES STORING IT HONEST: the figure is prefilled and
-- **always editable**. Keepo's ECB reference rate is not the rate the bank
-- used — Visa, Amex and Revolut each add a spread — and the balance is a
-- running sum, so a silently stored reference conversion would drift the
-- account away from reality permanently, with a number that was never true.
-- The user overwrites it with what their bank charged. Every RPC below
-- therefore *stores* what the client sends and only *computes* where no
-- human has seen the number yet (`capture_transaction`).
--
-- THE INVARIANT THIS MIGRATION EXTENDS, which is the key to reading it:
-- `account_id`/`currency` are set only when `amount_e4` is genuinely in that
-- account's currency. `account_currency_together` already said both or
-- neither; this says *why*. An unknown card and an unresolvable rate are
-- the same problem — no amount can be expressed in an account's currency
-- yet — so both land the same way, with the original recorded and the
-- account left for the review form to supply. Neither is allowed to invent
-- a figure (money rule 5: `—`, never `0`, never a guessed rate).

-- ============================================================================
-- 1. The columns
-- ============================================================================

alter table public.transactions
  add column original_amount_e4 bigint,
  add column original_currency text references public.currencies (code);

comment on column public.transactions.original_amount_e4 is
  'What was actually paid, when that differs from the account''s currency. Provenance only: never summed, never re-converted, never a balance. See CLAUDE.md money rule 6.';

-- Set or null together, so one can never be read without the other.
alter table public.transactions add constraint original_amount_currency_together
  check ((original_amount_e4 is null) = (original_currency is null));

-- The original is stored ONLY when it differs, so a non-null original always
-- means "this was foreign" and the ordinary row stays clean — "is this a
-- foreign transaction?" is a null check, not a comparison. `currency is
-- null` is the held case: the account is not known yet, so there is nothing
-- to differ from.
alter table public.transactions add constraint original_currency_differs
  check (original_currency is null or currency is null or original_currency <> currency);

-- €50 paid cannot have charged +$54. Written as a boolean comparison rather
-- than sign(), which would resolve through numeric and admit 0.
alter table public.transactions add constraint original_amount_sign_matches
  check (original_amount_e4 is null or (original_amount_e4 < 0) = (amount_e4 < 0));

-- ============================================================================
-- 2. A currency you transact in is a currency in use
--
-- Without this the feature does not work at all, and the reason is worth
-- stating: `sync-fx-rates` fetches rates for currencies in use, defined as
-- `accounts.currency ∪ profiles.base_currency`. A currency you are
-- travelling in is by definition NOT one you hold an account in — so a
-- Spaniard paying in baht has no THB rate, and never would have. The
-- missing-rate case is therefore the COMMON case for exactly the user this
-- feature exists for, not an exotic one.
--
-- Same shape as accounts_backfill_fx_on_new_currency: a trigger, because
-- "a currency newly in use needs rates" is a property of the data and not
-- of whichever RPC happened to write it. The edge function's own
-- currencies-in-use query is extended to match (see
-- supabase/functions/sync-fx-rates/index.ts) — both halves are required.
-- ============================================================================

create function public.trigger_fx_backfill_on_new_original_currency()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.original_currency is not null and new.original_currency <> 'EUR'
     and not exists (select 1 from public.fx_rates where currency = new.original_currency) then
    -- pg_net, asynchronous, and silent when the vault secrets are unset
    -- (ops_http_post logs an ops_event and returns). A capture must never
    -- fail because a rate fetch could not be dispatched.
    perform public.request_fx_backfill();
  end if;
  return new;
end;
$$;

-- A trigger function is invoked by the table owner, never called directly,
-- so PUBLIC needs no EXECUTE on it — and 01_grants_rls asserts that nothing
-- in public is executable by PUBLIC. Same revoke its two siblings got in
-- 20260830120000_p2_hardening.sql.
revoke all on function public.trigger_fx_backfill_on_new_original_currency() from public;

create trigger transactions_backfill_fx_on_new_original_currency
  after insert or update of original_currency on public.transactions
  for each row execute function public.trigger_fx_backfill_on_new_original_currency();

-- ============================================================================
-- 3. capture_transaction — the only place that converts without a human
--
-- DROPPED and recreated rather than `create or replace`d: a 9th defaulted
-- parameter added to an 8-parameter function creates a second function
-- rather than replacing the first, and every existing 8-argument call then
-- fails as "function is not unique". Same reasoning, and the same fix, as
-- 20260903100000 applied to link_card_to_account.
--
-- Body is 20260901100000's verbatim (the authoritative one) plus the
-- currency arm — re-read in full rather than patched from an excerpt, per
-- version-logs/lessons-learned.md.
-- ============================================================================

drop function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text);

create function public.capture_transaction(
  p_id uuid, p_card_identifier text, p_merchant_raw text, p_merchant_normalized text, p_amount_e4 bigint,
  p_occurred_at timestamptz, p_external_id text, p_notes text default null,
  p_detected_currency text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_account_id uuid;
  v_currency text;
  v_category_id uuid;
  v_detected text := nullif(upper(trim(coalesce(p_detected_currency, ''))), '');
  v_paid bigint := -abs(p_amount_e4);
  v_amount bigint;
  v_original_amount bigint;
  v_original_currency text;
begin
  if not public.ops_check_own_rate_limit('capture_transaction', 20, 60) then
    raise exception 'capture rate limit exceeded';
  end if;

  insert into public.card_mappings (owner_id, card_identifier)
  values (v_owner, p_card_identifier)
  on conflict (owner_id, card_identifier) do nothing;

  -- `deleted_at is null` (20260901100000's fix A): an unmapped card must
  -- resolve to no account at all, landing the capture as an ordinary
  -- unresolved pending review, not silently back into the account it was
  -- unmapped from.
  select cm.account_id into v_account_id
  from public.card_mappings cm
  where cm.owner_id = v_owner and cm.card_identifier = p_card_identifier and cm.deleted_at is null;

  if v_account_id is not null then
    select a.currency into v_currency from public.accounts a where a.id = v_account_id;
  end if;

  -- A currency this app cannot price is the same as none detected. The
  -- client's detector is already restricted to the supported set; this is
  -- the server refusing to take its word for it.
  if v_detected is not null and not exists (select 1 from public.currencies c where c.code = v_detected) then
    v_detected := null;
  end if;

  v_amount := v_paid;

  if v_detected is not null and v_currency is not null and v_detected <> v_currency then
    -- The account is known, so the conversion can happen now and both
    -- figures go to review together. fx_rate_on(occurred_at), never
    -- today's rate: the purchase happened when it happened.
    v_original_amount := v_paid;
    v_original_currency := v_detected;
    v_amount := public.fx_convert(v_paid, v_detected, v_currency, p_occurred_at::date);

    if v_amount is null then
      -- No resolvable rate for that pair and date. There is no number that
      -- belongs in this account's currency, so the row does not claim one:
      -- it holds what was paid and waits. The trigger above has just asked
      -- for a backfill, so the rate usually exists by the time the user
      -- opens the review; if it still does not, the form shows `—` and the
      -- user types what their bank charged (money rule 5).
      v_amount := v_paid;
      v_account_id := null;
      v_currency := null;
    end if;
  elsif v_detected is not null and v_currency is null then
    -- The card is not mapped yet, so there is no account currency to
    -- compare against. Hold the pair; the review form converts once the
    -- user picks an account, which is also the moment a human first sees
    -- the number — the property money rule 6 turns on.
    v_original_amount := v_paid;
    v_original_currency := v_detected;
  end if;

  v_category_id := public.resolve_category_for_merchant(v_owner, p_merchant_normalized, 'expense');

  insert into public.transactions (
    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, notes, source, status, external_id, card_identifier,
    original_amount_e4, original_currency
  ) values (
    p_id, v_owner, v_owner, v_account_id, v_category_id, v_amount, v_currency, p_occurred_at,
    p_merchant_raw, p_merchant_normalized, p_notes, 'capture', 'pending', p_external_id, p_card_identifier,
    v_original_amount, v_original_currency
  );
end;
$$;

revoke all on function public.capture_transaction(
  uuid, text, text, text, bigint, timestamptz, text, text, text
) from public;
grant execute on function public.capture_transaction(
  uuid, text, text, text, bigint, timestamptz, text, text, text
) to authenticated;

-- ============================================================================
-- 4. review_capture_transaction and update_transaction — they STORE, never
--    compute. By the time either runs, a human has seen the converted
--    figure in the form and had the chance to replace it with what their
--    bank actually charged. Recomputing here would throw that away.
--
--    Both normalize a same-currency original to null rather than rejecting
--    it, so `original_currency_differs` can never be tripped by a client
--    that passes the account's own currency through.
--
--    Both dropped and recreated for the same arity reason as above. Bodies
--    are 20260825100000's and 20260822100000's verbatim plus the two
--    parameters.
-- ============================================================================

drop function public.review_capture_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text
);

create function public.review_capture_transaction(
  p_id uuid, p_expected_version integer, p_account_id uuid, p_category_id uuid, p_amount_e4 bigint,
  p_currency text, p_occurred_at timestamptz, p_merchant_raw text default null, p_notes text default null,
  p_original_amount_e4 bigint default null, p_original_currency text default null
)
returns table(conflict boolean, transaction transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.transactions;
  v_original_amount bigint := p_original_amount_e4;
  v_original_currency text := nullif(upper(trim(coalesce(p_original_currency, ''))), '');
begin
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, status, card_identifier,
         merchant_normalized
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  if v_current.source <> 'capture' or v_current.status <> 'pending' then
    raise exception 'transaction % is not a pending capture — use update_transaction', p_id;
  end if;

  if v_current.account_id is not null then
    if not public.can_write_account(v_current.account_id) then
      raise exception 'transaction not found or not accessible';
    end if;
  elsif v_current.owner_id <> v_owner then
    raise exception 'transaction not found or not accessible';
  end if;

  if not public.can_write_account(p_account_id)
     or exists (select 1 from public.accounts where id = p_account_id and deleted_at is not null) then
    raise exception 'account not found or not accessible';
  end if;

  if v_original_currency is null or v_original_currency = p_currency then
    v_original_amount := null;
    v_original_currency := null;
  end if;

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount_e4 = p_amount_e4,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw,
    notes = p_notes,
    status = 'confirmed',
    original_amount_e4 = v_original_amount,
    original_currency = v_original_currency
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);
    return query select true, null::public.transactions;
    return;
  end if;

  if v_current.account_id is null and v_current.card_identifier is not null then
    perform public.link_card_to_account(v_owner, v_current.card_identifier, p_account_id);
  end if;

  if v_current.merchant_normalized is not null then
    insert into public.merchant_category_map (owner_id, merchant_pattern, category_id)
    values (v_owner, v_current.merchant_normalized, p_category_id)
    on conflict (owner_id, merchant_pattern) do update set category_id = excluded.category_id, updated_at = now();
  end if;

  return query select false, v_result;
end;
$$;

revoke all on function public.review_capture_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text, bigint, text
) from public;
grant execute on function public.review_capture_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text, bigint, text
) to authenticated;

drop function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text
);

create function public.update_transaction(
  p_id uuid, p_expected_version integer, p_account_id uuid, p_category_id uuid, p_amount_e4 bigint,
  p_currency text, p_occurred_at timestamptz, p_merchant_raw text default null, p_notes text default null,
  p_original_amount_e4 bigint default null, p_original_currency text default null
)
returns table(conflict boolean, transaction transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.transactions;
  v_original_amount bigint := p_original_amount_e4;
  v_original_currency text := nullif(upper(trim(coalesce(p_original_currency, ''))), '');
begin
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, card_identifier
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  if v_current.account_id is not null then
    if not public.can_write_account(v_current.account_id) then
      raise exception 'transaction not found or not accessible';
    end if;
  elsif v_current.owner_id <> v_owner then
    raise exception 'transaction not found or not accessible';
  end if;

  if not public.can_write_account(p_account_id)
     or exists (select 1 from public.accounts where id = p_account_id and deleted_at is not null) then
    raise exception 'account not found or not accessible';
  end if;

  if v_original_currency is null or v_original_currency = p_currency then
    v_original_amount := null;
    v_original_currency := null;
  end if;

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount_e4 = p_amount_e4,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw,
    notes = p_notes,
    original_amount_e4 = v_original_amount,
    original_currency = v_original_currency
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.transactions;
    return;
  end if;

  if v_current.account_id is null and v_current.source = 'capture' and v_current.card_identifier is not null then
    perform public.link_card_to_account(v_owner, v_current.card_identifier, p_account_id);
  end if;

  return query select false, v_result;
end;
$$;

revoke all on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text, bigint, text
) from public;
grant execute on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text, bigint, text
) to authenticated;

-- ============================================================================
-- 5. Reads
--
-- Both views are restated from their AUTHORITATIVE definitions —
-- transactions_with_details from 20260822100000, needs_review from
-- 20260909100000 — not from the older copies in 20260815100000, which
-- differ in ways that would have silently reverted live behaviour: the
-- older transactions_with_details INNER JOINs accounts (which would have
-- hidden every unresolved capture, including the ones this migration
-- creates) and omits `notes`, and the older needs_review still carries
-- the deleted CSV-import branch and none of ambiguous_card's guards.
--
-- transactions_with_details gains the pair plus the original currency's own
-- minor_unit — a form cannot render "¥1,234" without knowing the currency
-- has no decimals, and the view already carries `minor_unit` for exactly
-- that reason. Appended at the end of the select list, which is the only
-- place CREATE OR REPLACE VIEW allows a new column (lessons-learned).
--
-- needs_review's `currency` becomes coalesce(currency, original_currency).
-- A held foreign capture has no account currency yet, and the inbox was
-- rendering its amount against a null currency. The amount shown IS the
-- original while the row is held (capture_transaction stores the paid
-- figure in both), so this labels it correctly rather than inventing one.
-- ============================================================================

create or replace view transactions_with_details
with (security_invoker = true) as
select
  t.id as transaction_id,
  t.account_id,
  a.name as account_name,
  t.category_id,
  c.name as category_name,
  t.amount_e4,
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
    when t.amount_e4 < 0 then 'expense'
    else 'income'
  end as kind,
  t.created_by,
  t.created_at,
  t.version,
  p.base_currency,
  bc.minor_unit as base_minor_unit,
  fx_convert(t.amount_e4, t.currency, p.base_currency, t.occurred_at::date) as amount_base_e4,
  (fx_convert(t.amount_e4, t.currency, p.base_currency, t.occurred_at::date) is null) as has_missing_rate,
  t.recurring_rule_id,
  t.notes,
  t.original_amount_e4,
  t.original_currency,
  ocur.minor_unit as original_minor_unit
from transactions t
left join accounts a on a.id = t.account_id
left join categories c on c.id = t.category_id
left join currencies cur on cur.code = t.currency
left join profiles p on p.id = (select auth.uid())
left join currencies bc on bc.code = p.base_currency
left join currencies ocur on ocur.code = t.original_currency
where t.deleted_at is null;

create or replace view needs_review
with (security_invoker = true) as
select
  'sync_conflict'::text as kind,
  sc.id as item_id,
  case sc.table_name
    when 'accounts' then sc.row_id
    when 'transactions' then (select t.account_id from transactions t where t.id = sc.row_id)
    else null::uuid
  end as account_id,
  sc.created_at as occurred_at,
  'Sync conflict — ' || sc.table_name as title,
  'your version ' || sc.client_version || ' vs. the saved version ' || sc.server_version as subtitle,
  null::bigint as amount_e4,
  null::text as currency
from sync_conflicts sc
where sc.resolved_at is null
union all
select
  'pending_capture'::text as kind,
  t.id as item_id,
  t.account_id,
  t.occurred_at,
  'Review capture — ' || coalesce(t.merchant_raw, 'Unknown merchant') as title,
  case when c.is_default then 'Other' else 'Suggested: ' || c.name end as subtitle,
  t.amount_e4,
  coalesce(t.currency, t.original_currency) as currency
from transactions t
join categories c on c.id = t.category_id
where t.source = 'capture' and t.status = 'pending' and t.deleted_at is null
union all
select
  'ambiguous_card'::text as kind,
  cm.id as item_id,
  null::uuid as account_id,
  cm.created_at as occurred_at,
  'Unmapped card'::text as title,
  cm.card_identifier as subtitle,
  null::bigint as amount_e4,
  null::text as currency
from card_mappings cm
where cm.account_id is null
  and cm.deleted_at is null
  and not exists (
    select 1 from transactions t2
    where t2.owner_id = cm.owner_id and t2.card_identifier = cm.card_identifier
      and t2.source = 'capture' and t2.status = 'pending' and t2.deleted_at is null
  );
