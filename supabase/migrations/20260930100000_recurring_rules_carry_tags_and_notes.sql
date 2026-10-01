-- ============================================================================
-- A recurring rule carries tags and a note, like the transaction it becomes.
--
-- A rule is a transaction seen before it happens, and the redesign made that
-- true of every part of the form except these two: the user could tag and
-- annotate a rent payment they typed, but not the standing instruction that
-- files one every month — so a tag-based view of spending had a hole in it
-- exactly where the predictable spending lives.
--
-- Both are carried onto **every** occurrence at materialization. That is the
-- point of putting them on the rule: a note typed once appears on all twelve
-- of next year's rows, and a tag applied once keeps the tag's own totals
-- honest without the user re-tagging every month.
--
-- **A transfer is tagged on its outflow leg only**, the same rule
-- `TransactionFormView.applyTagChanges` already follows for a hand-entered
-- one: both legs are real rows, so tagging both would make any future sum
-- over a tag count one £100 transfer as £200. The note goes on both legs,
-- matching `create_transfer`'s own `p_notes`, because a note is prose about
-- the movement rather than a figure anything sums.
-- ============================================================================

alter table recurring_rules add column notes text;

comment on column recurring_rules.notes is
  'Copied onto every transaction this rule materializes, exactly as typed. '
  'Mirrors transactions.notes, which is where it lands.';

-- ============================================================================
-- recurring_rule_tags — the same shape as `transaction_tags`, because it is
-- the same relationship one step earlier.
--
-- Deliberately a second table rather than a `taggable_id`/`taggable_type`
-- pair over one: the composite FKs this schema leans on everywhere
-- ((account_id, owner_id), (category_id, owner_id)) cannot be expressed
-- against a polymorphic parent, and a join table that cannot state its own
-- referential integrity is how a tag ends up pointing at a rule that no
-- longer exists.
-- ============================================================================

create table recurring_rule_tags (
  recurring_rule_id uuid not null references recurring_rules (id) deferrable initially deferred,
  tag_id uuid not null references tags (id) deferrable initially deferred,
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  sync_seq bigint not null default 0,
  primary key (recurring_rule_id, tag_id)
);

alter table recurring_rule_tags enable row level security;

create index recurring_rule_tags_tag_idx on recurring_rule_tags (tag_id) where deleted_at is null;
create index recurring_rule_tags_owner_idx on recurring_rule_tags (owner_id);
create index recurring_rule_tags_sync_seq_idx on recurring_rule_tags (sync_seq);

-- Visible and writable exactly when the rule is — `recurring_rules_select`
-- and `_update`'s own conditions, restated. A rule always has an account
-- (unlike a transaction, which can be a pending capture with none), so there
-- is no second branch to mirror here.
create policy recurring_rule_tags_select on recurring_rule_tags
  for select to authenticated
  using (
    exists (
      select 1 from recurring_rules r
      where r.id = recurring_rule_tags.recurring_rule_id
        and can_read_account(r.account_id)
        and (r.to_account_id is null or can_read_account(r.to_account_id))
    )
  );

create policy recurring_rule_tags_insert on recurring_rule_tags
  for insert to authenticated
  with check (
    can_read_tag(tag_id)
    and exists (
      select 1 from recurring_rules r
      where r.id = recurring_rule_tags.recurring_rule_id
        and can_write_account(r.account_id)
        and (r.to_account_id is null or can_write_account(r.to_account_id))
    )
  );

create policy recurring_rule_tags_update on recurring_rule_tags
  for update to authenticated
  using (
    exists (
      select 1 from recurring_rules r
      where r.id = recurring_rule_tags.recurring_rule_id
        and can_write_account(r.account_id)
        and (r.to_account_id is null or can_write_account(r.to_account_id))
    )
  )
  with check (
    exists (
      select 1 from recurring_rules r
      where r.id = recurring_rule_tags.recurring_rule_id
        and can_write_account(r.account_id)
        and (r.to_account_id is null or can_write_account(r.to_account_id))
    )
  );

-- RLS grants nothing (CLAUDE.md).
grant select, insert, update on recurring_rule_tags to authenticated, service_role;

