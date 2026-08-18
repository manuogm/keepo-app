-- S-03/S-04: ops_check_rate_limit was a single global counter per function
-- name — fine for a cron-only caller, wrong for anything a signed-in user
-- can call directly. One user looping sync-fx-rates 20 times exhausted the
-- nightly cron's own budget for every user on the project (S-04); the same
-- shape meant any RPC this got added to would let one user's spike degrade
-- service for everyone else calling the same RPC, rather than only
-- throttling that one user.
--
-- Generalizes the counter to (function_name, subject) — service_role
-- (Edge Functions) can key it by whatever caller identity makes sense
-- (a fixed 'cron' string for the secret-header path, the JWT user id for
-- the on-demand path), and every write RPC below keys it by its own
-- caller's auth.uid() via ops_check_own_rate_limit, a thin wrapper that
-- hardcodes the subject to auth.uid() so a client granted EXECUTE on it
-- can only ever rate-limit *themselves* — passing another user's id to
-- grief their budget was the one new hole a naive "just add a subject
-- parameter, grant it to authenticated" change would have opened.
--
-- Scope: this migration replaces capture_transaction's bespoke counter
-- (the audit's explicit ask) and adds the same guard to the operations
-- flagged as actually expensive or spam-prone — pull_changes (unpaginated,
-- aggregates every syncable table), create_invite/accept_invite (each
-- sends a household-lifecycle notification), and log_export. Ordinary
-- per-transaction CRUD (update_transaction, delete_transaction,
-- create_transfer, set_account_balance, import_csv_rows) is deliberately
-- left unlimited in this pass — these are exactly the RPCs a legitimate
-- user's normal bulk-editing session calls many times a minute, and
-- picking a threshold without real usage data risks throttling real work
-- to close a lower-severity gap (cost/availability, not data exposure).
-- Revisit if usage data ever suggests otherwise.

alter table ops_rate_limits add column subject text not null default '';
alter table ops_rate_limits drop constraint ops_rate_limits_pkey;
alter table ops_rate_limits add primary key (function_name, subject);

create or replace function ops_check_rate_limit(
  p_function_name text, p_subject text, p_max_calls int, p_window_seconds int
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.ops_rate_limits;
begin
  insert into public.ops_rate_limits (function_name, subject) values (p_function_name, p_subject)
  on conflict (function_name, subject) do nothing;

  select * into v_row from public.ops_rate_limits
  where function_name = p_function_name and subject = p_subject for update;

  if now() - v_row.window_started_at > (p_window_seconds || ' seconds')::interval then
    update public.ops_rate_limits set window_started_at = now(), count = 1
    where function_name = p_function_name and subject = p_subject;
    return true;
  end if;

  if v_row.count >= p_max_calls then
    return false;
  end if;

  update public.ops_rate_limits set count = count + 1
  where function_name = p_function_name and subject = p_subject;
  return true;
end;
$$;

revoke all on function ops_check_rate_limit(text, text, int, int) from public;
grant execute on function ops_check_rate_limit(text, text, int, int) to service_role;

-- The only entry point granted to authenticated — subject is never a
-- client-supplied parameter, so calling this can only ever spend the
-- caller's own budget, never another user's. A null auth.uid() (no request
-- JWT — never true for an actual authenticated RPC call in production,
-- since RLS already requires one everywhere else) is a no-op pass rather
-- than a constraint violation on ops_rate_limits' not-null subject column.
create function ops_check_own_rate_limit(p_function_name text, p_max_calls int, p_window_seconds int)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select case
    when (select auth.uid()) is null then true
    else public.ops_check_rate_limit(p_function_name, (select auth.uid())::text, p_max_calls, p_window_seconds)
  end;
$$;

revoke all on function ops_check_own_rate_limit(text, int, int) from public;
grant execute on function ops_check_own_rate_limit(text, int, int) to authenticated;

-- ============================================================================
-- capture_transaction — same 20/minute threshold, now via the shared
-- limiter instead of its own count(*) over transactions (which also had no
-- supporting index). Body otherwise byte-identical to
-- 20260822100000_unmapped_capture_lands_locally.sql.
-- ============================================================================

create or replace function public.capture_transaction(
  p_id uuid, p_card_identifier text, p_merchant_raw text, p_merchant_normalized text, p_amount_e4 bigint,
  p_occurred_at timestamptz, p_external_id text, p_notes text default null
)
returns table(mapped boolean, account_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_account_id uuid;
  v_currency text;
  v_category_id uuid;
begin
  if not public.ops_check_own_rate_limit('capture_transaction', 20, 60) then
    raise exception 'capture rate limit exceeded';
  end if;

  insert into public.card_mappings (owner_id, card_identifier)
  values (v_owner, p_card_identifier)
  on conflict (owner_id, card_identifier) do nothing;

  select cm.account_id into v_account_id
  from public.card_mappings cm
  where cm.owner_id = v_owner and cm.card_identifier = p_card_identifier;

  if v_account_id is not null then
    select a.currency into v_currency from public.accounts a where a.id = v_account_id;
  end if;

  v_category_id := public.resolve_category_for_merchant(v_owner, p_merchant_normalized, 'expense');

  insert into public.transactions (
    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, notes, source, status, external_id, card_identifier
  ) values (
    p_id, v_owner, v_owner, v_account_id, v_category_id, -abs(p_amount_e4), v_currency, p_occurred_at,
    p_merchant_raw, p_merchant_normalized, p_notes, 'capture', 'pending', p_external_id, p_card_identifier
  );

  return query select (v_account_id is not null), v_account_id;
end;
$$;

revoke all on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text) from public;
grant execute on function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text) to authenticated;

-- ============================================================================
-- pull_changes — the audit's own "the expensive one": unpaginated,
-- aggregates every syncable table with jsonb_agg. No longer `stable` — a
-- rate-limit check has a side effect (the counter row), which `stable`
-- promises this function doesn't have. Body otherwise byte-identical to
-- 20260819100000_remove_fi_add_account_appearance.sql (the latest
-- redefinition — post fi_settings removal, post the fx_rates.rate_to_eur
-- JSON-string fix).
-- ============================================================================

create or replace function public.pull_changes(p_cursor bigint default 0, p_global_cursor bigint default 0)
returns table (payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
language plpgsql
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  if not public.ops_check_own_rate_limit('pull_changes', 30, 60) then
    raise exception 'rate limit exceeded';
  end if;

  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());

  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.sync_seq > p_cursor), '[]'::jsonb),
    'transactions', coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where t.sync_seq > p_cursor), '[]'::jsonb),
    'balance_snapshots', coalesce((select jsonb_agg(to_jsonb(bs)) from public.balance_snapshots bs where bs.sync_seq > p_cursor), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(to_jsonb(c)) from public.categories c where c.sync_seq > p_cursor), '[]'::jsonb),
    'currencies', coalesce((select jsonb_agg(to_jsonb(cur)) from public.currencies cur where cur.sync_seq > p_global_cursor), '[]'::jsonb),
    'fx_rates', coalesce((
      select jsonb_agg(to_jsonb(fr) || jsonb_build_object('rate_to_eur', fr.rate_to_eur::text))
      from public.fx_rates fr where fr.sync_seq > p_global_cursor
    ), '[]'::jsonb),
    'budgets', coalesce((select jsonb_agg(to_jsonb(bud)) from public.budgets bud where bud.sync_seq > p_cursor), '[]'::jsonb),
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

