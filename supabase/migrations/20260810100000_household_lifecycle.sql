-- Phase 19: household lifecycle — invites, category merge at formation,
-- leave/fork, erasure, and the forkable-table registry that keeps fork
-- correct as the schema grows.
--
-- Fork model: leaving a household is a SPLIT, not a transfer of ownership.
-- Every account shared in the household gets forked into TWO fresh, private
-- copies — one per member, both seeded with a full replica of the shared
-- history — and the original shared account is archived, never deleted (its
-- rows stay exactly as they were, for audit continuity; it simply drops out
-- of household_accounts and both members' active balances). The caller's
-- own household_members row is the only one removed — the remaining member
-- keeps their household (now single-member again, the same state Phase 7
-- already handles for a brand-new household before any invite is ever
-- accepted). "Deleting that row is the entire revocation" (spec) reads
-- correctly under this model: revocation of SHARING, not dissolution of
-- the household record itself.
--
-- A forked transfer leg cannot keep its transfer_group_id: the sibling leg
-- (on the OTHER account of the pair) isn't being duplicated unless that
-- account happens to also be shared in the same household, and
-- check_transfer_integrity's deferred constraint requires exactly 0 or 2
-- legs per group. Rather than special-case "is the sibling also forking,"
-- every forked transfer leg becomes a plain adjustment-sourced entry
-- (source = 'adjustment', category = the new owner's own
-- adjustment_expense/adjustment_income system category) carrying the same
-- signed amount — the new copy's balance is identical the moment it's
-- created; only the "this used to be a transfer" provenance is lost, which
-- is an acceptable, clearly-documented simplification for a feature this
-- deep in the plan.

-- ============================================================================
-- fork_handled_tables — the mechanical answer to "fork grows with every
-- table added after it." leave_household()/erase_own_account() both query
-- information_schema directly and RAISE if any public table with an
-- account_id column isn't registered here — a real runtime check, not a
-- comment someone has to remember to update. Three handling strategies:
--   duplicate_to_both  — full replica written into each of the two new
--                        per-member accounts (shared history both sides keep)
--   repoint_by_owner   — never shared visibility (owner-scoped already,
--                        Phase 12/18 precedent); each row's account_id is
--                        repointed to *that row's own owner's* new copy
--   cache_recompute    — a derived/materialized value with no source-of-
--                        truth data of its own; rows for the old account_id
--                        are dropped and left to regenerate naturally
--   deleted_on_leave   — the join table that defines sharing itself; the
--                        row for the forking account is deleted, not forked
-- ============================================================================

create table fork_handled_tables (
  table_name text primary key,
  handling text not null check (
    handling in ('duplicate_to_both', 'repoint_by_owner', 'cache_recompute', 'deleted_on_leave')
  )
);

insert into fork_handled_tables (table_name, handling) values
  ('transactions', 'duplicate_to_both'),
  ('balance_snapshots', 'duplicate_to_both'),
  ('reconciliations', 'duplicate_to_both'),
  ('recurring_rules', 'duplicate_to_both'),
  ('net_worth_daily', 'cache_recompute'),
  ('card_mappings', 'repoint_by_owner'),
  ('csv_import_batches', 'repoint_by_owner'),
  ('csv_import_candidates', 'repoint_by_owner'),
  ('household_accounts', 'deleted_on_leave');

alter table fork_handled_tables enable row level security;

create policy fork_handled_tables_select on fork_handled_tables
  for select to authenticated
  using (true);

grant select on fork_handled_tables to authenticated, service_role;

-- ============================================================================
-- household_events — append-only notification seam. Written only by
-- accept_invite/leave_household/erase_own_account (all SECURITY DEFINER, no
-- INSERT grant to authenticated — same "write only through a vetted
-- function" precedent as sync_conflicts/fx_rates/export_audit_log).
-- notify_household() below is the no-op-transport hook Phase 20 swaps for a
-- real APNs call; the client surfaces these via Needs Review-style polling
-- (Phase 19's own HouseholdRepository) rather than a push today.
-- ============================================================================

create type household_event_kind as enum ('member_joined', 'member_left', 'member_erased');

create table household_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households (id) deferrable initially deferred,
  actor_id uuid not null references auth.users (id) deferrable initially deferred,
  kind household_event_kind not null,
  created_at timestamptz not null default now()
);

create index household_events_household_created_idx on household_events (household_id, created_at desc);

alter table household_events enable row level security;

create policy household_events_select on household_events
  for select to authenticated
  using (household_id = my_household_id());

grant select on household_events to authenticated, service_role;

-- ============================================================================
-- notify_household — the no-op-transport seam (app-architecture.md/master
-- plan: "a household_events row + a notify-household Edge Function whose
-- APNs call sits behind a no-op transport"). Fire-and-forget via
-- ops_http_post (Phase 13) exactly like sync-fx-rates/alert-operator; a
-- missing vault secret degrades to an ops_events log entry, never blocks
-- the caller's actual write.
-- ============================================================================

create function notify_household(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.ops_http_post(
    'notify_household_url', 'notify_household_secret', 'x-notify-household-secret',
    jsonb_build_object('event_id', p_event_id)
  );
end;
$$;

revoke all on function notify_household(uuid) from public;
grant execute on function notify_household(uuid) to service_role;

-- ============================================================================
-- create_invite / accept_invite — household_invites has existed as a
-- table-only stub since Phase 7. The token is generated here, returned to
-- the caller exactly once; only its SHA-256 hash is ever persisted.
-- ============================================================================

create function create_invite()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_token text;
begin
  if v_household_id is null then
    raise exception 'create a household before inviting a member';
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');

  insert into public.household_invites (household_id, invited_by, token_hash, expires_at)
  values (
    v_household_id, (select auth.uid()), encode(extensions.digest(v_token, 'sha256'), 'hex'), now() + interval '7 days'
  );

  return v_token;
end;
$$;

revoke all on function create_invite() from public;
grant execute on function create_invite() to authenticated;

-- ============================================================================
-- merge_household_categories — one-time, at formation. Category rows can
-- never literally merge (transactions.category_id's composite FK to
-- (id, owner_id) forces every category to stay owned by whoever uses it),
-- so "merge" means: give each member an equivalent, same-named category for
-- everything the other already has, so a shared account's spending can be
-- categorized consistently by name from day one. Exact case-insensitive
-- name+kind match only — near-match fuzzy suggestion (the spec's "near-
-- matches into Needs Review") is descoped; every user already has the same
-- seeded 'Other' defaults, so this never duplicates those.
--
-- Takes both member ids explicitly from accept_invite (invited_by and the
-- caller) rather than deriving "who joined first" from household_members.
-- joined_at — that column defaults to now(), and now() is frozen for an
-- entire transaction (the exact _helpers.psql gotcha this project's own
-- pgTAP harness documents); two rows inserted moments apart in the same
-- test-file transaction can tie, making an ORDER BY joined_at pick
-- unpredictable. Explicit ids have no such hazard, in tests or production.
-- ============================================================================

create function merge_household_categories(p_member_a uuid, p_member_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member_a uuid := p_member_a;
  v_member_b uuid := p_member_b;
begin
  if v_member_a is null or v_member_b is null or v_member_a = v_member_b then
    return;
  end if;

  insert into public.categories (owner_id, kind, name)
  select v_member_b, c.kind, c.name
  from public.categories c
  where c.owner_id = v_member_a and c.deleted_at is null
    and not exists (
      select 1 from public.categories mine
      where mine.owner_id = v_member_b and mine.kind = c.kind and mine.deleted_at is null
        and lower(mine.name) = lower(c.name)
    );

  insert into public.categories (owner_id, kind, name)
  select v_member_a, c.kind, c.name
  from public.categories c
  where c.owner_id = v_member_b and c.deleted_at is null
    and not exists (
      select 1 from public.categories mine
      where mine.owner_id = v_member_a and mine.kind = c.kind and mine.deleted_at is null
        and lower(mine.name) = lower(c.name)
    );
end;
$$;

revoke all on function merge_household_categories(uuid, uuid) from public;

create function accept_invite(p_token text)
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

  insert into public.household_members (household_id, user_id) values (v_invite.household_id, (select auth.uid()));

  update public.household_invites set status = 'accepted' where id = v_invite.id;

  perform public.merge_household_categories(v_invite.invited_by, (select auth.uid()));

  insert into public.household_events (household_id, actor_id, kind)
  values (v_invite.household_id, (select auth.uid()), 'member_joined')
  returning id into v_event_id;

  perform public.notify_household(v_event_id);

  return v_invite.household_id;
end;
$$;

revoke all on function accept_invite(text) from public;
grant execute on function accept_invite(text) to authenticated;

-- ============================================================================
-- fork_category_id — a forked row's category must belong to its NEW owner
-- (the same composite-FK reasoning categories has always enforced).
-- Same-name, same-kind match first (merge_household_categories should have
-- already produced one); the new owner's own 'Other' default otherwise —
-- never null, since every user has a default category for every kind.
-- ============================================================================

create function fork_category_id(p_new_owner uuid, p_original_category_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_kind public.category_kind;
  v_result uuid;
begin
  select name, kind into v_name, v_kind from public.categories where id = p_original_category_id;
  if v_name is null then
    return null;
  end if;

  select id into v_result from public.categories
  where owner_id = p_new_owner and kind = v_kind and deleted_at is null and lower(name) = lower(v_name)
  limit 1;

  if v_result is null then
    select id into v_result from public.categories
    where owner_id = p_new_owner and kind = v_kind and is_default and deleted_at is null
    limit 1;
  end if;

  return v_result;
end;
$$;

revoke all on function fork_category_id(uuid, uuid) from public;

-- ============================================================================
-- fork_household_accounts — the core split, shared by leave_household() and
-- erase_own_account(). Runs the registry check first (Finding-worthy: this
-- is what makes the forkable-table registry a real guard, not a comment),
-- then for every account shared in the household, creates one fresh private
-- copy per member and replicates history per fork_handled_tables' handling.
-- ============================================================================

create function fork_household_accounts(p_household_id uuid, p_member_a uuid, p_member_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unregistered text;
  v_old_account_id uuid;
  v_new_for_a uuid;
  v_new_for_b uuid;
begin
  -- BASE TABLE only — views (account_balances, transactions_with_details,
  -- needs_review, ...) surface an account_id column too, but they hold no
  -- data of their own to fork; only real tables need a handling strategy.
  select string_agg(c.table_name, ', ') into v_unregistered
  from information_schema.columns c
  join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
  where c.table_schema = 'public' and c.column_name = 'account_id' and t.table_type = 'BASE TABLE'
    and not exists (select 1 from public.fork_handled_tables f where f.table_name = c.table_name);

  if v_unregistered is not null then
    raise exception 'fork_household_accounts: unregistered account_id-bearing table(s): %', v_unregistered;
  end if;

  for v_old_account_id in select account_id from public.household_accounts where household_id = p_household_id
  loop
    insert into public.accounts (
      owner_id, created_by, kind, subtype, name, currency,
      opening_balance, opening_balance_at, include_in_total, counts_toward_fi
    )
    select p_member_a, p_member_a, kind, subtype, name, currency,
           opening_balance, opening_balance_at, include_in_total, counts_toward_fi
    from public.accounts where id = v_old_account_id
    returning id into v_new_for_a;

    insert into public.accounts (
      owner_id, created_by, kind, subtype, name, currency,
      opening_balance, opening_balance_at, include_in_total, counts_toward_fi
    )
    select p_member_b, p_member_b, kind, subtype, name, currency,
           opening_balance, opening_balance_at, include_in_total, counts_toward_fi
    from public.accounts where id = v_old_account_id
    returning id into v_new_for_b;

    -- transactions: duplicate_to_both. A transfer leg loses its group
    -- (see the migration header) and becomes an adjustment-sourced entry
    -- carrying the same signed amount. Lateral column names deliberately
    -- avoid this function's own declared variable names — plpgsql resolves
    -- a bare identifier against its variables before table columns, so
    -- reusing v_new_for_a/v_new_for_b as an alias here would shadow, not
    -- reference, the lateral row (confirmed empirically while building
    -- this migration).
    insert into public.transactions (
      owner_id, created_by, account_id, category_id, amount, currency, occurred_at,
      merchant_raw, merchant_normalized, source, status
    )
    select
      fork.fork_owner, t.created_by, fork.fork_account_id,
      case
        when t.transfer_group_id is not null then (
          select id from public.categories
          where owner_id = fork.fork_owner
            and system_key = case when t.amount < 0 then 'adjustment_expense' else 'adjustment_income' end
        )
        else public.fork_category_id(fork.fork_owner, t.category_id)
      end,
      t.amount, t.currency, t.occurred_at, t.merchant_raw, t.merchant_normalized,
      case when t.transfer_group_id is not null then 'adjustment'::public.transaction_source else t.source end,
      t.status
    from public.transactions t
    cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
    where t.account_id = v_old_account_id and t.deleted_at is null;

    -- balance_snapshots: duplicate_to_both, identical historical values.
    insert into public.balance_snapshots (account_id, currency, as_of, value, created_by)
    select fork.fork_account_id, bs.currency, bs.as_of, bs.value, bs.created_by
    from public.balance_snapshots bs
    cross join lateral (values (v_new_for_a), (v_new_for_b)) as fork (fork_account_id)
    where bs.account_id = v_old_account_id;

    -- reconciliations: duplicate_to_both. adjustment_txn_id/snapshot_id are
    -- best-effort — the referenced rows still exist (now under the
    -- archived original account), but there is no 1:1 mapping to this
    -- fork's own new transaction/snapshot rows, so they're left null rather
    -- than pointed at the wrong account's data.
    insert into public.reconciliations (account_id, currency, as_of, entered_balance, computed_balance, created_by)
    select fork.fork_account_id, r.currency, r.as_of, r.entered_balance, r.computed_balance, r.created_by
    from public.reconciliations r
    cross join lateral (values (v_new_for_a), (v_new_for_b)) as fork (fork_account_id)
    where r.account_id = v_old_account_id;

    -- recurring_rules: duplicate_to_both, category remapped per new owner.
    insert into public.recurring_rules (created_by, account_id, category_id, amount, currency, frequency, next_due_at, active)
    select rr.created_by, fork.fork_account_id, public.fork_category_id(fork.fork_owner, rr.category_id),
           rr.amount, rr.currency, rr.frequency, rr.next_due_at, rr.active
    from public.recurring_rules rr
    cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
    where rr.account_id = v_old_account_id;

    -- card_mappings / csv_import_batches / csv_import_candidates:
    -- repoint_by_owner — never shared visibility; each row already belongs
    -- to exactly one member, so it just follows that member's new copy.
    update public.card_mappings
    set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
    where account_id = v_old_account_id;

    update public.csv_import_batches
    set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
    where account_id = v_old_account_id;

    update public.csv_import_candidates
    set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
    where account_id = v_old_account_id;

    -- net_worth_daily: cache_recompute — drop, let the next refresh rebuild it.
    delete from public.net_worth_daily where account_id = v_old_account_id;

    -- household_accounts: deleted_on_leave — the sharing relationship ends.
    delete from public.household_accounts where account_id = v_old_account_id;

    update public.accounts set archived_at = coalesce(archived_at, now()) where id = v_old_account_id;
  end loop;
end;
$$;

revoke all on function fork_household_accounts(uuid, uuid, uuid) from public;

-- ============================================================================
-- leave_household — the caller's own household_members row is the entire
-- revocation (spec). A single-member household (no v_other) forks nothing;
-- there is nothing shared to split.
-- ============================================================================

create function leave_household()
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
  where household_id = v_household_id and user_id <> v_me;

  if v_other is not null then
    perform public.fork_household_accounts(v_household_id, v_me, v_other);
  end if;

  delete from public.household_members where household_id = v_household_id and user_id = v_me;

  insert into public.household_events (household_id, actor_id, kind)
  values (v_household_id, v_me, 'member_left')
  returning id into v_event_id;

  perform public.notify_household(v_event_id);
end;
$$;

revoke all on function leave_household() from public;
grant execute on function leave_household() to authenticated;

-- ============================================================================
-- erase_own_account — fork (so the other member's shared history is never
-- corrupted by this), then scrub the caller's own resulting copy's free-text
-- fields. Deliberately never touches the other member's new copy, and never
-- attempts to delete auth.users itself (that's an admin-API operation, out
-- of scope for a SQL RPC) — this closes the data side of "erase my data,"
-- the account-deletion flow closes the identity side separately.
-- ============================================================================

create function erase_own_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_other uuid;
  v_event_id uuid;
begin
  if v_household_id is not null then
    select user_id into v_other from public.household_members
    where household_id = v_household_id and user_id <> v_me;

    if v_other is not null then
      perform public.fork_household_accounts(v_household_id, v_me, v_other);
    end if;

    delete from public.household_members where household_id = v_household_id and user_id = v_me;

    insert into public.household_events (household_id, actor_id, kind)
    values (v_household_id, v_me, 'member_erased')
    returning id into v_event_id;

    perform public.notify_household(v_event_id);
  end if;

  update public.transactions set merchant_raw = null, merchant_normalized = null
  where owner_id = v_me and (merchant_raw is not null or merchant_normalized is not null);

  update public.card_mappings set card_identifier = 'erased'
  where owner_id = v_me;

  update public.csv_import_batches set filename = 'erased'
  where owner_id = v_me;

  update public.csv_import_candidates set raw_row = '{}'::jsonb, merchant_raw = null, merchant_normalized = null
  where owner_id = v_me;
end;
$$;

revoke all on function erase_own_account() from public;
grant execute on function erase_own_account() to authenticated;
