-- Follow-up to 20260807150000_capture.sql (already pushed — fixing forward
-- with a new migration rather than editing it, per the Phase 9 precedent).
--
-- The client needs the raw card_identifier as a distinct, parseable field
-- to resolve an ambiguous_card item (map_card takes the identifier, not a
-- freeform title string) — putting it only inside the title's display text
-- would force the app to parse UI copy to find it. Moved to `subtitle`
-- instead, and out of `title`, so nothing is shown twice.
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
  'Unmapped card'::text as title,
  cm.card_identifier as subtitle,
  null::numeric(20, 4) as amount,
  null::text as currency
from card_mappings cm
where cm.account_id is null;

grant select on needs_review to authenticated, service_role;
