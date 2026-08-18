-- Wave 3 of the Supabase Advisor remediation (see keepo-security-remediation-plan.md).
-- Two independent, low-risk cleanups: revoke PUBLIC's default EXECUTE
-- grant from every function that still carries it, and pin search_path on
-- the seven SECURITY INVOKER functions that were missing it.

-- ----------------------------------------------------------------------------
-- Part A — revoke PUBLIC's default EXECUTE grant.
--
-- Postgres grants EXECUTE to PUBLIC automatically on every new function
-- unless a `revoke` explicitly takes it away. 21 functions in this schema
-- never got that revoke (confirmed against pg_proc.proacl on the live
-- database, not just the migration source).
--
-- 19 of the 21 are `returns trigger` — bump_version, check_transfer_
-- integrity, enforce_household_member_cap, handle_new_user, next_
-- occurrence_date, normalize_budget_period_month, prevent_default_
-- category_deletion, prevent_owner_id_change, set_csv_import_batch_owner,
-- set_updated_at, the six stamp_sync_seq_* functions, and the two
-- trigger_fx_backfill_* functions. Confirmed empirically (not assumed):
-- `select public.bump_version()` fails with "trigger functions can only be
-- called as triggers" even as postgres, superuser, with no RLS or grant
-- involved — Postgres itself refuses the call at the language level.
-- Revoking PUBLIC's grant here removes a permission nobody could ever have
-- exercised; it does not change trigger behavior, since triggers are
-- authorized when CREATE TRIGGER runs, not on each firing.
--
-- The other 2 are plain functions genuinely reachable via PostgREST:
--   - pull_changes: SECURITY INVOKER, already correctly granted to
--     authenticated + service_role — RLS filters its own output, so an
--     anon call already returns nothing useful. Revoking PUBLIC removes
--     the pointless anon-callable surface without touching the grant the
--     app actually uses.
--   - sync_global_domain: immutable SQL, returns a fixed reference uuid,
--     already granted to postgres/authenticated/service_role. Same
--     reasoning — revoke PUBLIC, keep the real grants.
--
-- ensure_user_bootstrap is handled separately below: it's the one
-- genuinely dangerous case, a plain `returns void` function an anonymous
-- caller really can invoke (it fails on a NOT NULL violation with no
-- signed-in auth.uid(), but that's still an unauthenticated write
-- attempt reaching the database).
-- ----------------------------------------------------------------------------

revoke all on function public.bump_version() from public;
revoke all on function public.check_transfer_integrity() from public;
revoke all on function public.enforce_household_member_cap() from public;
revoke all on function public.handle_new_user() from public;
revoke all on function public.next_occurrence_date(date, recurring_frequency) from public;
revoke all on function public.normalize_budget_period_month() from public;
revoke all on function public.prevent_default_category_deletion() from public;
revoke all on function public.prevent_owner_id_change() from public;
revoke all on function public.set_csv_import_batch_owner() from public;
revoke all on function public.set_updated_at() from public;
revoke all on function public.stamp_sync_seq_account() from public;
revoke all on function public.stamp_sync_seq_global() from public;
revoke all on function public.stamp_sync_seq_household() from public;
revoke all on function public.stamp_sync_seq_household_ref() from public;
revoke all on function public.stamp_sync_seq_owner() from public;
revoke all on function public.stamp_sync_seq_profile() from public;
revoke all on function public.trigger_fx_backfill_on_base_currency_change() from public;
revoke all on function public.trigger_fx_backfill_on_new_account_currency() from public;

revoke all on function public.pull_changes(bigint, bigint) from public, anon;
grant execute on function public.pull_changes(bigint, bigint) to authenticated;

revoke all on function public.sync_global_domain() from public, anon;
grant execute on function public.sync_global_domain() to postgres, authenticated, service_role;

-- No internal caller (SQL or Swift) ever invokes ensure_user_bootstrap();
-- the only other functions historically named alongside it
-- (handle_new_user) do their own seeding inline rather than calling it.
-- It's kept callable by a signed-in user as a self-service repair path —
-- idempotent (every insert is ON CONFLICT DO NOTHING) and scoped entirely
-- to auth.uid()'s own rows — but no longer by anon, which had no
-- legitimate reason to reach it and could only ever hit a NOT NULL
-- violation on a null auth.uid() today.
revoke all on function public.ensure_user_bootstrap() from public, anon;
grant execute on function public.ensure_user_bootstrap() to authenticated;

-- ----------------------------------------------------------------------------
-- Part B — pin search_path on the seven SECURITY INVOKER functions that
-- were missing it. Real risk here is low: this matters most for
-- SECURITY DEFINER functions (a caller-controlled search_path could
-- shadow a table/function the DEFINER body calls unqualified), and every
-- one of those in this schema already pins it, enforced by
-- supabase/tests/01_grants_rls.sql's own assertion. These seven are
-- ordinary invoker functions with no elevated rights to steal — this is
-- consistency with the rule the codebase already follows everywhere else,
-- not a live escalation fix. Each body already uses fully-qualified names
-- or built-ins, so pinning changes nothing about behavior.
-- ----------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.prevent_owner_id_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.owner_id is distinct from old.owner_id then
    raise exception 'owner_id is immutable; use the household fork/leave path to reassign ownership';
  end if;
  return new;
end;
$$;

create or replace function public.bump_version()
returns trigger
language plpgsql
set search_path = ''
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

create or replace function public.prevent_default_category_deletion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.is_default and new.deleted_at is not null then
      raise exception 'this category cannot be deleted';
    end if;
    if new.is_default and new.name <> old.name then
      raise exception 'this category cannot be renamed';
    end if;
  end if;
  if not new.is_default and lower(trim(new.name)) in ('other', 'others') then
    raise exception 'this category name is reserved';
  end if;
  return new;
end;
$$;

create or replace function public.enforce_household_member_cap()
returns trigger
language plpgsql
set search_path = ''
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

create or replace function public.normalize_budget_period_month()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.period_month := date_trunc('month', new.period_month)::date;
  return new;
end;
$$;

-- next_occurrence_date is `immutable`, not a trigger — CREATE OR REPLACE
-- FUNCTION can change an immutable function's body freely (no dependent
-- index or generated column relies on this one; confirmed no index or
-- generated column definition in the schema references it), so no drop is
-- needed the way update_account's signature change once required one.
create or replace function public.next_occurrence_date(p_date date, p_frequency recurring_frequency)
returns date
language sql
immutable
set search_path = ''
as $$
  select case p_frequency
    when 'weekly' then p_date + interval '7 days'
    when 'monthly' then p_date + interval '1 month'
    when 'yearly' then p_date + interval '1 year'
  end::date;
$$;