-- `owner_id` from the rule, never from the client — same reasoning as
-- `set_transaction_tag_derived_columns`: it has to match for
-- `stamp_sync_seq_owner()` to file the row in the right sync domain, and a
-- client-supplied value could put a household member's tagging of a shared
-- rule into their own domain, where the account's owner would never pull it.
create function set_recurring_rule_tag_derived_columns()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule_owner uuid;
begin
  select owner_id into v_rule_owner
  from public.recurring_rules where id = new.recurring_rule_id;

  if v_rule_owner is null then
    raise exception 'recurring rule % not found', new.recurring_rule_id;
  end if;

  new.owner_id := v_rule_owner;

  -- A row on its way out is not re-validated, for the reason
  -- `set_transaction_tag_derived_columns` gives: the tag cascade soft-deletes
  -- the tag first, so this lookup would not find it.
  if new.deleted_at is not null then
    return new;
  end if;

  if not exists (select 1 from public.tags where id = new.tag_id and deleted_at is null) then
    raise exception 'tag % not found', new.tag_id;
  end if;

  return new;
end;
$$;

revoke all on function set_recurring_rule_tag_derived_columns() from public;

create trigger recurring_rule_tags_set_derived
  before insert or update on recurring_rule_tags
  for each row execute function set_recurring_rule_tag_derived_columns();

create trigger recurring_rule_tags_set_updated_at
  before update on recurring_rule_tags
  for each row execute function set_updated_at();

create trigger recurring_rule_tags_stamp_sync_seq
  before insert or update on recurring_rule_tags
  for each row execute function stamp_sync_seq_owner();

-- ============================================================================
-- cascade_tag_soft_delete — the rule links go when the tag does.
--
-- Restated from `20260918100000` (its own latest definition) with the second
-- statement added. Without it, deleting a tag would leave live
-- `recurring_rule_tags` rows pointing at a tombstone, and every future
-- occurrence would keep being stamped with a tag the user deleted — the same
-- shape of leak as the orphaned-category one 20260929100000 closed.
-- ============================================================================

create or replace function cascade_tag_soft_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.household_sharing_tag(new.id);
begin
  update public.transaction_tags
  set deleted_at = new.deleted_at, updated_at = now()
  where tag_id = new.id and deleted_at is null;

  -- The same cascade one step earlier. Without it a deleted tag would keep
  -- being stamped onto every future occurrence of every rule wearing it.
  update public.recurring_rule_tags
  set deleted_at = new.deleted_at, updated_at = now()
  where tag_id = new.id and deleted_at is null;

  -- The links this just retired were the other member's only claim on the
  -- tag. Their device cannot be told incrementally that a row it holds has
  -- stopped existing for it, so both members re-pull.
  if v_household_id is not null then
    perform public.bump_household_sync_epochs(v_household_id);
  end if;

  return null;
end;
$$;

revoke all on function cascade_tag_soft_delete() from public;


-- ============================================================================
-- materialize_recurring — carries the note and the tags onto what it mints.
--
-- The tag insert is `on conflict do nothing` for the same reason the
-- transaction insert above it is: a re-run must not fail on links it already
-- created. It reads the rule's **live** links each time rather than a
-- snapshot, so retagging a rule changes future occurrences and leaves past
-- ones alone — which is what "edit all future occurrences" already means
-- everywhere else in this feature.
-- ============================================================================

