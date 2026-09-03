-- Tags lose their link to categories. A tag is now **name and nothing else**.
--
-- Product decision, one day after 20260907100000 introduced the link. The
-- category binding bought one rule — "this tag only goes on transactions in
-- that category" — and cost four mechanisms to uphold it: a validation
-- branch in the join's trigger, a cascade that soft-deleted links when a
-- transaction was recategorised, a filtered picker on the client, and a
-- second filtered read. For a label whose whole job is to cut *across*
-- categories, the restriction was working against the feature.
--
-- What this removes:
--   * `tags.category_id` and its composite FK
--   * the category rule inside `set_transaction_tag_derived_columns`
--   * `drop_incompatible_transaction_tags` and its trigger — with no
--     category on a tag, recategorising a transaction can no longer
--     invalidate anything
--
-- What it does **not** change: `can_read_tag`. That function already only
-- tested the shared-account path, with the category path noted as pending
-- the household category-sharing work. Dropping the link doesn't defer that
-- clause any more — it deletes the question. Tag visibility is now, simply
-- and completely: your own tags, plus any tag applied to a transaction on
-- an account shared with you.
--
-- Deploy order: this migration, then the app build whose `LocalSchemaV1` and
-- `SyncApply` whitelist no longer carry `tags.category_id`. An older client
-- keeps sending it and PostgREST rejects the unknown column, so the client
-- must not lag behind this one.

-- ============================================================================
-- The recategorisation cascade goes first: it reads tags.category_id, so it
-- cannot outlive the column.
-- ============================================================================

drop trigger if exists transactions_drop_incompatible_tags on transactions;
drop function if exists drop_incompatible_transaction_tags();

drop index if exists tags_category_idx;

alter table tags drop column category_id;

-- ============================================================================
-- set_transaction_tag_derived_columns — restated in full, minus the category
-- rule. Everything else stands, and the two reasons it exists are unchanged:
--
--   * `owner_id` comes from the transaction, never the client. It has to
--     match for `stamp_sync_seq_owner()` to file the row in the right sync
--     domain; a client-supplied value could put a household member's tagging
--     of a shared transaction in their own domain, where the account owner
--     would never pull it.
--   * A row on its way OUT is not re-validated. `cascade_tag_soft_delete`
--     soft-deletes links for a tag it has already tombstoned, so the lookup
--     below would not find it. Reviving a link still runs the full check.
-- ============================================================================

create or replace function set_transaction_tag_derived_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_txn_owner uuid;
begin
  select owner_id into v_txn_owner
  from public.transactions where id = new.transaction_id;

  if v_txn_owner is null then
    raise exception 'transaction % not found', new.transaction_id;
  end if;

  new.owner_id := v_txn_owner;

  if new.deleted_at is not null then
    return new;
  end if;

  if not exists (select 1 from public.tags where id = new.tag_id and deleted_at is null) then
    raise exception 'tag % not found', new.tag_id;
  end if;

  return new;
end;
$$;

revoke all on function set_transaction_tag_derived_columns() from public;

-- `pull_changes` needs no edit: its tags branch is `to_jsonb(tg)`, which
-- picks up the table's columns as they are, so dropping one simply stops
-- emitting it.
