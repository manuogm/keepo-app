-- unmap_card/rename_card_mapping used to be keyed by card_mappings.id — the
-- one write pair in this table's whole surface that wasn't. Every other
-- write here (map_card, capture_transaction, link_card_to_account) resolves
-- by the table's real identity, (owner_id, card_identifier); id is always
-- server-generated, no RPC ever lets a client choose it.
--
-- That mismatch is what actually produced "P0001: card mapping not found or
-- not accessible" on retry, permanently, no matter how many times the
-- outbox drained: the local mirror's write-through (`linkCardLocally`)
-- can't know the server's real id for a card before its first sync pull, so
-- when it needs to create a row optimistically it invents a fresh client
-- UUID. If the server already had its own row for that card (from an
-- earlier capture, before this device's mirror ever pulled it down), the
-- local row exists under an id the server has never heard of — every write
-- keyed by that id fails "not found" forever, since the id itself, not the
-- network, is wrong. Resolving by natural key instead makes both RPCs
-- immune to this by construction, exactly like every sibling write here
-- already is.

drop function if exists public.unmap_card(uuid);

create function public.unmap_card(p_card_identifier text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.card_mappings
  set deleted_at = now()
  where owner_id = (select auth.uid()) and card_identifier = p_card_identifier and deleted_at is null;

  if not found then
    raise exception 'card mapping not found or not accessible';
  end if;
end;
$$;

revoke all on function public.unmap_card(text) from public;
grant execute on function public.unmap_card(text) to authenticated;

drop function if exists public.rename_card_mapping(uuid, text);

create function public.rename_card_mapping(p_old_card_identifier text, p_new_card_identifier text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.card_mappings
  set card_identifier = p_new_card_identifier, updated_at = now()
  where owner_id = (select auth.uid()) and card_identifier = p_old_card_identifier and deleted_at is null;

  if not found then
    raise exception 'card mapping not found or not accessible';
  end if;
end;
$$;

revoke all on function public.rename_card_mapping(text, text) from public;
grant execute on function public.rename_card_mapping(text, text) to authenticated;

-- needs_review: the ambiguous_card branch has set subtitle to null since
-- this view was last rewritten, but MapCardSheet.swift (the only UI that
-- resolves this item kind) reads item.subtitle as the raw card_identifier
-- to pass to map_card — a real, silent bug: the "Map Card" sheet's Card
-- section never rendered anything, and its checkmark button's own guard
-- (`guard let cardIdentifier = item.subtitle`) failed every single time,
-- so tapping it always did nothing, independent of anything else fixed in
-- this migration. Restoring subtitle to the raw identifier fixes the
-- actual read; title drops the concatenation since it's now redundant
-- with subtitle.
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
  null::bigint as amount_e4,
  null::text as currency
from card_mappings cm
where cm.account_id is null
  and cm.deleted_at is null
  and not exists (
    select 1 from transactions t2
    where t2.owner_id = cm.owner_id and t2.card_identifier = cm.card_identifier
      and t2.source = 'capture' and t2.status = 'pending' and t2.deleted_at is null
  )
union all
select
  'csv_import_candidate'::text as kind,
  ic.id as item_id,
  ic.account_id,
  ic.occurred_at,
  'Import row — ' || coalesce(ic.merchant_raw, 'no description') as title,
  case when ic.matched_transaction_id is not null then 'Possible duplicate of an existing transaction' else null end
    as subtitle,
  ic.amount_e4,
  ic.currency
from csv_import_candidates ic
where ic.status = 'pending';

grant select on needs_review to authenticated, service_role;
