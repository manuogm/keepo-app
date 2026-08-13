-- Follow-up to 20260816100000_sync_primitives.sql — fixes found via pgTAP
-- after that migration had already been pushed to hosted once. Since
-- `supabase db push` tracks applied migrations by filename, editing that
-- file's content locally does not re-apply it to hosted; these functions
-- must be redefined here instead, same precedent as
-- 20260814100100_drop_category_system_key.sql following 20260814100000.
--
-- Three real bugs found by pgTAP, all fixed below:
--   1. pull_changes used ONE scalar cursor across every table, but
--      currencies/fx_rates share a separate GLOBAL ticket domain that
--      accumulates much faster than any single household's — a fresh
--      LH3 re-stamp in a quiet household domain could sit at ticket #6
--      while the client's cursor was already past #500 from currencies
--      alone, so `sync_seq > cursor` was false forever and the row never
--      delivered. Fixed with two separate cursors.
--   2. restamp_account_for_sync used `alter table ... disable trigger`,
--      which errors ("cannot ALTER TABLE because it has pending trigger
--      events") whenever the account was created earlier in the same
--      transaction — exactly the sequence pgTAP's own test files use, via
--      the DEFERRABLE FK triggers on accounts/transactions. Replaced with
--      a plain UPDATE plus a transaction-local escape hatch on
--      bump_version/set_updated_at so it still doesn't perturb version/
--      updated_at.
--   3. create_household's own guard was a raw EXISTS against
--      household_members with no deleted_at filter, permanently blocking
--      a former member (a tombstoned row from a past leave/erase) from
--      ever creating a fresh household again.

drop function if exists public.pull_changes(bigint);
drop function if exists public.restamp_account_for_sync(uuid, uuid);

create or replace function public.bump_version()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('keepo.restamp_only', true), 'false') = 'true' then
    new.version = old.version;
  else
    new.version = old.version + 1;
  end if;
  return new;
end;
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('keepo.restamp_only', true), 'false') = 'true' then
    new.updated_at = old.updated_at;
  else
    new.updated_at = now();
  end if;
  return new;
end;
$$;

