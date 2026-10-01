-- A household closes when its last member goes.
--
-- Found in the two-device review (2026-09-24): after a leave, the household
-- row stayed live with nobody in it. `leave_household` has ended both
-- memberships since 20260915100000, and `discard_household` ends them all,
-- but only `delete_own_account` ever closed the household — inline, in its own
-- body. `erase_own_account` leaves it empty too when the eraser was its only
-- member. Nothing reads an empty household today (every read goes through a
-- live membership, and the phone's `myHousehold` also filters the household's
-- own `deleted_at`), but one thing could use it: **a pending invite**.
-- `accept_invite` checks the invite, not the household. An invite made before
-- its maker left could still be accepted, into a household nobody else is in.
--
-- The rule lives on the membership table, so every way out reaches it: once a
-- household has no live member, it is soft-deleted (a tombstone, as
-- `delete_own_account` did, so a device still pulling that domain sees it
-- close) and its pending invites are revoked, as `discard_household` already
-- does for its own. `delete_own_account` loses its inline copy.

create or replace function public.close_household_when_empty()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := old.household_id;
begin
  -- A membership ending: soft-deleted, or deleted outright (account
  -- deletion). A revival or an unrelated edit leaves the household alone.
  if tg_op = 'UPDATE' and not (old.deleted_at is null and new.deleted_at is not null) then
    return null;
  end if;

  if exists (
    select 1 from public.household_members
    where household_id = v_household_id and deleted_at is null
  ) then
    return null;
  end if;

  update public.households set deleted_at = now()
  where id = v_household_id and deleted_at is null;

  update public.household_invites set status = 'revoked'
  where household_id = v_household_id and status = 'pending';

  return null;
end;
$$;

revoke all on function public.close_household_when_empty() from public, anon, authenticated;

create trigger household_members_close_an_empty_household
  after update of deleted_at or delete on public.household_members
  for each row execute function public.close_household_when_empty();

-- Households already left empty, and their pending invites.
update public.household_invites i set status = 'revoked'
where i.status = 'pending'
  and not exists (
    select 1 from public.household_members hm
    where hm.household_id = i.household_id and hm.deleted_at is null
  );

update public.households h set deleted_at = now()
where h.deleted_at is null
  and not exists (
    select 1 from public.household_members hm
    where hm.household_id = h.id and hm.deleted_at is null
  );

-- Restated from 20261012100000. Closing an empty household moved into
-- `close_household_when_empty` above, which every way out of a household
-- now reaches; this function kept its own copy of that step.
create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_unregistered text;
begin
  if v_me is null then
    raise exception 'delete_own_account: no authenticated user';
  end if;

  -- Before anything is destroyed. A table added since this function was
  -- written, carrying the user's id and not accounted for here, is a row that
  -- would either survive the erasure or refuse the auth delete — and the
  -- moment to find out is while everything is still intact.
  v_unregistered := public.unregistered_identity_columns();
  if v_unregistered is not null then
    raise exception 'delete_own_account: unregistered identity column(s): %', v_unregistered;
  end if;

  -- The fork, the departure, the notification, and the free-text scrub — all
  -- of it already exists and is already tested (18_household_lifecycle.sql).
  -- Deletion is erasure plus destruction, so it starts by erasing.
  perform public.erase_own_account();

  -- **The step without which the auth delete is simply refused.** After the
  -- fork the other member owns fresh copies of the shared history, and every
  -- one of them still records this user as its creator. `created_by` is
  -- provenance, not ownership, so pointing it at the row's own owner keeps
  -- the row truthful about who has it and silent about who first typed it.
  update public.transactions set created_by = owner_id where created_by = v_me and owner_id <> v_me;
  update public.accounts set created_by = owner_id where created_by = v_me and owner_id <> v_me;
  update public.recurring_rules set created_by = owner_id where created_by = v_me and owner_id <> v_me;

  -- The same, for what this user left on other people's rows (#1). The fork
  -- settles everything a live household shared; this catches what older
  -- forks left behind. A transfer half whose other half is this user's would
  -- be left alone and refused at commit, so it is detached; a tag of this
  -- user's on someone else's row becomes that person's own tag.
  perform public.detach_transfer_leg(t.id)
  from public.transactions t
  where t.owner_id <> v_me and t.deleted_at is null
    and t.transfer_group_id in (
      select x.transfer_group_id from public.transactions x where x.owner_id = v_me
    );
  perform public.swap_in_own_tags(null, v_me);

  -- The event stays, the person goes. See the ALTER above.
  update public.household_events set actor_id = null where actor_id = v_me;

  -- An invitation from an account that no longer exists cannot be accepted.
  delete from public.household_invites where invited_by = v_me;

  -- `erase_own_account` soft-deletes this, so a rejoin can reactivate the
  -- same row. There is no rejoining from here, and a soft-deleted row holds
  -- the foreign key just as firmly as a live one.
  -- A household left with nobody in it is closed by the trigger on this
  -- table (`close_household_when_empty`).
  delete from public.household_members where user_id = v_me;

  -- Children first, all the way down. Each line is here because something
  -- below it has a foreign key pointing at it. A tag link is someone else's
  -- row when it sits on their transaction or rule, but a tombstone still
  -- pointing at one of this user's tags holds that tag's foreign key.
  delete from public.export_audit_log where owner_id = v_me;
  delete from public.merchant_category_map where owner_id = v_me;
  delete from public.card_mappings where owner_id = v_me;
  delete from public.recurring_rule_tags
  where owner_id = v_me or tag_id in (select id from public.tags where owner_id = v_me);
  delete from public.transaction_tags
  where owner_id = v_me or tag_id in (select id from public.tags where owner_id = v_me);
  delete from public.tags where owner_id = v_me;
  delete from public.recurring_rules where owner_id = v_me;
  delete from public.sync_conflicts where owner_id = v_me;
  delete from public.household_accounts
  where account_id in (select id from public.accounts where owner_id = v_me);
  delete from public.transactions where owner_id = v_me;
  delete from public.accounts where owner_id = v_me;
  delete from public.categories where owner_id = v_me;

  -- Not a uuid and not a foreign key — the user's id as `text`, which nothing
  -- in the database would ever have cleaned up on its own.
  delete from public.ops_rate_limits where subject = v_me::text;

  delete from public.profiles where id = v_me;
end;
$$;
