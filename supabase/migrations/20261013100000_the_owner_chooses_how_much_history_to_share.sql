-- The owner chooses how much history to share.
--
-- Phase 4 of the "Transfers & household sharing" workstream
-- (keepo-v1-master-plan.md): the sharing API gains the choice Phases 1–3
-- built the machinery for. Every new parameter defaults to full history, so
-- the build already on a phone shares exactly as it does today.
--
-- ============================================================================
-- 1. Where a share begins
-- ============================================================================
--
-- `share_start(owner)` is the start of today in the owner's time zone
-- (user's decision, 2026-09-23). It is taken at the moment the share is
-- made, so an account in an invite starts on the day the invite is accepted,
-- not the day it was sent. `account_opening_as_seen` dates the partner's
-- carried opening on that same calendar day.
--
-- ============================================================================
-- 2. One way into a household
-- ============================================================================
--
-- `share_account` and both halves of `accept_invite` each carried their own
-- copy of the upsert. They now call `share_into_household`, which also fixes
-- what the copies got wrong once a share can begin on a date: re-sharing an
-- account whose share had ended revived the row with whatever start date it
-- last had. A share that had ended now starts afresh with the date asked for.
-- A live share never narrows (the owner may widen, never narrow — user's
-- decision, 2026-09-23), so sharing an already-shared account again keeps
-- the wider of the two.
--
-- `create_invite` and `accept_invite` take the accounts to share with full
-- history as a list beside the accounts to share; when it is left out, every
-- shared account gets full history. The inviter's choice waits on the invite
-- in `full_history_account_ids`, and `preview_invite` shows it per account.
--
-- ============================================================================
-- 3. Widening
-- ============================================================================
--
-- `share_full_history(account)` turns a dated share into a full one and
-- re-sends the account, so the partner's phone receives the earlier rows,
-- their tags and categories, and the account's true opening balance.
--
-- ============================================================================
-- 4. What a partner schedules stays where they can see it
-- ============================================================================
--
-- Two ways a partner could still place a row before the start date, both
-- unreachable until now because no share could carry one:
--
--   * a transfer between the two members' accounts, dated before the start
--     of the account the caller owns — Phase 1 checks each leg only against
--     the caller, who sees all of their own account. `create_transfer` and
--     `update_transfer` now require both halves to be where the household
--     sees them;
--   * a recurring rule on the owner's account whose first occurrence falls
--     before the start date: the scheduler would create rows the partner who
--     set it up could never see. A trigger refuses it, with the sentence
--     Phase 1 uses for a transaction.

-- ============================================================================
-- Where a share begins
-- ============================================================================

create function public.share_start(p_owner uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select ((now() at time zone t.tz)::date)::timestamp at time zone t.tz
  from (
    select coalesce(
      (select public.safe_time_zone(p.time_zone) from public.profiles p where p.id = p_owner),
      'UTC'
    ) as tz
  ) t;
$$;

revoke all on function public.share_start(uuid) from public, anon, authenticated;

-- ============================================================================
-- One way into a household
-- ============================================================================

create function public.share_into_household(p_household_id uuid, p_account_id uuid, p_full_history boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.household_accounts as existing (household_id, account_id, history_from)
  select p_household_id, a.id, case when p_full_history then null else public.share_start(a.owner_id) end
  from public.accounts a
  where a.id = p_account_id
  on conflict (household_id, account_id) do update
  set deleted_at = null,
      shared_at = now(),
      -- An ended share starts afresh; a live one never narrows.
      history_from = case
        when existing.deleted_at is not null then excluded.history_from
        when existing.history_from is null or excluded.history_from is null then null
        else least(existing.history_from, excluded.history_from)
      end;

  perform public.restamp_account_for_sync(p_account_id);
end;
$$;

revoke all on function public.share_into_household(uuid, uuid, boolean) from public, anon, authenticated;

-- Restated from 20260816100001 with the history choice.
drop function public.share_account(uuid);

create function public.share_account(p_account_id uuid, p_full_history boolean default true)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_household_id uuid;
begin
  select owner_id into v_owner from public.accounts where id = p_account_id and deleted_at is null;
  if v_owner is null or v_owner <> (select auth.uid()) then
    raise exception 'account not found or not owned by you';
  end if;

  select household_id into v_household_id
  from public.household_members where user_id = (select auth.uid()) and deleted_at is null;
  if v_household_id is null then
    raise exception 'you do not belong to a household';
  end if;

  perform public.share_into_household(v_household_id, p_account_id, p_full_history);
end;
$$;

revoke all on function public.share_account(uuid, boolean) from public, anon;
grant execute on function public.share_account(uuid, boolean) to authenticated;

-- ============================================================================
-- Invites
-- ============================================================================

alter table public.household_invites
  add column full_history_account_ids uuid[] not null default '{}';

comment on column public.household_invites.full_history_account_ids is
  'Which of shared_account_ids the inviter shares with full history; the rest start on the day the invite is accepted.';

-- Invites sent before the choice existed share everything, as they promised.
update public.household_invites set full_history_account_ids = shared_account_ids;

-- Restated from 20260912100000 with the history choice.
drop function public.create_invite(uuid[], uuid[]);

create function public.create_invite(
  p_share_account_ids uuid[] default '{}',
  p_share_category_ids uuid[] default '{}',
  p_full_history_account_ids uuid[] default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_token text;
begin
  if not public.ops_check_own_rate_limit('create_invite', 10, 60) then
    raise exception 'rate limit exceeded';
  end if;

  if v_household_id is null then
    raise exception 'create a household before inviting a member';
  end if;

  -- Only your own, and only things that exist. A selection is a promise about
  -- what the other member will get; silently dropping an unowned id would
  -- make the review screen a lie.
  if exists (
    select 1 from unnest(p_share_account_ids) as a(id)
    where not exists (
      select 1 from public.accounts
      where id = a.id and owner_id = (select auth.uid()) and deleted_at is null
    )
  ) then
    raise exception 'cannot share an account you do not own';
  end if;

  if exists (
    select 1 from unnest(p_share_category_ids) as c(id)
    where not exists (
      select 1 from public.categories
      where id = c.id and owner_id = (select auth.uid()) and deleted_at is null and not is_default
    )
  ) then
    raise exception 'cannot share a category you do not own';
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');

  insert into public.household_invites (
    household_id, invited_by, token_hash, expires_at, shared_account_ids, shared_category_ids,
    full_history_account_ids
  )
  values (
    v_household_id, (select auth.uid()), encode(extensions.digest(v_token, 'sha256'), 'hex'),
    now() + interval '7 days', p_share_account_ids, p_share_category_ids,
    coalesce(p_full_history_account_ids, p_share_account_ids)
  );

  return v_token;
end;
$$;

revoke all on function public.create_invite(uuid[], uuid[], uuid[]) from public, anon;
grant execute on function public.create_invite(uuid[], uuid[], uuid[]) to authenticated, service_role;

-- Restated from 20260912100000: each account says whether it comes with its
-- full history. The return type changes, so it is dropped and recreated.
drop function public.preview_invite(text);

-- What the invitee is about to receive, before they commit to anything.
--
-- Readable by whoever holds the token and nobody else — the token is a secret
-- the inviter chose to hand over, and it expires. Names only: no ids, no
-- amounts, nothing that outlives the decision it exists to inform.
create function public.preview_invite(p_token text)
returns table (
  account_name text, category_name text, category_kind public.category_kind, full_history boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite record;
begin
  if not public.ops_check_own_rate_limit('preview_invite', 20, 60) then
    raise exception 'rate limit exceeded';
  end if;

  select * into v_invite from public.household_invites
  where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status = 'pending'
    and expires_at > now();

  if v_invite.id is null then
    raise exception 'invite not found, already used, or expired';
  end if;

  return query
  select a.name, null::text, null::public.category_kind, a.id = any(v_invite.full_history_account_ids)
  from public.accounts a
  where a.id = any(v_invite.shared_account_ids) and a.deleted_at is null
  union all
  select null::text, c.name, c.kind, null::boolean
  from public.categories c
  where c.id = any(v_invite.shared_category_ids) and c.deleted_at is null;
end;
$$;

revoke all on function public.preview_invite(text) from public, anon;
grant execute on function public.preview_invite(text) to authenticated, service_role;

-- Restated from 20260915100000 with the history choice, both members' shares
-- going through `share_into_household`.
drop function public.accept_invite(text, uuid[], uuid[]);

create function public.accept_invite(
  p_token text,
  p_share_account_ids uuid[] default '{}',
  p_share_category_ids uuid[] default '{}',
  p_full_history_account_ids uuid[] default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
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
  -- with. Their accounts first: sharing one is the inviter's own act, so it
  -- goes through `share_into_household` rather than `share_account`, which
  -- would check the caller — here, the invitee. A dated share starts today,
  -- in the inviter's own time zone.
  foreach v_account_id in array v_invite.shared_account_ids loop
    if exists (select 1 from public.accounts where id = v_account_id and owner_id = v_invite.invited_by and deleted_at is null) then
      perform public.share_into_household(
        v_invite.household_id, v_account_id, v_account_id = any(v_invite.full_history_account_ids)
      );
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
      perform public.share_into_household(
        v_invite.household_id, v_account_id,
        v_account_id = any(coalesce(p_full_history_account_ids, p_share_account_ids))
      );
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
$$;

revoke all on function public.accept_invite(text, uuid[], uuid[], uuid[]) from public, anon;
grant execute on function public.accept_invite(text, uuid[], uuid[], uuid[]) to authenticated, service_role;

-- ============================================================================
-- Widening
-- ============================================================================

create function public.share_full_history(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.accounts
    where id = p_account_id and owner_id = (select auth.uid()) and deleted_at is null
  ) then
    raise exception 'account not found or not owned by you';
  end if;

  if not exists (select 1 from public.household_accounts where account_id = p_account_id and deleted_at is null) then
    raise exception 'This account isn''t shared with your household.';
  end if;

  update public.household_accounts set history_from = null
  where account_id = p_account_id and deleted_at is null and history_from is not null;

  if found then
    perform public.restamp_account_for_sync(p_account_id);
  end if;
end;
$$;

revoke all on function public.share_full_history(uuid) from public, anon;
grant execute on function public.share_full_history(uuid) to authenticated, service_role;

-- ============================================================================
-- A transfer between the two members
-- ============================================================================

-- Both halves of a transfer between two members' accounts must be where the
-- household sees them. A question about the caller's own accounts only, so
-- it can be granted to the invoker-mode `create_transfer`.
create function public.assert_transfer_seen_by_both(
  p_from_account_id uuid, p_to_account_id uuid, p_occurred_at timestamptz
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if public.can_read_account(p_from_account_id) and public.can_read_account(p_to_account_id)
     and (select count(distinct owner_id) from public.accounts where id in (p_from_account_id, p_to_account_id)) > 1
     and (public.transaction_shared_into(p_from_account_id, p_occurred_at) is null
          or public.transaction_shared_into(p_to_account_id, p_occurred_at) is null) then
    raise exception 'This transfer is between your account and your partner''s, so it can''t be dated before both accounts were shared. Pick a later date.';
  end if;
end;
$$;

revoke all on function public.assert_transfer_seen_by_both(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.assert_transfer_seen_by_both(uuid, uuid, timestamptz) to authenticated, service_role;

-- Restated from 20261009100000 with `assert_transfer_seen_by_both`.
create or replace function public.create_transfer(
  p_from_account_id uuid,
  p_to_account_id uuid,
  p_from_amount_e4 bigint,
  p_to_amount_e4 bigint default null,
  p_occurred_at timestamptz default now(),
  p_from_id uuid default null,
  p_to_id uuid default null,
  p_notes text default null,
  p_title text default null
)
returns setof public.transactions
language plpgsql
set search_path = ''
as $$
declare
  v_from_owner uuid;
  v_from_currency text;
  v_to_owner uuid;
  v_to_currency text;
  v_to_amount_e4 bigint;
  v_from_id uuid := coalesce(p_from_id, gen_random_uuid());
  -- The sending leg's own id: the value the phone already wrote as its
  -- placeholder (20261006100000), so the two can never disagree.
  v_group uuid := v_from_id;
  v_title text := nullif(btrim(p_title), '');
begin
  if p_from_amount_e4 is null or p_from_amount_e4 <= 0 then
    raise exception 'from_amount must be a positive magnitude';
  end if;

  select owner_id, currency into v_from_owner, v_from_currency
  from public.accounts where id = p_from_account_id;
  select owner_id, currency into v_to_owner, v_to_currency
  from public.accounts where id = p_to_account_id;

  if v_from_currency is null or v_to_currency is null then
    raise exception 'one or both accounts were not found or are not accessible';
  end if;

  perform public.assert_transaction_placeable(p_from_account_id, p_occurred_at);
  perform public.assert_transaction_placeable(p_to_account_id, p_occurred_at);
  perform public.assert_transfer_seen_by_both(p_from_account_id, p_to_account_id, p_occurred_at);

  v_to_amount_e4 := coalesce(
    p_to_amount_e4,
    case when v_from_currency = v_to_currency then p_from_amount_e4 end
  );
  if v_to_amount_e4 is null or v_to_amount_e4 <= 0 then
    raise exception 'to_amount is required for cross-currency transfers and must be a positive magnitude';
  end if;

  insert into public.transactions (
    id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, transfer_group_id, source, notes, title
  )
  values
    (
      v_from_id, v_from_owner, (select auth.uid()), p_from_account_id,
      -p_from_amount_e4, v_from_currency, p_occurred_at, v_group, 'manual', p_notes, v_title
    ),
    (
      coalesce(p_to_id, gen_random_uuid()), v_to_owner, (select auth.uid()), p_to_account_id,
      v_to_amount_e4, v_to_currency, p_occurred_at, v_group, 'manual', p_notes, v_title
    );

  return query select * from public.transactions where transfer_group_id = v_group;
end;
$$;

-- Restated from 20261009100000 with `assert_transfer_seen_by_both`.
create or replace function public.update_transfer(
  p_transfer_group_id uuid,
  p_from_expected_version integer,
  p_to_expected_version integer,
  p_from_amount_e4 bigint,
  p_to_amount_e4 bigint,
  p_occurred_at timestamptz,
  p_notes text default null,
  p_title text default null,
  p_from_account_id uuid default null,
  p_to_account_id uuid default null
)
returns table(conflict boolean, transaction transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from record;
  v_to record;
  v_from_account uuid;
  v_to_account uuid;
  v_from_currency text;
  v_to_currency text;
  v_title text := nullif(btrim(p_title), '');
begin
  if p_from_amount_e4 is null or p_from_amount_e4 <= 0 or p_to_amount_e4 is null or p_to_amount_e4 <= 0 then
    raise exception 'from_amount and to_amount must be positive magnitudes';
  end if;

  select id, version, account_id, owner_id, currency, occurred_at into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 < 0;

  select id, version, account_id, owner_id, currency, occurred_at into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 > 0;

  if v_from.id is null or v_to.id is null
     or not public.can_read_transaction(v_from.account_id, v_from.owner_id, v_from.occurred_at)
     or not public.can_read_transaction(v_to.account_id, v_to.owner_id, v_to.occurred_at) then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  v_from_account := coalesce(p_from_account_id, v_from.account_id);
  v_to_account := coalesce(p_to_account_id, v_to.account_id);
  v_from_currency := v_from.currency;
  v_to_currency := v_to.currency;

  if v_from_account = v_to_account then
    raise exception 'A transfer needs two different accounts.';
  end if;

  -- A leg that moves is placed afresh; a leg that stays only needs its new
  -- date to be one the caller can see. It may sit on a deleted account — a
  -- kept anchor (20261007100000) — and editing the live side must not
  -- depend on that.
  if v_from_account <> v_from.account_id then
    v_from_currency := public.transfer_leg_target_currency(v_from_account, v_from.owner_id, p_occurred_at);
  else
    perform public.assert_transaction_date_visible(v_from_account, p_occurred_at);
  end if;
  if v_to_account <> v_to.account_id then
    v_to_currency := public.transfer_leg_target_currency(v_to_account, v_to.owner_id, p_occurred_at);
  else
    perform public.assert_transaction_date_visible(v_to_account, p_occurred_at);
  end if;

  perform public.assert_transfer_seen_by_both(v_from_account, v_to_account, p_occurred_at);

  if v_from.version <> p_from_expected_version or v_to.version <> p_to_expected_version then
    -- The versions of whichever leg moved on, so the review reads as a real
    -- disagreement rather than "your version 3 vs. the saved version 3".
    perform public.record_transaction_conflict(
      v_from.id,
      case when v_from.version <> p_from_expected_version then p_from_expected_version else p_to_expected_version end,
      case when v_from.version <> p_from_expected_version then v_from.version else v_to.version end,
      jsonb_build_object(
        'rpc', 'update_transfer', 'transfer_group_id', p_transfer_group_id,
        'from_amount_e4', p_from_amount_e4, 'to_amount_e4', p_to_amount_e4, 'occurred_at', p_occurred_at,
        'notes', p_notes, 'title', v_title, 'from_account_id', v_from_account, 'to_account_id', v_to_account
      )
    );
    return query select true, null::public.transactions;
    return;
  end if;

  update public.transactions set account_id = v_from_account, currency = v_from_currency,
    amount_e4 = -p_from_amount_e4, occurred_at = p_occurred_at, notes = p_notes, title = v_title
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set account_id = v_to_account, currency = v_to_currency,
    amount_e4 = p_to_amount_e4, occurred_at = p_occurred_at, notes = p_notes, title = v_title
  where id = v_to.id and version = p_to_expected_version;

  return query select false, t from public.transactions t where t.transfer_group_id = p_transfer_group_id;
end;
$$;

-- ============================================================================
-- A partner's recurring rule
-- ============================================================================

-- Only a partner's own scheduling is checked. The owner may backdate their
-- own account freely, and the system — the scheduler, or a fork handing a
-- copy to the other member — is nobody's partner: it runs with no user, or as
-- someone who cannot read the rule's account at all.
create function public.keep_partner_rule_in_view()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_at timestamptz;
begin
  if v_me is null or v_me = new.owner_id or not public.can_read_account(new.account_id) then
    return new;
  end if;

  -- An edit that neither moves the first occurrence nor resumes the rule
  -- schedules nothing new.
  if tg_op = 'UPDATE'
     and old.next_due_at is not distinct from new.next_due_at
     and old.account_id is not distinct from new.account_id
     and old.to_account_id is not distinct from new.to_account_id
     and not (new.active and not old.active) then
    return new;
  end if;

  -- The moment `materialize_recurring` would date the first occurrence.
  select new.next_due_at::timestamp at time zone coalesce(public.safe_time_zone(p.time_zone), 'UTC')
  into v_at
  from public.profiles p where p.id = new.owner_id;

  perform public.assert_transaction_date_visible(new.account_id, v_at);
  if new.to_account_id is not null then
    perform public.assert_transaction_date_visible(new.to_account_id, v_at);
  end if;

  return new;
end;
$$;

revoke all on function public.keep_partner_rule_in_view() from public, anon, authenticated;

-- Named to sort after `recurring_rules_set_owner`, which fills in `owner_id`.
create trigger recurring_rules_stay_in_view
  before insert or update of next_due_at, account_id, to_account_id, active on public.recurring_rules
  for each row execute function public.keep_partner_rule_in_view();
