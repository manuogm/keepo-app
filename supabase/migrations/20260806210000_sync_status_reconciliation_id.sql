-- accounts_sync_status needs the actual last reconciliation id, not just its
-- timestamp — the client passes it straight back as
-- p_expected_last_reconciliation_id, the concurrency guard reconcile_*
-- account() checks against. Missed when the view was first written
-- (20260806200000); appended at the end per the established "CREATE OR
-- REPLACE VIEW can't reorder or insert columns mid-list" convention.

create or replace view accounts_sync_status
with (security_invoker = true) as
select
  a.account_id,
  a.name,
  a.kind,
  a.subtype,
  a.currency,
  a.minor_unit,
  a.balance,
  a.include_in_total,
  a.archived_at,
  coalesce(r.last_verified_at, acc.created_at) as last_verified_at,
  account_staleness(a.subtype, coalesce(r.last_verified_at, acc.created_at)) as is_stale,
  r.last_reconciliation_id
from accounts_with_balances a
join accounts acc on acc.id = a.account_id
left join (
  select distinct on (account_id) account_id, id as last_reconciliation_id, created_at as last_verified_at
  from reconciliations
  order by account_id, created_at desc
) r on r.account_id = a.account_id;

grant select on accounts_sync_status to authenticated, service_role;
