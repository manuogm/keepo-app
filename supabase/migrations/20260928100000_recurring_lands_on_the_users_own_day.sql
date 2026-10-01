-- ============================================================================
-- A recurring transaction lands on the day the user actually chose.
--
-- `materialize_recurring` inserted `v_occurrence::timestamptz`. A `date` cast
-- to `timestamptz` is midnight **in the session's TimeZone**, which for the
-- cron job is UTC — so a rule due on the 20th was stored as
-- `2026-09-20 00:00:00+00`. The ledger groups by the *device's* calendar, so
-- for every user west of UTC that instant is the evening of the 19th and the
-- row rendered a day early. True of expense rules since Phase 14; the
-- transfer pair added in 20260927100000 inherited it.
--
-- **There is no single UTC time-of-day that fixes this.** Real offsets span
-- UTC-11..UTC+14 — twenty-six hours, wider than a day — so any fixed instant
-- is the wrong calendar date for somebody. Shifting to noon UTC, the obvious
-- one-line "fix", would correct the Americas and break New Zealand, Fiji,
-- Tonga, Samoa and Kiribati, which are correct today. Trading a western bug
-- for an eastern one is not a fix.
--
-- So the rule's owner has to say which calendar they mean, and the occurrence
-- is stored at **their local midnight**. That is also what makes a recurring
-- row behave exactly like a hand-entered one dated the same day: the
-- transaction form already sends a real local instant, and until now a
-- materialized row was the only thing in `transactions` carrying a
-- zone-less date pretending to be one.
--
-- Historical rows are corrected too, by `realign_recurring_occurrences()` —
-- see its own header for why it is client-triggered rather than run here.
-- ============================================================================

-- ============================================================================
-- profiles.time_zone — an IANA name, defaulting to UTC.
--
-- Defaulting to UTC rather than to null keeps `materialize_recurring`'s
-- arithmetic total and makes the pre-existing behaviour the default: a
-- profile that never reports a zone materializes exactly where it does today.
-- ============================================================================

alter table profiles add column time_zone text not null default 'UTC';

comment on column profiles.time_zone is
  'IANA zone name (e.g. America/Chicago) the client reports for this device. '
  'Decides which calendar a recurring rule''s date means. Defaults to UTC, '
  'which reproduces the pre-20260928100000 behaviour exactly.';

-- A bad zone name is not a cosmetic problem: `at time zone 'Garbage'` raises,
-- and inside `materialize_recurring`'s loop that would abort the nightly job
-- for **every** user over one profile's bad write. Validated here so it
-- cannot land, and separately tolerated in the job itself (see
-- `safe_time_zone`) so an entry removed from a future tzdb still cannot take
-- materialization down. Defence in depth, and the job's half is the
-- load-bearing one.
create function validate_profile_time_zone()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- The only exact test for "does Postgres know this zone" is to use it.
  -- `pg_timezone_names` is a view that enumerates the whole tz database on
  -- every scan; this costs a subtransaction and nothing else.
  perform ('2000-01-01'::timestamp at time zone new.time_zone);
  return new;
exception when others then
  raise exception 'not a known IANA time zone: %', new.time_zone;
end;
$$;

revoke all on function validate_profile_time_zone() from public;

create trigger profiles_validate_time_zone
  before insert or update of time_zone on profiles
  for each row execute function validate_profile_time_zone();

-- `profiles`' UPDATE grant is column-scoped (S-06,
-- 20260827100000_close_direct_write_gaps.sql): a client may set
-- `base_currency`/`onboarded_at`/`display_name`/`avatar_path` and nothing
-- else, because a raw PATCH on `sync_epoch` would let a removed household
-- member suppress the local wipe that revokes their offline copy of a shared
-- account.
--
-- `time_zone` joins that whitelist. It gates access to nothing — it decides
-- which calendar the user's own dates are rendered against — it is
-- trigger-validated above, and `profiles_update`'s `id = auth.uid()` still
-- decides whose row is being written. The columns S-06 exists to protect stay
-- exactly as closed as they were.
grant update (time_zone) on profiles to authenticated;

-- ============================================================================
-- safe_time_zone — a zone name that `at time zone` is guaranteed to accept.
--
-- Exists so one unusable value cannot abort a whole nightly run. Written with
-- an exception handler rather than a lookup against `pg_timezone_names`
-- because that view materializes the entire tz database per scan, and this is
-- called once per due rule.
-- ============================================================================

create function safe_time_zone(p_name text)
returns text
language plpgsql
stable
set search_path = ''
as $$
begin
  perform ('2000-01-01'::timestamp at time zone p_name);
  return p_name;
exception when others then
  return 'UTC';
end;
$$;

revoke all on function safe_time_zone(text) from public;
grant execute on function safe_time_zone(text) to authenticated, service_role;

-- ============================================================================
-- materialize_recurring — unchanged except for the instant it stores.
--
-- `v_occurrence::timestamp at time zone v_tz` reads as "midnight on that date,
-- in that zone", and yields the `timestamptz` that actually is. Contrast the
-- old `v_occurrence::timestamptz`, which is "midnight on that date, in
-- whatever zone this session happens to be set to" — the bug.
-- ============================================================================