create or replace function public.materialize_recurring(p_through date default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule record;
  v_occurrence date;
  v_inserted integer := 0;
  v_group uuid;
  v_currency text;
  v_to_currency text;
  v_tz text;
  v_at timestamptz;
  v_through date;
  v_dormant boolean;
  v_new_id uuid;
begin
  for v_rule in
    select * from public.recurring_rules where active
    order by id
    for update
  loop
    select public.safe_time_zone(p.time_zone) into v_tz
    from public.profiles p where p.id = v_rule.owner_id;
    v_tz := coalesce(v_tz, 'UTC');

    v_through := coalesce(p_through, (now() at time zone v_tz)::date);

    continue when v_rule.next_due_at > v_through;

    select not (
      a.deleted_at is null and a.archived_at is null
      and (v_rule.to_account_id is null or (d.deleted_at is null and d.archived_at is null))
    )
    into v_dormant
    from public.accounts a
    left join public.accounts d on d.id = v_rule.to_account_id
    where a.id = v_rule.account_id;
    v_dormant := coalesce(v_dormant, true);

    select currency into v_currency from public.accounts where id = v_rule.account_id;
    v_to_currency := null;
    if v_rule.to_account_id is not null then
      select currency into v_to_currency from public.accounts where id = v_rule.to_account_id;
    end if;

    v_occurrence := v_rule.next_due_at;

    while v_occurrence <= v_through loop
      v_at := v_occurrence::timestamp at time zone v_tz;
      v_new_id := null;

      if v_dormant then
        null;
      elsif v_rule.to_account_id is null then
        insert into public.transactions (
          id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
          notes, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id, v_rule.category_id,
          v_rule.amount_e4, v_currency, v_at,
          v_rule.notes, 'recurring', v_rule.id::text || '|' || v_occurrence::text, v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing
        returning id into v_new_id;

        if v_new_id is not null then
          v_inserted := v_inserted + 1;
        end if;
      else
        v_group := gen_random_uuid();

        -- The outflow leg, and the only one that gets tagged.
        insert into public.transactions (
          id, owner_id, created_by, account_id, amount_e4, currency, occurred_at,
          notes, transfer_group_id, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id,
          v_rule.amount_e4, v_currency, v_at,
          v_rule.notes, v_group, 'recurring', v_rule.id::text || '|' || v_occurrence::text || '|from', v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing
        returning id into v_new_id;

        if v_new_id is not null then
          v_inserted := v_inserted + 1;
        end if;

        insert into public.transactions (
          id, owner_id, created_by, account_id, amount_e4, currency, occurred_at,
          notes, transfer_group_id, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.to_account_id,
          -v_rule.amount_e4, v_to_currency, v_at,
          v_rule.notes, v_group, 'recurring', v_rule.id::text || '|' || v_occurrence::text || '|to', v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing;

        if found then
          v_inserted := v_inserted + 1;
        end if;
      end if;

      -- `v_new_id` is null when the row was already there (a re-run), so the
      -- links are not rewritten either — the whole occurrence is a no-op.
      if v_new_id is not null then
        insert into public.transaction_tags (transaction_id, tag_id, owner_id)
        select v_new_id, rt.tag_id, v_rule.owner_id
        from public.recurring_rule_tags rt
        join public.tags tg on tg.id = rt.tag_id and tg.deleted_at is null
        where rt.recurring_rule_id = v_rule.id and rt.deleted_at is null
        on conflict (transaction_id, tag_id) do nothing;
      end if;

      v_occurrence := public.next_occurrence_date(v_occurrence, v_rule.frequency);
    end loop;

    update public.recurring_rules
    set next_due_at = v_occurrence, last_materialized_at = v_through
    where id = v_rule.id;
  end loop;

  return v_inserted;
end;
$$;

revoke all on function public.materialize_recurring(date) from public;
grant execute on function public.materialize_recurring(date) to service_role;

-- ============================================================================
-- pull_changes — the new table joins the payload.
--
-- Restated from `20260916100000` (its latest definition). `security invoker`
-- is deliberate and load-bearing: as `definer` this would hand every user
-- every row. Noted because a previous restatement of this function got that
-- exact thing wrong — see the 2026-09-03 account-deletion entry in
-- `keepo-v1-master-plan.md`.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pull_changes(p_cursor bigint DEFAULT 0, p_global_cursor bigint DEFAULT 0)
 RETURNS TABLE(payload jsonb, next_cursor bigint, next_global_cursor bigint, sync_epoch bigint)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_payload jsonb;
  v_next_cursor bigint;
  v_next_global_cursor bigint;
  v_epoch bigint;
begin
  if not public.ops_check_own_rate_limit('pull_changes', 120, 60) then
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
    'recurring_rule_tags', coalesce((select jsonb_agg(to_jsonb(rt)) from public.recurring_rule_tags rt where rt.sync_seq > p_cursor), '[]'::jsonb),
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
    union all select max(sync_seq) from public.recurring_rule_tags where sync_seq > p_cursor
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
$function$;

revoke all on function public.pull_changes(bigint, bigint) from public;
grant execute on function public.pull_changes(bigint, bigint) to authenticated;

-- ============================================================================
-- delete_tag_retagging — a merge moves the rule links too.
--
-- Extracted verbatim from `20260922100000` (its latest definition — the first
-- draft here used `20260918100000`'s, which predates the household tag-prune
-- undo and reverted it; the pgTAP suite caught that immediately) with one
-- block added and nothing else changed.
--
-- **The prune-undo log is deliberately not widened.**
-- `household_retagged_links` restores links by `(transaction_id, tag_id)` and
-- has no column for a rule, so a rule's tag is not restored by discarding a
-- household. That is a gap in the *undo* feature rather than in this one, and
-- closing it means a schema change to that table — out of scope here, and
-- recorded rather than silently half-done.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.delete_tag_retagging(p_tag_id uuid, p_into_tag_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_tag public.tags;
  v_into public.tags;
  v_moved integer := 0;
  v_revoked_for uuid := public.household_sharing_tag(p_tag_id);
  v_prune_id bigint;
begin
  select * into v_tag from public.tags where id = p_tag_id and deleted_at is null;
  if v_tag.id is null then
    raise exception 'tag not found';
  end if;

  -- Your own tag needs no household at all: this is also the path the Tags
  -- screen uses to merge two of your own duplicates.
  if v_tag.owner_id <> v_me then
    if v_household_id is null then
      raise exception 'tag not found';
    end if;
    if public.household_owner_id(v_household_id) <> v_me then
      raise exception 'only the household owner can delete another member''s tag';
    end if;
    if not exists (
      select 1 from public.household_members
      where household_id = v_household_id and user_id = v_tag.owner_id and deleted_at is null
    ) then
      raise exception 'tag not found';
    end if;
  end if;

  if v_household_id is not null then
    insert into public.household_pruned_tags (household_id, tag_id)
    values (v_household_id, p_tag_id)
    returning id into v_prune_id;
  end if;

  if p_into_tag_id is not null then
    if p_into_tag_id = p_tag_id then
      raise exception 'a tag cannot be re-tagged into itself';
    end if;

    select * into v_into from public.tags where id = p_into_tag_id and deleted_at is null;
    if v_into.id is null then
      raise exception 'destination tag not found';
    end if;

    -- The destination has to be usable by whoever owns the transactions being
    -- moved. `transaction_tags.owner_id` comes from the transaction, and
    -- `transaction_tags_insert` demands `can_read_tag(tag_id)` — a
    -- destination the transaction's owner cannot read would produce rows the
    -- app can never show them again.
    if v_into.owner_id <> v_tag.owner_id and not exists (
      select 1
      from public.household_members mine
      join public.household_members theirs on theirs.household_id = mine.household_id
      where mine.user_id = v_tag.owner_id and mine.deleted_at is null
        and theirs.user_id = v_into.owner_id and theirs.deleted_at is null
    ) then
      raise exception 'destination tag belongs to neither member of this household';
    end if;

    -- `transaction_tags`' primary key is `(transaction_id, tag_id)`, and its
    -- rows are **soft**-deleted like everything else here — so a transaction
    -- that once wore the destination tag and had it removed still holds a
    -- tombstone on exactly the key a move would land on. Updating into it
    -- raises a unique violation; hard-deleting the tombstone would strand
    -- the other device, which pulls tombstones as ordinary rows.
    --
    -- Reviving it is the move, for those transactions. Three statements, in
    -- this order: revive what would collide, retire the sources that are now
    -- redundant, then move whatever is left onto a free key.
    with targets as (
      select dest.transaction_id, dest.tag_id, dest.deleted_at as prev_deleted_at
      from public.transaction_tags dest
      where dest.tag_id = p_into_tag_id
        and dest.deleted_at is not null
        and exists (
          select 1 from public.transaction_tags src
          where src.transaction_id = dest.transaction_id
            and src.tag_id = p_tag_id
            and src.deleted_at is null
        )
    ), logged as (
      insert into public.household_retagged_links
        (prune_id, transaction_id, tag_id, prev_tag_id, prev_deleted_at)
      select v_prune_id, t.transaction_id, t.tag_id, t.tag_id, t.prev_deleted_at
      from targets t where v_prune_id is not null
      returning 1
    ), revived as (
      update public.transaction_tags dest
      set deleted_at = null
      from targets t
      where dest.transaction_id = t.transaction_id and dest.tag_id = t.tag_id
      returning 1
    )
    select count(*) into v_moved from revived;

    with targets as (
      select tt.transaction_id, tt.tag_id
      from public.transaction_tags tt
      where tt.tag_id = p_tag_id and tt.deleted_at is null
        and exists (
          select 1 from public.transaction_tags other
          where other.transaction_id = tt.transaction_id
            and other.tag_id = p_into_tag_id
            and other.deleted_at is null
        )
    ), logged as (
      insert into public.household_retagged_links
        (prune_id, transaction_id, tag_id, prev_tag_id, prev_deleted_at)
      select v_prune_id, t.transaction_id, t.tag_id, t.tag_id, null
      from targets t where v_prune_id is not null
      returning 1
    )
    update public.transaction_tags tt
    set deleted_at = now()
    from targets t
    where tt.transaction_id = t.transaction_id and tt.tag_id = t.tag_id;

    -- Logged against the key the row is about to have, which is what the undo
    -- looks it up by.
    with targets as (
      select tt.transaction_id from public.transaction_tags tt
      where tt.tag_id = p_tag_id and tt.deleted_at is null
    ), logged as (
      insert into public.household_retagged_links
        (prune_id, transaction_id, tag_id, prev_tag_id, prev_deleted_at)
      select v_prune_id, t.transaction_id, p_into_tag_id, p_tag_id, null
      from targets t where v_prune_id is not null
      returning 1
    ), moved as (
      update public.transaction_tags tt
      set tag_id = p_into_tag_id
      from targets t
      where tt.transaction_id = t.transaction_id and tt.tag_id = p_tag_id
      returning 1
    )
    select v_moved + count(*) into v_moved from moved;

    -- The same revive / retire / move sequence for the rule links, in the
    -- same order and for the same reason:
    -- `(recurring_rule_id, tag_id)` is a primary key whose rows are
    -- soft-deleted, so a rule that once wore the destination tag holds a
    -- tombstone on exactly the key a move would land on. Without this,
    -- merging two tags would leave the rule on the source tag, which the
    -- tombstone below then cascades away — the rule would silently stop
    -- tagging what it mints while the transactions it already made keep
    -- theirs.
    --
    -- Not logged to `household_retagged_links` and not added to `v_moved`:
    -- both are about transactions. The undo path restores links by
    -- `(transaction_id, tag_id)` and has no column for a rule, so widening it
    -- is a change to that feature rather than a line here — noted in the
    -- migration header.
    update public.recurring_rule_tags dest
    set deleted_at = null
    where dest.tag_id = p_into_tag_id
      and dest.deleted_at is not null
      and exists (
        select 1 from public.recurring_rule_tags src
        where src.recurring_rule_id = dest.recurring_rule_id
          and src.tag_id = p_tag_id
          and src.deleted_at is null
      );

    update public.recurring_rule_tags rt
    set deleted_at = now()
    where rt.tag_id = p_tag_id and rt.deleted_at is null
      and exists (
        select 1 from public.recurring_rule_tags other
        where other.recurring_rule_id = rt.recurring_rule_id
          and other.tag_id = p_into_tag_id
          and other.deleted_at is null
      );

    update public.recurring_rule_tags
    set tag_id = p_into_tag_id
    where tag_id = p_tag_id and deleted_at is null;
  end if;

  -- Last, so `cascade_tag_soft_delete` finds only the links that genuinely
  -- had nowhere to go.
  update public.tags set deleted_at = now() where id = p_tag_id;

  -- The tag has stopped being visible to whoever was seeing it through a
  -- shared account — including, on the report's own path, the member who
  -- pressed the button. An incremental pull cannot deliver "a row you hold
  -- is no longer yours to see", so both members re-pull in full.
  if v_revoked_for is not null then
    perform public.bump_household_sync_epochs(v_revoked_for);
  end if;

  return v_moved;
end;
$function$;

revoke all on function delete_tag_retagging(uuid, uuid) from public;
grant execute on function delete_tag_retagging(uuid, uuid) to authenticated, service_role;

-- ============================================================================
-- GDPR erasure — the new link table joins the registry and the delete order.
--
-- `unregistered_identity_columns()` refused the migration until it did, which
-- is the registry working exactly as designed: a new table carrying an
-- identity column cannot be added without someone deciding what erasure does
-- with it. Caught by the pgTAP suite on the first run, not by review.
--
-- `delete_owned`, like `transaction_tags`: a link between a rule and a tag
-- both of which are the leaving user's own. The delete is ordered **before**
-- `transaction_tags` for the reason every line there is ordered — children
-- first — since this table's foreign keys point at `recurring_rules` and
-- `tags`, both deleted further down.
-- ============================================================================

insert into deletion_handled_columns (table_name, column_name, handling) values
  ('recurring_rule_tags', 'owner_id', 'delete_owned');

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
  delete from public.recurring_rule_tags where owner_id = v_me;
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
grant execute on function delete_own_account() to authenticated;