-- ============================================================================
-- create_invite / accept_invite — each sends a household-lifecycle
-- notification (notify_household); an unbounded loop of either is free
-- spam. Bodies otherwise byte-identical to
-- 20260810100000_household_lifecycle.sql / 20260816100000_sync_primitives.sql.
-- ============================================================================

create or replace function create_invite()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_token text;
begin
  if not public.ops_check_own_rate_limit('create_invite', 10, 60) then
    raise exception 'rate limit exceeded';
  end if;

  if v_household_id is null then
    raise exception 'create a household before inviting a member';
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');

  insert into public.household_invites (household_id, invited_by, token_hash, expires_at)
  values (
    v_household_id, (select auth.uid()), encode(extensions.digest(v_token, 'sha256'), 'hex'), now() + interval '7 days'
  );

  return v_token;
end;
$$;

revoke all on function create_invite() from public;
grant execute on function create_invite() to authenticated;

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
  if not public.ops_check_own_rate_limit('accept_invite', 10, 60) then
    raise exception 'rate limit exceeded';
  end if;

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

-- ============================================================================
-- log_export — body otherwise byte-identical to
-- 20260809100000_csv_import_export.sql.
-- ============================================================================

create or replace function log_export(p_account_ids uuid[], p_row_count int)
returns export_audit_log
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result public.export_audit_log;
begin
  if not public.ops_check_own_rate_limit('log_export', 10, 60) then
    raise exception 'rate limit exceeded';
  end if;

  insert into public.export_audit_log (owner_id, account_ids, row_count)
  values ((select auth.uid()), p_account_ids, p_row_count)
  returning * into v_result;
  return v_result;
end;
$$;

revoke all on function log_export(uuid[], int) from public;
grant execute on function log_export(uuid[], int) to authenticated;