create or replace function public.materialize_recurring(p_through date default current_date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule record;
  v_occurrence date;
  v_inserted integer := 0;
  v_group uuid;
  v_to_currency text;
  v_tz text;
  v_at timestamptz;
begin
  for v_rule in
    select * from public.recurring_rules where active and next_due_at <= p_through
    order by id
    for update
  loop
    v_occurrence := v_rule.next_due_at;
    v_to_currency := null;

    -- The rule's owner, not the caller: this runs as a cron job with no
    -- `auth.uid()` at all, and each rule in the loop can belong to somebody
    -- different.
    select public.safe_time_zone(p.time_zone) into v_tz
    from public.profiles p where p.id = v_rule.owner_id;
    v_tz := coalesce(v_tz, 'UTC');

    if v_rule.to_account_id is not null then
      select currency into v_to_currency from public.accounts where id = v_rule.to_account_id;
    end if;

    while v_occurrence <= p_through loop
      v_at := v_occurrence::timestamp at time zone v_tz;

      if v_rule.to_account_id is null then
        insert into public.transactions (
          id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
          source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id, v_rule.category_id,
          v_rule.amount_e4, v_rule.currency, v_at,
          'recurring', v_rule.id::text || '|' || v_occurrence::text, v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing;

        if found then
          v_inserted := v_inserted + 1;
        end if;
      else
        v_group := gen_random_uuid();

        insert into public.transactions (
          id, owner_id, created_by, account_id, amount_e4, currency, occurred_at,
          transfer_group_id, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id,
          v_rule.amount_e4, v_rule.currency, v_at,
          v_group, 'recurring', v_rule.id::text || '|' || v_occurrence::text || '|from', v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing;

        if found then
          v_inserted := v_inserted + 1;
        end if;

        insert into public.transactions (
          id, owner_id, created_by, account_id, amount_e4, currency, occurred_at,
          transfer_group_id, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.to_account_id,
          -v_rule.amount_e4, v_to_currency, v_at,
          v_group, 'recurring', v_rule.id::text || '|' || v_occurrence::text || '|to', v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing;

        if found then
          v_inserted := v_inserted + 1;
        end if;
      end if;

      v_occurrence := public.next_occurrence_date(v_occurrence, v_rule.frequency);
    end loop;

    update public.recurring_rules
    set next_due_at = v_occurrence, last_materialized_at = p_through
    where id = v_rule.id;
  end loop;

  return v_inserted;
end;
$$;

revoke all on function public.materialize_recurring(date) from public;
grant execute on function public.materialize_recurring(date) to service_role;

-- ============================================================================
-- realign_recurring_occurrences — fixes what is already stored.
--
-- **Not run by this migration, and that is the point.** At migration time
-- every profile's `time_zone` is still the 'UTC' default, because only a
-- client can report a device's zone — so a backfill here would be a no-op for
-- everybody and would then be unrepeatable. The client calls this once, right
-- after it first writes a zone that differs from what is stored.
--
-- **It only touches rows it would visibly move**, which is what makes it both
-- minimal and idempotent:
--
--   * `source = 'recurring'` — nothing hand-entered or captured ever carried
--     the zone-less convention, and their instants are real.
--   * still at exact UTC midnight — the old convention's signature. A row
--     already written by the fixed `materialize_recurring` is at the owner's
--     local midnight and is skipped unless that IS UTC midnight, in which
--     case moving it is a no-op anyway.
--   * and whose stored instant renders as a *different* local date than the
--     one intended. For a user east of UTC that set is empty, so they get no
--     row churn and no FX-date shift for a display that was already right.
--
-- Returns the number of rows moved, so the client can log it and so a second
-- call visibly returns 0.
-- ============================================================================

create function realign_recurring_occurrences()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_tz text;
  v_moved integer;
begin
  if v_me is null then
    raise exception 'not signed in';
  end if;

  select public.safe_time_zone(p.time_zone) into v_tz from public.profiles p where p.id = v_me;
  v_tz := coalesce(v_tz, 'UTC');

  with candidate as (
    select t.id, (t.occurred_at at time zone 'UTC')::date as utc_day
    from public.transactions t
    where t.owner_id = v_me
      and t.source = 'recurring'
      and t.deleted_at is null
      -- Exactly UTC midnight: the signature of the old convention.
      and t.occurred_at = ((t.occurred_at at time zone 'UTC')::date::timestamp at time zone 'UTC')
      -- ...and currently rendering as the wrong local day.
      and (t.occurred_at at time zone v_tz)::date
          <> (t.occurred_at at time zone 'UTC')::date
  )
  update public.transactions t
  set occurred_at = c.utc_day::timestamp at time zone v_tz
  from candidate c
  where t.id = c.id;

  get diagnostics v_moved = row_count;
  return v_moved;
end;
$$;

revoke all on function realign_recurring_occurrences() from public;
grant execute on function realign_recurring_occurrences() to authenticated;
