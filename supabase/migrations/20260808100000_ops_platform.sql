-- Phase 13: ops platform — scheduling, health, alerting. `pg_net` and
-- `supabase_vault` are preloaded/installed already; `pg_cron` is available
-- but not yet created, so this migration is the one that turns it on.
--
-- Real secret VALUES are never committed here — `vault.create_secret` calls
-- with real values belong in a superuser session against each environment
-- (local: `supabase/seed.sql`, which only ever runs against the local
-- stack; hosted: a one-time manual `vault.create_secret` call, same
-- mechanism Phase 4's log already called out for `FX_SYNC_SECRET`). Every
-- function here that needs a secret degrades to an `ops_events` error log
-- entry, never a crash, when the secret hasn't been provisioned yet.

create extension if not exists pg_cron;

-- ============================================================================
-- ops_events — RLS on, no policies (spec: nothing readable by `authenticated`
-- at all; this is an ops-only surface). No PII, ever: ids and codes only,
-- never merchant names, amounts, or email addresses — enforced by
-- convention (there is no PII-typed column to put here in the first place).
-- ============================================================================

create type ops_event_level as enum ('info', 'warning', 'error');

create table ops_events (
  id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default now(),
  source text not null,
  level ops_event_level not null,
  code text not null,
  detail jsonb
);

alter table ops_events enable row level security;
grant select, insert on ops_events to service_role;

create index ops_events_occurred_at_idx on ops_events (occurred_at);
create index ops_events_level_occurred_idx on ops_events (level, occurred_at);

-- ============================================================================
-- ops_rate_limits — a fixed-window counter, reusable by every Edge Function
-- (spec: rate limiting on every Edge Function and the ingestion path — the
-- capture path already has its own SQL-side guard from Phase 12; this is
-- the shared mechanism for sync-fx-rates/alert-operator and any future
-- Edge Function).
-- ============================================================================

create table ops_rate_limits (
  function_name text primary key,
  window_started_at timestamptz not null default now(),
  count int not null default 0
);

alter table ops_rate_limits enable row level security;
grant select, insert, update on ops_rate_limits to service_role;

create function ops_check_rate_limit(p_function_name text, p_max_calls int, p_window_seconds int)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.ops_rate_limits;
begin
  insert into public.ops_rate_limits (function_name) values (p_function_name)
  on conflict (function_name) do nothing;

  select * into v_row from public.ops_rate_limits where function_name = p_function_name for update;

  if now() - v_row.window_started_at > (p_window_seconds || ' seconds')::interval then
    update public.ops_rate_limits set window_started_at = now(), count = 1
    where function_name = p_function_name;
    return true;
  end if;

  if v_row.count >= p_max_calls then
    return false;
  end if;

  update public.ops_rate_limits set count = count + 1 where function_name = p_function_name;
  return true;
end;
$$;

revoke all on function ops_check_rate_limit(text, int, int) from public;
grant execute on function ops_check_rate_limit(text, int, int) to service_role;

-- ============================================================================
-- ops_http_post — the one place any SQL caller (a cron job, a trigger) makes
-- an authenticated HTTP call to one of this project's own Edge Functions.
-- Looks up both the target URL and the auth secret from Vault by name;
-- logs to ops_events and returns without raising if either is missing,
-- so a not-yet-provisioned secret degrades to a visible ops log entry
-- rather than breaking the cron job that called it (and every OTHER
-- statement in the same scheduled call, if it were allowed to raise).
-- ============================================================================

create function ops_http_post(p_url_secret text, p_auth_secret text, p_auth_header text, p_body jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_auth text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = p_url_secret;
  select decrypted_secret into v_auth from vault.decrypted_secrets where name = p_auth_secret;

  if v_url is null or v_auth is null then
    insert into public.ops_events (source, level, code, detail)
    values ('ops_http_post', 'error', 'missing_vault_secret', jsonb_build_object('url_secret', p_url_secret));
    return;
  end if;

  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', p_auth_header, v_auth),
    body := p_body
  );
end;
$$;

revoke all on function ops_http_post(text, text, text, jsonb) from public;
grant execute on function ops_http_post(text, text, text, jsonb) to service_role;

-- ============================================================================
-- Health — derived from data, never job status (spec). Each check function
-- is independently callable; `ops_health()` is the one aggregator every
-- cron/dashboard caller actually uses.
-- ============================================================================

-- The newest fx_rates row, globally — not per-currency, per the spec's own
-- framing ("is the newest FX rate older than N days"). Healthy trivially
-- when nobody has a non-EUR account or base currency yet — there is
-- nothing to be stale about. 4 days, not the naive 2, because Frankfurter/
-- ECB doesn't publish on weekends and the freshness check itself must not
-- flap red every Saturday.
create function fx_freshness_check(p_max_age_days int default 4)
returns table (healthy boolean, newest_rate_date date)
language sql
security invoker
stable
set search_path = ''
as $$
  select
    coalesce(max(rate_date) >= current_date - p_max_age_days, false)
      or not exists (
        select 1 from public.accounts where currency <> 'EUR' and deleted_at is null
        union
        select 1 from public.profiles where base_currency is not null and base_currency <> 'EUR'
      ),
    max(rate_date)
  from public.fx_rates;
$$;

revoke all on function fx_freshness_check(int) from public;
grant execute on function fx_freshness_check(int) to service_role;

-- Stub, deliberately: `recurring_rules` doesn't exist until Phase 14.
-- Always healthy (nothing can be overdue if nothing can be scheduled yet).
-- Phase 14 MUST replace this body once the table lands — tracked in
-- keepo-v1-master-plan.md's Phase 14 section, not left to be rediscovered.
create function recurring_materialization_check()
returns table (healthy boolean, detail text)
language sql
security invoker
stable
as $$
  select true, 'no recurring_rules table yet (Phase 14)';
$$;

revoke all on function recurring_materialization_check() from public;
grant execute on function recurring_materialization_check() to service_role;

create function ops_health()
returns table (check_name text, healthy boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  select 'fx_freshness'::text, f.healthy, 'newest_rate_date=' || coalesce(f.newest_rate_date::text, 'none')
  from public.fx_freshness_check() f;

  return query
  select 'recurring_materialization'::text, r.healthy, r.detail
  from public.recurring_materialization_check() r;

  return query
  select
    'heartbeat'::text,
    exists (
      select 1 from public.ops_events
      where code = 'heartbeat' and occurred_at > now() - interval '30 minutes'
    ),
    'no heartbeat in the last 30 minutes means the alerting itself broke, not that everything is fine';

  return query
  select
    'error_events_24h'::text,
    (select count(*) from public.ops_events where level = 'error' and occurred_at > now() - interval '24 hours') = 0,
    (select count(*)::text from public.ops_events where level = 'error' and occurred_at > now() - interval '24 hours')
      || ' error-level ops_events in the last 24h';
end;
$$;

revoke all on function ops_health() from public;
grant execute on function ops_health() to service_role;

-- ============================================================================
-- 400-day FX backfill — async via pg_net, never inline (spec). The 400-day
-- FLOOR (not an exact window) is what makes a repeated trigger idempotent:
-- sync-fx-rates recomputes currencies-in-use itself and re-upserts whatever
-- it fetches, so overlapping backfills for an already-covered currency are
-- wasted work, never a correctness problem (`upsert_fx_rate`'s own
-- later-fetched_at-wins rule already handles that).
-- ============================================================================

create function request_fx_backfill()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.ops_http_post('fx_sync_url', 'fx_sync_secret', 'X-Fx-Sync-Secret', jsonb_build_object('days', 400));
end;
$$;

revoke all on function request_fx_backfill() from public;

create function trigger_fx_backfill_on_new_account_currency()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.currency <> 'EUR' and not exists (select 1 from public.fx_rates where currency = new.currency) then
    perform public.request_fx_backfill();
  end if;
  return new;
end;
$$;

create trigger accounts_backfill_fx_on_new_currency
  after insert on accounts
  for each row execute function trigger_fx_backfill_on_new_account_currency();

create function trigger_fx_backfill_on_base_currency_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.base_currency is not null and new.base_currency <> 'EUR'
     and new.base_currency is distinct from old.base_currency then
    perform public.request_fx_backfill();
  end if;
  return new;
end;
$$;

create trigger profiles_backfill_fx_on_base_currency_change
  after update on profiles
  for each row execute function trigger_fx_backfill_on_base_currency_change();

-- ============================================================================
-- ops_check_and_alert — the one function the alerting cron job calls.
-- Silent when everything's healthy; forwards the full check list to
-- alert-operator only when something isn't (the Edge Function itself
-- decides what a human actually sees).
-- ============================================================================

create function ops_check_and_alert()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_checks jsonb;
  v_any_unhealthy boolean;
begin
  select jsonb_agg(jsonb_build_object('check_name', check_name, 'healthy', healthy, 'detail', detail)),
         bool_or(not healthy)
  into v_checks, v_any_unhealthy
  from public.ops_health();

  if v_any_unhealthy then
    perform public.ops_http_post(
      'alert_operator_url', 'alert_operator_secret', 'X-Alert-Operator-Secret', jsonb_build_object('checks', v_checks)
    );
  end if;
end;
$$;

revoke all on function ops_check_and_alert() from public;

-- ============================================================================
-- Schedules. All four run as `postgres` via pg_cron (the local/hosted
-- superuser role migrations already run as) — no separate cron-specific
-- role needed.
-- ============================================================================

-- The daily sync-fx-rates run, overdue since Phase 4.
select cron.schedule(
  'sync-fx-rates-daily', '0 4 * * *',
  $$select public.ops_http_post('fx_sync_url', 'fx_sync_secret', 'X-Fx-Sync-Secret', '{}'::jsonb)$$
);

-- Heartbeat — "silence means the alerting itself broke," not "everything's
-- fine." A gap the ops_health() heartbeat check above is watching for.
select cron.schedule(
  'ops-heartbeat', '*/15 * * * *',
  $$insert into public.ops_events (source, level, code) values ('ops-heartbeat', 'info', 'heartbeat')$$
);

-- The health-check-and-alert loop itself.
select cron.schedule('ops-check-and-alert', '*/30 * * * *', $$select public.ops_check_and_alert()$$);

-- 30-day prune (spec).
select cron.schedule(
  'ops-events-prune', '0 3 * * *',
  $$delete from public.ops_events where occurred_at < now() - interval '30 days'$$
);
