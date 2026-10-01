-- A partner files a row on the owner's account under the owner's category.
--
-- Found in the two-device review (2026-09-24): a partner could not add an
-- expense to the owner's shared account at all. A transaction belongs to its
-- account's owner — `(account_id, owner_id)` is a foreign key (Phase 7, H10)
-- — and so does its category, through `(category_id, owner_id)`. The app sent
-- the partner as the owner, and would have sent the partner's category even
-- once it sent the right owner. Recurring rules have the same two keys;
-- `set_recurring_rule_owner` already takes the owner from the account, so for
-- them only the category was wrong.
--
-- On someone else's account the partner is offered only the categories that
-- have a counterpart there (user's decision, 2026-09-24):
--   * one shared with the household. A shared category is a pair of rows,
--     one per member, joined by `shared_group_id` (20260912100000);
--   * their "Other". Each member has exactly one default per kind.
-- This swaps the partner's row for the owner's counterpart, in one place,
-- for every write that sets a category: the direct insert, `update_transaction`
-- and both recurring-rule writes. A private category has no counterpart and
-- is refused in plain words. Nothing here shares a category on anyone's
-- behalf.
--
-- The fork is unaffected: it maps every category to the new owner's own
-- (`fork_category_id`) before it inserts, so the swap finds nothing to do.

create or replace function public.owners_category(p_category_id uuid, p_owner uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_category record;
  v_counterpart uuid;
begin
  select id, owner_id, kind, is_default, shared_group_id into v_category
  from public.categories where id = p_category_id;

  -- Unknown ids are left to the foreign key, which names the problem.
  if v_category.id is null or v_category.owner_id = p_owner then
    return p_category_id;
  end if;

  if v_category.is_default then
    select id into v_counterpart from public.categories
    where owner_id = p_owner and kind = v_category.kind and is_default and deleted_at is null;
  elsif v_category.shared_group_id is not null then
    select id into v_counterpart from public.categories
    where owner_id = p_owner and kind = v_category.kind and deleted_at is null
      and shared_group_id = v_category.shared_group_id
    order by created_at
    limit 1;
  end if;

  if v_counterpart is null then
    raise exception 'Only categories shared with your household can be used on an account that isn''t yours. Pick a shared category.';
  end if;

  return v_counterpart;
end;
$$;

comment on function public.owners_category(uuid, uuid) is
  'The owner''s own row for a category: itself, the owner''s default of the same kind, or the owner''s row in the same shared group. Raises for a private category of someone else.';

revoke all on function public.owners_category(uuid, uuid) from public, anon, authenticated;

create or replace function public.use_owners_category()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.category_id is not null then
    new.category_id := public.owners_category(new.category_id, new.owner_id);
  end if;
  return new;
end;
$$;

revoke all on function public.use_owners_category() from public, anon, authenticated;

-- Named to fire before `transactions_set_derived_columns`, which reads the
-- category's kind: BEFORE triggers run in name order.
create trigger transactions_category_is_the_owners
  before insert or update of category_id on public.transactions
  for each row execute function public.use_owners_category();

-- Named to fire after `recurring_rules_set_owner`, which is what says whose
-- category it has to be, and before `recurring_rules_validate_sign`.
create trigger recurring_rules_use_the_owners_category
  before insert or update on public.recurring_rules
  for each row execute function public.use_owners_category();
