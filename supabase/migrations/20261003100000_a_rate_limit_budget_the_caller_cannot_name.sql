-- A rate-limit budget the caller cannot name.
--
-- Found by the security audit of 2026-09-21, and confirmed with a working
-- exploit before this was written.
--
-- `ops_check_own_rate_limit(function_name, max_calls, window_seconds)` was
-- granted `EXECUTE` to `authenticated`, which meant the *caller* named the
-- budget. The counter underneath resets its window whenever
-- `now() - window_started_at > p_window_seconds`, so naming a window of
-- zero resets your own counter on demand:
--
--   select ops_check_own_rate_limit('preview_invite', 1, 0);   -- window reset
--   select preview_invite('...');                              -- allowed again
--
-- Measured against the live stack: the `preview_invite` budget (20/60s) was
-- exhausted and confirmed blocked, then 30 of 30 further calls were let
-- through by interleaving that reset. Every limit built on this helper —
-- `accept_invite`, `apply_category_merges`, `capture_transaction`,
-- `create_invite`, `log_export`, `preview_invite`, `pull_changes` — was
-- bypassable the same way. Invite tokens are 128-bit so this was never a
-- token-guessing path; it is an abuse and cost-control bypass, and it
-- compounds anything else that leans on a limit to stay affordable.
--
-- **Why this is not simply a revoke.** Six of the seven callers are
-- SECURITY DEFINER owned by `postgres`, and keep their EXECUTE through the
-- definer's own rights no matter what `authenticated` holds. Those six are
-- trusted server-side code naming a budget for themselves, which is fine
-- and stays exactly as it is — inline, beside the RPC it governs, where it
-- is readable.
--
-- `pull_changes` is the exception and the whole reason this migration is
-- more than one line. It is SECURITY INVOKER *deliberately*: every
-- `where sync_seq > p_cursor` inside it is filtered by RLS as the calling
-- user, and making it a definer to dodge this problem would hand every
-- user the entire table. So it runs as `authenticated` and must still be
-- able to reach the limiter — a blanket revoke would break every sync pull
-- in the app.
--
-- The split below draws the line where the trust actually changes:
--
--   * the 3-argument form is now internal. Name your own budget only if you
--     are running as `postgres`.
--   * a 1-argument overload is the entry point an invoker-mode RPC uses. It
--     takes no budget from anybody; it looks one up. `authenticated` can
--     still call it, and the worst that does is increment the caller's own
--     counter, which is self-limiting rather than a bypass.
--
-- A future SECURITY INVOKER RPC that needs limiting adds a line to the
-- registry. One that reaches for the 3-argument form instead fails loudly
-- with a permission error the first time an ordinary user calls it, which
-- is the failure mode to want.

-- ---------------------------------------------------------------------------
-- 1. Naming your own budget becomes a privilege.
-- ---------------------------------------------------------------------------

revoke execute on function
  public.ops_check_own_rate_limit(text, integer, integer)
  from authenticated;

-- ---------------------------------------------------------------------------
-- 2. The budget registry, for callers that run as the user.
-- ---------------------------------------------------------------------------

create or replace function public.ops_check_own_rate_limit(p_function_name text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max_calls integer;
  v_window_seconds integer;
begin
  -- Deliberately a CASE and not a table: a budget is a constant of the
  -- deployment, changed by migration like any other piece of logic, and a
  -- table would be one more thing to grant, police and keep out of reach of
  -- the very clients this exists to limit.
  case p_function_name
    when 'pull_changes' then
      v_max_calls := 120;
      v_window_seconds := 60;
    else
      -- Unregistered is a programming error, not a request to fall back to
      -- something permissive. Fails on the first call, in tests.
      raise exception 'no rate-limit budget registered for %', p_function_name;
  end case;

  return public.ops_check_own_rate_limit(p_function_name, v_max_calls, v_window_seconds);
end;
$$;

revoke all on function public.ops_check_own_rate_limit(text) from public;
grant execute on function public.ops_check_own_rate_limit(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. `pull_changes` asks for its limit by name only.
--
--    Byte-for-byte the deployed body but for the one line marked below.
-- ---------------------------------------------------------------------------

create or replace function public.pull_changes(p_cursor bigint default 0, p_global_cursor bigint default 0)
returns table(payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
language plpgsql
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  -- Changed 20261003100000: the budget is the server's, not this call's.
  if not public.ops_check_own_rate_limit('pull_changes') then
    raise exception 'rate limit exceeded';
  end if;

  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());
  v_epoch := coalesce(v_epoch, 0);

  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.sync_seq > p_cursor), '[]'::jsonb),
    'transactions', coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where t.sync_seq > p_cursor), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(to_jsonb(c)) from public.categories c where c.sync_seq > p_cursor), '[]'::jsonb),
    'currencies', coalesce((select jsonb_agg(to_jsonb(cur)) from public.currencies cur where cur.sync_seq > p_global_cursor), '[]'::jsonb),
    'fx_rates', coalesce((
      select jsonb_agg(to_jsonb(fr) || jsonb_build_object('units_per_eur', fr.units_per_eur::text))
      from public.fx_rates fr where fr.sync_seq > p_global_cursor
    ), '[]'::jsonb),
    'tags', coalesce((select jsonb_agg(to_jsonb(tg)) from public.tags tg where tg.sync_seq > p_cursor), '[]'::jsonb),
    'transaction_tags', coalesce((select jsonb_agg(to_jsonb(tt)) from public.transaction_tags tt where tt.sync_seq > p_cursor), '[]'::jsonb),
    'recurring_rules', coalesce((select jsonb_agg(to_jsonb(rr)) from public.recurring_rules rr where rr.sync_seq > p_cursor), '[]'::jsonb),
    'recurring_rule_tags', coalesce((select jsonb_agg(to_jsonb(rt)) from public.recurring_rule_tags rt where rt.sync_seq > p_cursor), '[]'::jsonb),
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
    union all select max(sync_seq) from public.categories where sync_seq > p_cursor
    union all select max(sync_seq) from public.tags where sync_seq > p_cursor
    union all select max(sync_seq) from public.transaction_tags where sync_seq > p_cursor
    union all select max(sync_seq) from public.recurring_rules where sync_seq > p_cursor
    union all select max(sync_seq) from public.recurring_rule_tags where sync_seq > p_cursor
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

-- ---------------------------------------------------------------------------
-- 4. Defence in depth: a window of zero is never a legitimate budget.
--
--    Both overloads of the counter itself now refuse one, so the reset can
--    never be reached again even if some future caller is handed numbers it
--    should not have been.
-- ---------------------------------------------------------------------------

create or replace function public.ops_check_rate_limit(p_function_name text, p_max_calls integer, p_window_seconds integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.ops_rate_limits;
begin
  if p_window_seconds is null or p_window_seconds < 1 or p_max_calls is null or p_max_calls < 1 then
    raise exception 'rate limit budget must be at least 1 call per 1 second';
  end if;

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

create or replace function public.ops_check_rate_limit(p_function_name text, p_subject text, p_max_calls integer, p_window_seconds integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.ops_rate_limits;
begin
  if p_window_seconds is null or p_window_seconds < 1 or p_max_calls is null or p_max_calls < 1 then
    raise exception 'rate limit budget must be at least 1 call per 1 second';
  end if;

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
