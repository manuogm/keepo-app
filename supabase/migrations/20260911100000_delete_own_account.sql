-- Account deletion — App Store Review Guideline 5.1.1(v), and GDPR Art. 17.
--
-- Immediate and irreversible: no grace period, no "your account will be
-- deleted in 30 days" mail. The client already puts a biometric step-up and a
-- confirmation dialog in front of it, which is where the friction belongs.
--
-- **The hard part is not deleting rows, it is deleting rows a second person
-- also has a claim on.** A household shares accounts and their whole
-- transaction history. Deleting the leaver's copy outright would take that
-- history away from the member who stays, who did nothing and consented to
-- nothing. So deletion **forks first** — the same fork `leave_household()`
-- already performs — and only then destroys what is, by then, exclusively the
-- leaver's.
--
-- This function deliberately does **not** delete `auth.users`. That is the
-- `delete-account` Edge Function's job, through `auth.admin.deleteUser`: the
-- supported API, maintained by the platform, rather than this migration
-- reaching into the `auth` schema and hoping a future GoTrue release keeps
-- every child table's cascade intact.
--
-- `ops_events` was checked and carries no identity: its only writer is
-- `ops_http_post`, whose `detail` is `{"url_secret": ...}`. Nothing to scrub.

-- ============================================================================
-- Housekeeping: `fork_handled_tables` still names the two CSV import tables
-- that 20260909100000 dropped. Harmless to the guard, which only asks whether
-- existing tables are registered — but a registry whose entire job is to be
-- an accurate account of reality should not carry two rows that are not.
-- ============================================================================

delete from fork_handled_tables where table_name in ('csv_import_batches', 'csv_import_candidates');

-- ============================================================================
-- `household_events.actor_id` becomes nullable.
--
-- The event is the *other* member's record that something happened to their
-- household — they had accounts forked out from under them and are entitled
-- to see why. But `actor_id` FKs to `auth.users`, so it cannot survive the
-- deletion as it stands, and dropping the row entirely would erase the
-- explanation along with the identity.
--
-- Nulling it keeps the event and destroys the person: "a member erased their
-- data", with no id attached. `HouseholdEventsSection` renders `kind` alone,
-- so nothing on screen changes.
-- ============================================================================

alter table household_events alter column actor_id drop not null;

comment on column household_events.actor_id is
  'Null once that member deleted their account — the event survives, the identity does not.';

-- ============================================================================
-- deletion_handled_columns — the mechanical answer to "deletion grows with
-- every table added after it", and the direct descendant of
-- `fork_handled_tables` (20260810100000).
--
-- Keyed by **column**, not table, which is the one thing its ancestor cannot
-- express: `transactions` carries both `owner_id` and `created_by` and they
-- are handled oppositely — one is destroyed, the other is rewritten to point
-- at whoever now owns the row. A table-level registry would call
-- `transactions` "handled" and say nothing about the column that actually
-- blocks the auth delete.
--
--   delete_owned      — every row whose column is the leaver is destroyed
--   reassign_to_owner — the column is rewritten to the row's own `owner_id`,
--                       for rows that survive because someone else owns them.
--                       **This is what makes the auth delete possible at
--                       all**: after the fork, the other member's copies still
--                       carry `created_by = the leaver`, and that FK refuses
--                       the delete with nothing pointing at the cause.
--   scrubbed          — the row stays, the identity is nulled
-- ============================================================================

create table deletion_handled_columns (
  table_name text not null,
  column_name text not null,
  handling text not null check (handling in ('delete_owned', 'reassign_to_owner', 'scrubbed')),
  primary key (table_name, column_name)
);

insert into deletion_handled_columns (table_name, column_name, handling) values
  ('profiles', 'id', 'delete_owned'),
  ('accounts', 'owner_id', 'delete_owned'),
  ('accounts', 'created_by', 'reassign_to_owner'),
  ('categories', 'owner_id', 'delete_owned'),
  ('transactions', 'owner_id', 'delete_owned'),
  ('transactions', 'created_by', 'reassign_to_owner'),
  ('recurring_rules', 'owner_id', 'delete_owned'),
  ('recurring_rules', 'created_by', 'reassign_to_owner'),
  ('tags', 'owner_id', 'delete_owned'),
  ('transaction_tags', 'owner_id', 'delete_owned'),
  ('card_mappings', 'owner_id', 'delete_owned'),
  ('merchant_category_map', 'owner_id', 'delete_owned'),
  ('net_worth_daily', 'owner_id', 'delete_owned'),
  ('sync_conflicts', 'owner_id', 'delete_owned'),
  ('export_audit_log', 'owner_id', 'delete_owned'),
  ('household_members', 'user_id', 'delete_owned'),
  ('household_invites', 'invited_by', 'delete_owned'),
  ('household_events', 'actor_id', 'scrubbed'),
  ('ops_rate_limits', 'subject', 'delete_owned');

alter table deletion_handled_columns enable row level security;

-- Same posture as `fork_handled_tables`: readable so a client could show what
-- deletion covers, never writable from outside a migration.
create policy deletion_handled_columns_select on deletion_handled_columns
  for select to authenticated
  using (true);

grant select on deletion_handled_columns to authenticated, service_role;

-- ============================================================================
-- The guard, as a function so the test suite can call it without deleting
-- anybody.
--
-- Two independent sweeps, unioned, because either alone has a blind spot:
--
--   * **Every column with a foreign key to `auth.users`.** This is the set
--     that can actually refuse the delete, and it catches a column whatever
--     it is called — `profiles.id` names the user without saying so, and a
--     name-matching guard would sail straight past it.
--   * **Every column named like an owner.** Catches the ones with no FK at
--     all: `ops_rate_limits.subject` is the user's id as `text`, invisible to
--     the constraint catalogue and invisible to a cascade, and would have sat
--     there holding a deleted user's id forever.
-- ============================================================================

