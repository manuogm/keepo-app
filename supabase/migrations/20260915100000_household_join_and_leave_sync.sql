-- Two things two real phones found that one phone never could.
--
-- ============================================================================
-- 1. The inviter's device never pulled the household it had just gained
-- ============================================================================
--
-- `accept_invite` bumped only the **joiner's** `sync_epoch`. But
-- `sync_domain_id` moves a member into the household's own ticket sequence,
-- which starts at 1 — below whatever cursor a device is already holding.
-- `create_household` bumps the creator for precisely this reason, and
-- `30_household_category_sharing.sql`'s first assertion exists to pin it:
-- "without the bump the creator's own phone never pulls the household it just
-- made".
--
-- Joining does the same thing to the **inviter**. Their device kept its old
-- cursor, so the new membership row, the guest's shared accounts and every
-- category twin written by the join were all below it and never arrived.
--
-- The visible result, reported from a two-device run: the owner's Household
-- report opened on a net worth of **0**, with no shared accounts and no
-- categories — while the guest, who bumps their own epoch, saw all of it. It
-- also made scope look broken, because `LocalAccountRow.isShared` is that
-- same missing `household_accounts` lookup: with none of those rows present,
-- Household scope showed nothing and Private showed everything.
--
-- ============================================================================
-- 2. Leaving now dissolves the household, rather than stranding the other
-- ============================================================================
--
-- `leave_household` retired only the caller's membership, leaving the other
-- member in a household of one. On two phones that read as a bug: the person
-- who stayed was told nothing and their Household screen went on showing a
-- partner who had gone.
--
-- A household is two people by definition, so one leaving ends it. The fork
-- has already given each of them an independent private copy of everything
-- shared, so this costs neither side any data — and both epochs are bumped so
-- the remaining member's device actually re-pulls and notices.
--
-- Both functions restated from `pg_get_functiondef` (20260911100000's lesson,
-- which has now caught a from-memory restatement once in this workstream).

