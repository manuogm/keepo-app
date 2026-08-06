-- Fixes a real regression introduced in 20260807150000_capture.sql: that
-- migration's `create or replace function handle_new_user()`/
-- `ensure_user_bootstrap()` carried forward the Adjustment-category
-- seeding from Phase 9 and added Uncategorized, but silently dropped the
-- original "Other" default-category seeding (`is_default = true`) that
-- every version since Phase 1 had. Found while manually verifying Phase
-- 15's insights RPCs against seed data: a fixture user had zero default
-- categories, and a seed insert intended to hit exactly one "Other"
-- category matched three (Adjustment × kind, Uncategorized) instead,
-- silently tripling that row. Every real signup since Phase 12 shipped —
-- on hosted included — has had no default category either.
--
-- Fixed forward, per this project's established precedent for anything
-- already pushed: restores the missing insert in both functions, then
-- backfills any existing profile missing an "Other" category, same
-- pattern the Adjustment/Uncategorized backfills already used.

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

  insert into public.categories (owner_id, kind, name, system_key)
  values
    (new.id, 'expense', 'Adjustment', 'adjustment_expense'),
    (new.id, 'income', 'Adjustment', 'adjustment_income'),
    (new.id, 'expense', 'Uncategorized', 'uncategorized_expense')
  on conflict (owner_id, system_key) do nothing;

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

  insert into public.categories (owner_id, kind, name, system_key)
  values
    (auth.uid(), 'expense', 'Adjustment', 'adjustment_expense'),
    (auth.uid(), 'income', 'Adjustment', 'adjustment_income'),
    (auth.uid(), 'expense', 'Uncategorized', 'uncategorized_expense')
  on conflict (owner_id, system_key) do nothing;
end;
$$;

insert into categories (owner_id, kind, name, is_default)
select p.id, k.kind, 'Other', true
from profiles p
cross join (values ('expense'::category_kind), ('income'::category_kind)) as k (kind)
on conflict (owner_id, kind) where (is_default and deleted_at is null) do nothing;