create or replace function public.restamp_account_for_sync(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('keepo.restamp_only', 'true', true);
  update public.accounts set id = id where id = p_account_id;
  update public.transactions set id = id where account_id = p_account_id and deleted_at is null;
  update public.balance_snapshots set id = id where account_id = p_account_id;
  update public.recurring_rules set id = id where account_id = p_account_id;
  perform set_config('keepo.restamp_only', 'false', true);
end;
$$;

grant execute on function public.restamp_account_for_sync(uuid) to postgres;

create or replace function public.share_account(p_account_id uuid)
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

  insert into public.household_accounts (household_id, account_id)
  values (v_household_id, p_account_id)
  on conflict (household_id, account_id) do update set deleted_at = null, shared_at = now();

  perform public.restamp_account_for_sync(p_account_id);
end;
$$;

create or replace function public.accept_invite(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite record;
  v_event_id uuid;
begin
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

  if v_invite.invited_by = (select auth.uid()) then
    raise exception 'cannot accept your own invite';
  end if;

  -- A user who previously left this exact household has a tombstoned
  -- (deleted_at not null) row still occupying the PK — reactivate it
  -- instead of a plain insert, or a rejoin collides on household_members_pkey.
  insert into public.household_members (household_id, user_id)
  values (v_invite.household_id, (select auth.uid()))
  on conflict (household_id, user_id) do update set deleted_at = null, joined_at = now();

  update public.household_invites set status = 'accepted' where id = v_invite.id;

  perform public.merge_household_categories(v_invite.invited_by, (select auth.uid()));

  update public.profiles set sync_epoch = sync_epoch + 1 where id = (select auth.uid());

  insert into public.household_events (household_id, actor_id, kind)
  values (v_invite.household_id, (select auth.uid()), 'member_joined')
  returning id into v_event_id;

  perform public.notify_household(v_event_id);

  return v_invite.household_id;
end;
$$;

create or replace function public.create_household()
returns public.households
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_result public.households;
begin
  if public.my_household_id() is not null then
    raise exception 'you already belong to a household';
  end if;

  insert into public.households (id) values (v_id) returning * into v_result;
  insert into public.household_members (household_id, user_id) values (v_id, (select auth.uid()));

  return v_result;
end;
$$;

-- Two SEPARATE cursors, not one: currencies/fx_rates share ONE global
-- domain's ticket counter (every user reads them, so "who owns this
-- ticket" is meaningless for them), while every other table's ticket
-- comes from the caller's OWN domain (household or solo). See the header
-- comment above for why one scalar cursor across both is wrong.
create or replace function public.pull_changes(p_cursor bigint default 0, p_global_cursor bigint default 0)
returns table (payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
language plpgsql
security invoker
stable
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());

  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.sync_seq > p_cursor), '[]'::jsonb),
    'transactions', coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where t.sync_seq > p_cursor), '[]'::jsonb),
    'balance_snapshots', coalesce((select jsonb_agg(to_jsonb(bs)) from public.balance_snapshots bs where bs.sync_seq > p_cursor), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(to_jsonb(c)) from public.categories c where c.sync_seq > p_cursor), '[]'::jsonb),
    'currencies', coalesce((select jsonb_agg(to_jsonb(cur)) from public.currencies cur where cur.sync_seq > p_global_cursor), '[]'::jsonb),
    'fx_rates', coalesce((select jsonb_agg(to_jsonb(fr)) from public.fx_rates fr where fr.sync_seq > p_global_cursor), '[]'::jsonb),
    'budgets', coalesce((select jsonb_agg(to_jsonb(bud)) from public.budgets bud where bud.sync_seq > p_cursor), '[]'::jsonb),
    'fi_settings', coalesce((select jsonb_agg(to_jsonb(fs)) from public.fi_settings fs where fs.sync_seq > p_cursor), '[]'::jsonb),
    'recurring_rules', coalesce((select jsonb_agg(to_jsonb(rr)) from public.recurring_rules rr where rr.sync_seq > p_cursor), '[]'::jsonb),
    'card_mappings', coalesce((select jsonb_agg(to_jsonb(cm)) from public.card_mappings cm where cm.sync_seq > p_cursor), '[]'::jsonb),
    'merchant_category_map', coalesce((select jsonb_agg(to_jsonb(mcm)) from public.merchant_category_map mcm where mcm.sync_seq > p_cursor), '[]'::jsonb),
    'sync_conflicts', coalesce((select jsonb_agg(to_jsonb(sc)) from public.sync_conflicts sc where sc.sync_seq > p_cursor), '[]'::jsonb),
    'households', coalesce((select jsonb_agg(to_jsonb(h)) from public.households h where h.sync_seq > p_cursor), '[]'::jsonb),
    'household_members', coalesce((select jsonb_agg(to_jsonb(hm)) from public.household_members hm where hm.sync_seq > p_cursor), '[]'::jsonb),
    'household_accounts', coalesce((select jsonb_agg(to_jsonb(ha)) from public.household_accounts ha where ha.sync_seq > p_cursor), '[]'::jsonb),
    'profiles', coalesce((select jsonb_agg(to_jsonb(p)) from public.profiles p where p.sync_seq > p_cursor), '[]'::jsonb)
  ) into v_payload;

  select coalesce(max(m), p_cursor) into v_next_cursor from (
    select max(sync_seq) as m from public.accounts where sync_seq > p_cursor
    union all select max(sync_seq) from public.transactions where sync_seq > p_cursor
    union all select max(sync_seq) from public.balance_snapshots where sync_seq > p_cursor
    union all select max(sync_seq) from public.categories where sync_seq > p_cursor
    union all select max(sync_seq) from public.budgets where sync_seq > p_cursor
    union all select max(sync_seq) from public.fi_settings where sync_seq > p_cursor
    union all select max(sync_seq) from public.recurring_rules where sync_seq > p_cursor
    union all select max(sync_seq) from public.card_mappings where sync_seq > p_cursor
    union all select max(sync_seq) from public.merchant_category_map where sync_seq > p_cursor
    union all select max(sync_seq) from public.sync_conflicts where sync_seq > p_cursor
    union all select max(sync_seq) from public.households where sync_seq > p_cursor
    union all select max(sync_seq) from public.household_members where sync_seq > p_cursor
    union all select max(sync_seq) from public.household_accounts where sync_seq > p_cursor
    union all select max(sync_seq) from public.profiles where sync_seq > p_cursor
  ) s;

  select coalesce(max(m), p_global_cursor) into v_next_global_cursor from (
    select max(sync_seq) as m from public.currencies where sync_seq > p_global_cursor
    union all select max(sync_seq) from public.fx_rates where sync_seq > p_global_cursor
  ) g;

  return query select v_payload, v_next_cursor, v_next_global_cursor, v_epoch;
end;
$$;

grant execute on function public.pull_changes(bigint, bigint) to authenticated;