CREATE OR REPLACE FUNCTION public.accept_invite(p_token text, p_share_account_ids uuid[] DEFAULT '{}'::uuid[], p_share_category_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_invite record;
  v_event_id uuid;
  v_me uuid := (select auth.uid());
  v_category_id uuid;
  v_account_id uuid;
begin
  if not public.ops_check_own_rate_limit('accept_invite', 10, 60) then
    raise exception 'rate limit exceeded';
  end if;

  if public.my_household_id() is not null then
    raise exception 'already a member of a household';
  end if;

  select * into v_invite from public.household_invites
  where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status = 'pending'
    and expires_at > now();

  if v_invite.id is null then
    raise exception 'invite not found, already used, or expired';
  end if;

  if v_invite.invited_by = v_me then
    raise exception 'cannot accept your own invite';
  end if;

  insert into public.household_members (household_id, user_id)
  values (v_invite.household_id, v_me)
  on conflict (household_id, user_id) do update set deleted_at = null, joined_at = now();

  update public.household_invites set status = 'accepted' where id = v_invite.id;

  -- The inviter's choices, made real now that there is somebody to share
  -- with. Their accounts first: sharing one is the inviter's own act, and
  -- `share_account` runs as its owner, so it is inlined here rather than
  -- called — the caller is the invitee.
  foreach v_account_id in array v_invite.shared_account_ids loop
    if exists (select 1 from public.accounts where id = v_account_id and owner_id = v_invite.invited_by and deleted_at is null) then
      insert into public.household_accounts (household_id, account_id)
      values (v_invite.household_id, v_account_id)
      on conflict (household_id, account_id) do update set deleted_at = null, shared_at = now();
      perform public.restamp_account_for_sync(v_account_id);
    end if;
  end loop;

  -- Then the categories, in both directions. `ensure_category_twin` matches
  -- by trimmed, case-insensitive name and kind — the inviter's "Groceries"
  -- and the invitee's "groceries" become one category rather than two that
  -- look identical — and creates the other member's row when there is no
  -- match, which is what keeps every group one-row-per-member.
  foreach v_category_id in array v_invite.shared_category_ids loop
    if exists (
      select 1 from public.categories
      where id = v_category_id and owner_id = v_invite.invited_by and deleted_at is null and not is_default
    ) then
      perform public.ensure_category_twin(
        v_category_id, v_me,
        coalesce(
          (select shared_group_id from public.categories where id = v_category_id),
          gen_random_uuid()
        )
      );
    end if;
  end loop;

  foreach v_category_id in array p_share_category_ids loop
    if exists (
      select 1 from public.categories
      where id = v_category_id and owner_id = v_me and deleted_at is null and not is_default
    ) then
      -- Already linked by the loop above when both members named it the same
      -- thing; `coalesce` keeps that group rather than starting a second one.
      perform public.ensure_category_twin(
        v_category_id, v_invite.invited_by,
        coalesce(
          (select shared_group_id from public.categories where id = v_category_id),
          gen_random_uuid()
        )
      );
    end if;
  end loop;

  foreach v_account_id in array p_share_account_ids loop
    if exists (select 1 from public.accounts where id = v_account_id and owner_id = v_me and deleted_at is null) then
      insert into public.household_accounts (household_id, account_id)
      values (v_invite.household_id, v_account_id)
      on conflict (household_id, account_id) do update set deleted_at = null, shared_at = now();
      perform public.restamp_account_for_sync(v_account_id);
    end if;
  end loop;

  -- **Both** members, not just the joiner. `sync_domain_id` moves a member
  -- into the household's own ticket sequence, which starts at 1 — below
  -- whatever cursor a device already holds. `create_household` bumps the
  -- creator for exactly this reason (see 30_household_category_sharing.sql's
  -- first assertion); joining does the same thing to the **inviter**, whose
  -- device otherwise never pulls the membership row, the shared accounts or
  -- the category twins that were just written.
  --
  -- The symptom was not a missing row somewhere obscure: the owner's own
  -- Household report opened on a net worth of 0, no shared accounts and no
  -- categories, while the guest — who bumps their own epoch here — saw all of
  -- it. Everything arrived eventually, once unrelated writes pushed the
  -- sequence past the stale cursor.
  update public.profiles set sync_epoch = sync_epoch + 1
  where id in (v_me, v_invite.invited_by);

  insert into public.household_events (household_id, actor_id, kind)
  values (v_invite.household_id, v_me, 'member_joined')
  returning id into v_event_id;

  perform public.notify_household(v_event_id);

  return v_invite.household_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.leave_household()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_other uuid;
  v_event_id uuid;
begin
  if v_household_id is null then
    raise exception 'not a member of a household';
  end if;

  select user_id into v_other from public.household_members
  where household_id = v_household_id and user_id <> v_me and deleted_at is null;

  if v_other is not null then
    perform public.fork_household_accounts(v_household_id, v_me, v_other);
  end if;

  -- **Both** memberships, not just the caller's. A household is two people by
  -- definition; one of them walking out does not leave the other in a
  -- household of one, it ends the household. Leaving the other member behind
  -- in a single-member household was the old behaviour, and on two real
  -- phones it read as a bug: the person who stayed was never told anything,
  -- and their Household screen went on showing a partner who had gone.
  --
  -- The fork above has already given each of them an independent private copy
  -- of everything that was shared, so nothing is lost on either side.
  update public.household_members set deleted_at = now()
  where household_id = v_household_id and deleted_at is null;

  perform public.unlink_shared_categories(v_me);
  if v_other is not null then
    perform public.unlink_shared_categories(v_other);
  end if;

  -- Both epochs, so the other member's device re-pulls and discovers the
  -- household is gone rather than rendering one that no longer exists.
  update public.profiles set sync_epoch = sync_epoch + 1
  where id = v_me or (v_other is not null and id = v_other);

  insert into public.household_events (household_id, actor_id, kind)
  values (v_household_id, v_me, 'member_left')
  returning id into v_event_id;

  perform public.notify_household(v_event_id);
end;
$function$;
