-- Category delete, made safe: deleting a category the user actually uses
-- silently orphaned its transactions before this migration (soft delete
-- alone leaves category_id pointing at a deleted row, invisible in every
-- view that isn't already resilient to that). The client now shows a
-- warning naming the transaction count before calling this, but the DB is
-- the actual enforcement — the reassignment and the soft-delete happen in
-- one call so a crash mid-flow can never leave a transaction pointing at a
-- gone category.
--
-- SECURITY DEFINER, same reasoning as update_transaction/delete_transaction
-- (migration 20260805134921): `revoke update on transactions from
-- authenticated` (Phase 3) means a plain client-side UPDATE of category_id
-- is impossible regardless of RLS, so this needs to run as table owner and
-- re-implement its own ownership checks.

create function delete_category_and_reassign(p_category_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_category record;
  v_other_id uuid;
  v_reassigned integer;
begin
  select id, kind, is_default, system_key, owner_id, deleted_at
  into v_category
  from public.categories
  where id = p_category_id;

  if v_category.id is null or v_category.owner_id <> v_owner or v_category.deleted_at is not null then
    raise exception 'category not found or not accessible';
  end if;

  -- Belt-and-suspenders: prevent_default_category_deletion would also
  -- reject the soft-delete below, but failing here first means the
  -- reassignment never runs at all against a category the client's own UI
  -- should never have offered a delete affordance for in the first place.
  if v_category.is_default or v_category.system_key is not null then
    raise exception 'this category cannot be deleted';
  end if;

  select id into v_other_id
  from public.categories
  where owner_id = v_owner and kind = v_category.kind and is_default and deleted_at is null;

  if v_other_id is null then
    raise exception 'no default category found to reassign into';
  end if;

  -- set_transaction_derived_columns (before insert or update, migration
  -- 20260804192805) re-derives category_kind from the new category_id on
  -- every row this touches, so sign_matches_category_kind stays satisfied
  -- automatically — v_other_id is guaranteed the same kind as the category
  -- being deleted, never a cross-kind reassignment.
  update public.transactions
  set category_id = v_other_id
  where category_id = p_category_id and owner_id = v_owner and deleted_at is null;

  get diagnostics v_reassigned = row_count;

  update public.categories
  set deleted_at = now()
  where id = p_category_id;

  return v_reassigned;
end;
$$;

revoke all on function delete_category_and_reassign(uuid) from public;
grant execute on function delete_category_and_reassign(uuid) to authenticated;
