-- Phase 10: Needs Review inbox. `needs_review` is a VIEW with a stable
-- column contract (kind, item_id, account_id, occurred_at, title, subtitle,
-- amount, currency) — every later phase (12/14/18/19) appends its own
-- UNION ALL branch without ever changing the client decoder. Two branches
-- ship here: unresolved sync_conflicts, and accounts overdue for
-- reconciliation ("reconciliation gaps" — a stale account is exactly the
-- gap the ritual exists to close, and it deserves a place in the one inbox
-- alongside every other kind of thing needing attention, independent of
-- whether it also happens to trigger Home's banner).

create index sync_conflicts_owner_resolved_idx on sync_conflicts (owner_id, resolved_at);

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
where a.is_stale and a.archived_at is null;

grant select on needs_review to authenticated, service_role;

-- ============================================================================
-- resolve_sync_conflict — the only writer of sync_conflicts.resolved_at.
-- Idempotent: resolving an already-resolved conflict is a no-op, not an
-- error, so a client retry (e.g. after a dropped connection) can't fail on
-- the second attempt. Raises only when the row doesn't exist or isn't the
-- caller's — same "not found or not accessible" shape as every other
-- write RPC in this codebase, never leaking whether the id exists for a
-- different owner.
-- ============================================================================

create function resolve_sync_conflict(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner from public.sync_conflicts where id = p_id;

  if v_owner is null or v_owner <> (select auth.uid()) then
    raise exception 'sync conflict not found or not accessible';
  end if;

  update public.sync_conflicts
  set resolved_at = coalesce(resolved_at, now())
  where id = p_id;
end;
$$;

revoke all on function resolve_sync_conflict(uuid) from public;
grant execute on function resolve_sync_conflict(uuid) to authenticated;