create or replace function unregistered_identity_columns()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select string_agg(q.table_name || '.' || q.column_name, ', ' order by q.table_name, q.column_name)
  from (
    select cl.relname as table_name, att.attname as column_name
    from pg_constraint con
    join pg_class cl on cl.oid = con.conrelid
    join pg_namespace ns on ns.oid = cl.relnamespace
    join unnest(con.conkey) as k(attnum) on true
    join pg_attribute att on att.attrelid = con.conrelid and att.attnum = k.attnum
    where con.confrelid = 'auth.users'::regclass and con.contype = 'f' and ns.nspname = 'public'

    union

    select c.table_name, c.column_name
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.table_schema = 'public' and t.table_type = 'BASE TABLE'
      and c.column_name in ('owner_id', 'created_by', 'user_id', 'actor_id', 'invited_by', 'subject')
  ) q
  where not exists (
    select 1 from public.deletion_handled_columns d
    where d.table_name = q.table_name and d.column_name = q.column_name
  );
$$;

revoke all on function unregistered_identity_columns() from public;
grant execute on function unregistered_identity_columns() to authenticated, service_role;

-- ============================================================================
-- delete_own_account()
--
-- **Zero parameters, on purpose.** The identity comes from `auth.uid()` and
-- nowhere else. An RPC that takes a user id is an RPC that deletes somebody
-- else's account the day a policy is wrong, and there is no undo behind it.
-- ============================================================================

create or replace function delete_own_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := (select auth.uid());
  v_household_id uuid;
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

  -- Read before `erase_own_account` removes the membership that answers it.
  v_household_id := public.my_household_id();

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

  -- The event stays, the person goes. See the ALTER above.
  update public.household_events set actor_id = null where actor_id = v_me;

  -- An invitation from an account that no longer exists cannot be accepted.
  delete from public.household_invites where invited_by = v_me;

  -- `erase_own_account` soft-deletes this, so a rejoin can reactivate the
  -- same row. There is no rejoining from here, and a soft-deleted row holds
  -- the foreign key just as firmly as a live one.
  delete from public.household_members where user_id = v_me;

  -- A household with nobody in it is not a household. Soft-deleted rather
  -- than dropped so the remaining member's next pull sees a tombstone instead
  -- of a row that silently vanished — the same reasoning as a departure.
  if v_household_id is not null and not exists (
    select 1 from public.household_members
    where household_id = v_household_id and deleted_at is null
  ) then
    update public.households set deleted_at = now()
    where id = v_household_id and deleted_at is null;
  end if;

  -- Children first, all the way down. Each line is here because something
  -- below it has a foreign key pointing at it.
  delete from public.export_audit_log where owner_id = v_me;
  delete from public.merchant_category_map where owner_id = v_me;
  delete from public.card_mappings where owner_id = v_me;
  delete from public.transaction_tags where owner_id = v_me;
  delete from public.tags where owner_id = v_me;
  delete from public.recurring_rules where owner_id = v_me;
  delete from public.net_worth_daily where owner_id = v_me;
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

revoke all on function delete_own_account() from public;
grant execute on function delete_own_account() to authenticated, service_role;

-- ============================================================================
-- `pull_changes` tolerates a profile that is gone.
--
-- Deletion creates exactly this state on purpose, and a device that was
-- offline when it happened comes back and pulls with a session that still
-- looks valid. `v_epoch` was `null` there, and the client decodes
-- `sync_epoch` as a non-optional `Int64` — so the last thing a deleted
-- account ever showed its owner was "Couldn't connect", on a screen full of
-- data that no longer exists anywhere.
--
-- Zero is a value no live profile can hold (`sync_epoch` starts at 1 and only
-- rises), so the client can tell "your account is gone" from "you are behind"
-- without a second round trip.
-- ============================================================================

create or replace function pull_changes(p_cursor bigint default 0, p_global_cursor bigint default 0)
returns table (payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
language plpgsql
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  if not public.ops_check_own_rate_limit('pull_changes', 30, 60) then
    raise exception 'rate limit exceeded';
  end if;

  select p.sync_epoch into v_epoch from public.profiles p where p.id = (select auth.uid());
  v_epoch := coalesce(v_epoch, 0);

  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.sync_seq > p_cursor), '[]'::jsonb),
    'transactions', coalesce((select jsonb_agg(to_jsonb(t)) from public.transactions t where t.sync_seq > p_cursor), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(to_jsonb(c)) from public.categories c where c.sync_seq > p_cursor), '[]'::jsonb),
    'currencies', coalesce((select jsonb_agg(to_jsonb(cur)) from public.currencies cur where cur.sync_seq > p_global_cursor), '[]'::jsonb),
    'fx_rates', coalesce((
      select jsonb_agg(to_jsonb(fr) || jsonb_build_object('units_per_eur', fr.units_per_eur::text))
      from public.fx_rates fr where fr.sync_seq > p_global_cursor
    ), '[]'::jsonb),
    'tags', coalesce((select jsonb_agg(to_jsonb(tg)) from public.tags tg where tg.sync_seq > p_cursor), '[]'::jsonb),
    'transaction_tags', coalesce((select jsonb_agg(to_jsonb(tt)) from public.transaction_tags tt where tt.sync_seq > p_cursor), '[]'::jsonb),
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
    union all select max(sync_seq) from public.categories where sync_seq > p_cursor
    union all select max(sync_seq) from public.tags where sync_seq > p_cursor
    union all select max(sync_seq) from public.transaction_tags where sync_seq > p_cursor
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

revoke all on function pull_changes(bigint, bigint) from public;
grant execute on function pull_changes(bigint, bigint) to authenticated;
