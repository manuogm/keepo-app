-- UI overhaul: three schema facts the new Accounts and Mapped Card screens
-- need and that no existing column can answer.
--
--   1. accounts.sort_order — the Accounts list becomes drag-to-reorder.
--      Order is a user decision, so it belongs on the row and syncs with
--      it; a device-local ordering would silently disagree across a
--      reinstall or a second device, which for a list the user arranged by
--      hand reads as data loss.
--
--   2. accounts.kind becomes mutable, via its own RPC. 20260902100000
--      (unify_account_kinds) left kind immutable and said why in its own
--      §7 comment: not because anything downstream depends on it for
--      correctness anymore — that reason died with the ledger/valuation
--      split — but because changing it out from under existing data would
--      be surprising. Dragging a row from Everyday into Investments is the
--      user *asking* for exactly that, deliberately, so the surprise
--      argument no longer holds. Balance formula, transactions, card
--      mappings and FX are all untouched by kind; the only observable
--      effect is which section the row sits in and whether it carries the
--      Investment badge.
--
--   3. card_mappings.source — the Mapped Card popup distinguishes a
--      mapping the user typed in from one the capture pipeline created for
--      them. The distinction already exists structurally (map_card is only
--      ever reached from a user action; link_card_to_account is only ever
--      called by review/confirm_capture_transaction on the user's behalf),
--      it just was never written down on the row.
--
-- pull_changes uses to_jsonb(row) per table, so all three columns reach the
-- client without touching that function. The client's own mirror
-- (LocalSchemaV1) and SyncApply's column whitelist do need updating.

-- ============================================================================
-- 1. accounts.sort_order
-- ============================================================================

alter table public.accounts add column sort_order integer not null default 0;

-- Backfill to the order the list already rendered in (ORDER BY name), per
-- owner and kind — so the first drag starts from what the user was looking
-- at rather than from an arbitrary permutation.
with ordered as (
  select id, row_number() over (partition by owner_id, kind order by name) as position
  from public.accounts
)
update public.accounts a set sort_order = ordered.position::integer
from ordered where ordered.id = a.id;

comment on column public.accounts.sort_order is
  'User-arranged position within its kind group. Purely presentational, like icon/color — '
  'no money or access logic reads it. Ties break by name (see the client''s own ORDER BY).';

-- A new account belongs at the BOTTOM of its group, not the top. The column
-- default of 0 would put it first, ahead of every account the user has
-- already arranged by hand — which reads as the list rearranging itself.
--
-- A trigger rather than a change to create_account: `accounts` is inserted
-- into from more than one place (create_account, fork_one_account, and the
-- seed/test fixtures), and "a new row goes last" is a property of the
-- column, not of one caller. It fires only when nothing explicit was
-- supplied, so a fixture or a restore that carries its own ordering keeps it.
create function public.set_account_sort_order()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(new.sort_order, 0) = 0 then
    select coalesce(max(sort_order), 0) + 1 into new.sort_order
    from public.accounts
    where owner_id = new.owner_id and kind = new.kind and deleted_at is null;
  end if;
  return new;
end;
$$;

revoke all on function public.set_account_sort_order() from public;

create trigger accounts_set_sort_order
  before insert on public.accounts
  for each row execute function public.set_account_sort_order();

-- ============================================================================
-- 1b. A reorder is not a semantic edit, so it must not bump `version`
-- ============================================================================
--
-- No new machinery: `keepo.restamp_only` already exists for precisely this
-- (20260816100000 §restamp_account_for_sync) and both `bump_version()` and
-- `set_updated_at()` already honour it. Its name says "re-stamp", and that
-- is exactly what a reorder is — an UPDATE whose only purpose is to move the
-- row's sync ticket forward so every device re-pulls it, without claiming
-- the row's data was edited. reorder_accounts simply opts into it; see the
-- `perform set_config` in §2 below.
--
-- Why this matters rather than just letting the bump happen:
--
--   * `version` is this schema's optimistic-concurrency token. Bumping it
--     for a drag invalidates the expectedVersion every client holds for
--     those rows, so the next genuine edit (rename, balance, archive)
--     conflicts and lands in Needs Review having conflicted with nothing.
--   * Dragging a row between the Everyday and Investments groups is ONE
--     gesture that is two writes (set_account_kind + reorder_accounts).
--     With a bump on both, their ordering silently decides whether the
--     second conflicts with the first.
--
-- A dedicated bump_account_version() trigger was written first and thrown
-- away — recorded here because the reasoning is worth not repeating. It
-- tried to infer the exemption ("did any column other than sort_order
-- change?") instead of being told about it, and that inference is
-- unsound: set_account_balance ends with a bare `set updated_at = now()`
-- whose only purpose is to bump the version, and `now()` is frozen per
-- transaction, so "nothing else changed" and "the bump was the point" are
-- indistinguishable. It also silently dropped bump_version()'s existing
-- restamp_only check, breaking share_account. Both caught by the pgTAP
-- suite (21_set_account_balance.sql, 23_sync_primitives.sql).

-- ============================================================================
-- 2. reorder_accounts — one statement, not N round trips
-- ============================================================================

-- Takes the full ordered id list for ONE kind group and writes each row's
-- position from its place in that array. Deliberately not version-checked:
-- ordering is not a value two clients can meaningfully conflict over (last
-- arrangement wins is the correct semantic, the same reasoning
-- rename/unmap_card already use), and forcing an expected_version here
-- would make a drag fail against a concurrent, unrelated balance edit.
create function public.reorder_accounts(p_account_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- can_write_account per row rather than owner_id = auth.uid(): a shared
  -- household account is reorderable by either member, same as every other
  -- presentational edit on it.
  if exists (
    select 1 from unnest(p_account_ids) as ids(id)
    where not public.can_write_account(ids.id)
  ) then
    raise exception 'account not found or not accessible';
  end if;

  -- Touches nothing but sort_order, and opts out of both the version bump
  -- and the updated_at touch for the duration of this statement (see §1b).
  -- accounts_stamp_sync_seq still fires, which is all a pulling client
  -- needs to see the new arrangement.
  perform set_config('keepo.restamp_only', 'true', true);

  update public.accounts a
  set sort_order = ordered.position::integer
  from (
    select id, ordinality as position
    from unnest(p_account_ids) with ordinality as t(id, ordinality)
  ) ordered
  where ordered.id = a.id and a.deleted_at is null;

  -- Reset explicitly, matching restamp_account_for_sync's own shape: an RPC
  -- is its own transaction today, but nothing about this function requires
  -- that it always be called alone in one.
  perform set_config('keepo.restamp_only', 'false', true);
end;
$$;

revoke all on function public.reorder_accounts(uuid[]) from public;
grant execute on function public.reorder_accounts(uuid[]) to authenticated, service_role;

-- ============================================================================
-- 3. set_account_kind — the drag-between-sections write
-- ============================================================================

-- Version-checked and conflict-returning, matching update_account exactly:
-- unlike ordering, kind IS a value two clients can disagree about, and the
-- losing write must land in sync_conflicts rather than silently winning.
create function public.set_account_kind(
  p_id uuid, p_expected_version integer, p_kind public.account_kind
)
returns table (conflict boolean, account accounts)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.accounts;
begin
  select id, version, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set kind = p_kind
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.accounts;
    return;
  end if;

  return query select false, v_result;
end;
$$;

revoke all on function public.set_account_kind(uuid, integer, public.account_kind) from public;
grant execute on function public.set_account_kind(uuid, integer, public.account_kind)
  to authenticated, service_role;

-- ============================================================================
-- 4. card_mappings.source
-- ============================================================================

create type public.card_mapping_source as enum ('manual', 'automatic');

-- Enum, not text + CHECK (money rule 4's reasoning applies to every enum in
-- this schema, not only money ones — a CHECK generates as a plain String in
-- codegen, an enum as a proper type).
alter table public.card_mappings
  add column source public.card_mapping_source not null default 'manual';

-- Every row that already exists predates the distinction. 'manual' is the
-- honest default: the only pre-existing path that created a mapping without
-- the user naming it themselves is link_card_to_account, and its rows are
-- indistinguishable from map_card's now — claiming 'automatic' for them
-- would be inventing provenance we do not have.
comment on column public.card_mappings.source is
  'How this mapping came to exist: ''manual'' — the user typed the card name '
  '(map_card); ''automatic'' — the capture pipeline linked it while the user '
  'reviewed a captured transaction (link_card_to_account). Presentational only.';

-- link_card_to_account gains the parameter. The body below is
-- 20260902100000 §8's definition verbatim (the current, authoritative one)
-- plus p_source — re-read in full rather than patched from an excerpt, per
-- version-logs/lessons-learned.md.
--
-- The 3-arg signature is DROPPED, not kept alongside: a 4-arg overload with
-- a defaulted last parameter would make every existing `link_card_to_account
-- (a, b, c)` call ambiguous ("function is not unique") rather than resolving
-- to it. plpgsql resolves callee names at runtime, so the existing callers
-- inside review_capture_transaction / confirm_capture / update_transaction
-- bind to the new function untouched and get the 'automatic' default they
-- want.
drop function public.link_card_to_account(uuid, text, uuid);

create function public.link_card_to_account(
  p_owner uuid, p_card_identifier text, p_account_id uuid,
  p_source public.card_mapping_source default 'automatic'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.accounts
    where id = p_account_id and owner_id = p_owner
      and deleted_at is null and archived_at is null
  ) then
    raise exception 'account not found, not accessible, or archived';
  end if;

  insert into public.card_mappings (owner_id, card_identifier, account_id, source)
  values (p_owner, p_card_identifier, p_account_id, p_source)
  on conflict (owner_id, card_identifier)
  do update set
    account_id = excluded.account_id,
    -- 20260831100000's fix: re-mapping a card that was ever unmapped must
    -- not leave it soft-deleted and therefore invisible forever.
    deleted_at = null,
    -- Provenance is decided by whoever first gives this card a real
    -- account, and never rewritten afterwards. The `account_id is null`
    -- test is load-bearing, not defensive: capture_transaction inserts a
    -- bare (owner, card) placeholder with no account for every unrecognised
    -- card, which would otherwise claim the column's 'manual' default and
    -- permanently mislabel the automatic link that follows it.
    source = case
      when public.card_mappings.account_id is null then excluded.source
      else public.card_mappings.source
    end,
    updated_at = now();
end;
$$;

revoke all on function public.link_card_to_account(uuid, text, uuid, public.card_mapping_source) from public;
grant execute on function public.link_card_to_account(uuid, text, uuid, public.card_mapping_source)
  to authenticated, service_role;

-- map_card is the user-facing entry point; it now says so explicitly.
create or replace function public.map_card(p_card_identifier text, p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.link_card_to_account((select auth.uid()), p_card_identifier, p_account_id, 'manual');
end;
$$;

revoke all on function public.map_card(text, uuid) from public;
grant execute on function public.map_card(text, uuid) to authenticated;
