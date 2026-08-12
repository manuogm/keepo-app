-- Continuation of 20260814100000_remove_sync_ritual_and_system_categories.sql,
-- split into its own migration: pushing the whole thing as one migration
-- against the hosted project failed with an opaque error exactly at this
-- ALTER TABLE (reproducible, survived adding IF EXISTS/CASCADE, and
-- pg_depend showed no real dependent objects) while the identical SQL
-- ran clean locally — a batching/transaction-size quirk in `supabase db
-- push` against this migration file's statement count, not a real SQL
-- problem. Splitting isolates it; if hosted still rejects this in
-- isolation, the real error will finally surface on its own.

alter table categories drop constraint if exists categories_system_key_unique cascade;
alter table categories drop column if exists system_key;

-- ============================================================================
-- resolve_category_for_merchant: both kinds now fall back to their own
-- is_default row — the expense-only 'uncategorized_expense' special
-- case no longer exists, so this collapses to one rule for both kinds.
-- ============================================================================

create or replace function resolve_category_for_merchant(p_owner uuid, p_merchant_normalized text, p_kind category_kind)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select m.category_id
      from public.merchant_category_map m
      join public.categories c on c.id = m.category_id
      where m.owner_id = p_owner and m.merchant_pattern = p_merchant_normalized and c.kind = p_kind
    ),
    (
      select id from public.categories
      where owner_id = p_owner and kind = p_kind and is_default and deleted_at is null
      limit 1
    )
  );
$$;

-- Note: capture_transaction already calls resolve_category_for_merchant
-- (extracted in 20260809100000_csv_import_export.sql) rather than looking
-- up system_key itself, so it needs no change here — fixing the shared
-- function above is enough.

-- ============================================================================
-- handle_new_user / ensure_user_bootstrap: stop seeding the system
-- categories. "Other" per kind is still seeded (unchanged from
-- 20260808150000_budgets_fi.sql).
-- ============================================================================

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);

  insert into public.categories (owner_id, kind, name, is_default)
  values (new.id, 'expense', 'Other', true), (new.id, 'income', 'Other', true)
  on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;

  insert into public.fi_settings (owner_id) values (new.id)
  on conflict (owner_id) do nothing;

  return new;
end;
$$;

create or replace function ensure_user_bootstrap()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id)
  values (auth.uid())
  on conflict (id) do nothing;

  insert into public.categories (owner_id, kind, name, is_default)
  values (auth.uid(), 'expense', 'Other', true), (auth.uid(), 'income', 'Other', true)
  on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;

  insert into public.fi_settings (owner_id) values (auth.uid())
  on conflict (owner_id) do nothing;
end;
$$;

-- ============================================================================
-- delete_category_and_reassign: drop the now-nonexistent system_key half
-- of the delete guard.
-- ============================================================================

create or replace function delete_category_and_reassign(p_category_id uuid)
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
  select id, kind, is_default, owner_id, deleted_at
  into v_category
  from public.categories
  where id = p_category_id;

  if v_category.id is null or v_category.owner_id <> v_owner or v_category.deleted_at is not null then
    raise exception 'category not found or not accessible';
  end if;

  if v_category.is_default then
    raise exception 'this category cannot be deleted';
  end if;

  select id into v_other_id
  from public.categories
  where owner_id = v_owner and kind = v_category.kind and is_default and deleted_at is null;

  if v_other_id is null then
    raise exception 'no default category found to reassign into';
  end if;

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

-- ============================================================================
-- prevent_default_category_deletion: drop the system_key half of the
-- lock (column is gone), and add a reserved-name guard — no non-default
-- category may be named "Other"/"Others" (case-insensitive), per kind,
-- so a user-created category can never masquerade as the one true
-- fallback. The default row's own name stays locked by the rename
-- check, unaffected by the reserved-name check. The reserved-name check
-- must also run on INSERT (a brand-new "Other" is just as confusing as
-- a rename into one), so the trigger widens from update-only to
-- insert-or-update; the delete/rename checks stay update-only since
-- OLD doesn't exist on insert.
-- ============================================================================

create or replace function prevent_default_category_deletion()
returns trigger
language plpgsql
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

drop trigger if exists categories_prevent_default_deletion on categories;
create trigger categories_prevent_default_deletion
  before insert or update on categories
  for each row execute function prevent_default_category_deletion();
