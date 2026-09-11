-- A device holds one cursor. `sync_domain_id` can move a user to a different
-- ticket sequence. Nothing made the new sequence start ahead of the old one.
--
-- ============================================================================
-- The defect
-- ============================================================================
--
-- `stamp_sync_seq_owner` stamps every row with
-- `next_ticket(sync_domain_id(owner_id))`, and `sync_domain_id` is "your
-- household if you are in one, otherwise yourself". So joining a household
-- moves every subsequent write of yours onto the **household's** sequence —
-- and `next_ticket` starts a brand-new domain at **1**.
--
-- `pull_changes` is `sync_seq > p_cursor` across every table, and the cursor
-- it hands back is `max(sync_seq)` over everything the device can see. That
-- is one scalar spanning two sequences.
--
-- So for a user with real history:
--
--   * their private domain has issued, say, 5,000 tickets;
--   * `accept_invite` bumps both epochs, the device wipes and re-pulls from
--     0, and its cursor lands on ~5,000 — their own pre-existing rows, still
--     stamped in the private domain, are the high-water mark;
--   * the household domain starts at 1, so every category twin, every merge,
--     every tag prune is stamped 2, 3, 4 …;
--   * `pull_changes(5000)` matches none of them and returns an **empty
--     payload with no error at all**.
--
-- The household's writes are invisible to its own members until that
-- sequence climbs past 5,000, which is thousands of writes away. Proven in a
-- rolled-back transaction: `apply_category_merges` returns 1, both rows are
-- renamed on the server at `sync_seq` 13 and 14, and `pull_changes(5000, 0)`
-- reports `categories_delivered = 0`.
--
-- This is the cause underneath three rounds of "the household report does
-- nothing". Every fix before this one — the merge tombstone keeping its
-- group, chaining overlapping pulls, raising the pull rate limit, bumping
-- epochs on revocation — was downstream of a cursor that could never advance
-- to meet the new domain. It is invisible on a fresh test account, because
-- twenty rows of history means the household's sequence overtakes the cursor
-- within the ceremony itself. That is exactly why it survived two-device
-- testing on seeded accounts and reproduced instantly on real phones.
--
-- ============================================================================
-- The rule this migration writes down
-- ============================================================================
--
-- **A domain a user is moved into must start ahead of any cursor that
-- user's devices could already hold.** One scalar cursor spanning several
-- sequences only works if the sequences are monotonic with respect to each
-- other, and the only moment that can be guaranteed is the moment the move
-- happens.
--
-- The move is always a `household_members` write — `create_household` and
-- `accept_invite` insert or revive a row, `leave_household` and
-- `erase_own_account` retire one — so the guarantee goes on that table as a
-- trigger rather than into four function bodies. Nothing existing is
-- restated (20260911100000's lesson), and a fifth call site cannot forget it.
-- ============================================================================

-- ============================================================================
-- 1. How high any cursor could possibly be
--
-- The **global** maximum, not this user's own rows. A member's cursor is the
-- high-water mark of everything they can *see*, which includes the other
-- member's shared accounts, transactions and categories — so a per-owner max
-- would under-read exactly in the case this exists for. Over-allocating
-- tickets costs nothing: `sync_seq` is bigint and cursors are compared, never
-- counted.
--
-- `currencies` and `fx_rates` are deliberately absent. They live in
-- `sync_global_domain()` and are served off `p_global_cursor`, a separate
-- scalar, so they neither raise nor are raised by this.
-- ============================================================================

create or replace function sync_high_water()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(max(m), 0) from (
    select max(sync_seq) as m from public.accounts
    union all select max(sync_seq) from public.transactions
    union all select max(sync_seq) from public.categories
    union all select max(sync_seq) from public.tags
    union all select max(sync_seq) from public.transaction_tags
    union all select max(sync_seq) from public.recurring_rules
    union all select max(sync_seq) from public.card_mappings
    union all select max(sync_seq) from public.merchant_category_map
    union all select max(sync_seq) from public.sync_conflicts
    union all select max(sync_seq) from public.households
    union all select max(sync_seq) from public.household_members
    union all select max(sync_seq) from public.household_accounts
    union all select max(sync_seq) from public.profiles
  ) s;
$$;

revoke all on function sync_high_water() from public;

comment on function sync_high_water() is
  'The largest sync_seq any device could be holding as its cursor. Excludes the global domain, which has its own.';

-- ============================================================================
-- 2. Lifting a domain above it
--
-- Returns whether it actually moved, so the repair below can tell which
-- members are holding a cursor that has already outrun their own household.
-- ============================================================================

create or replace function raise_sync_domain(p_domain_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_floor bigint := public.sync_high_water() + 1;
  v_before bigint;
begin
  select next_ticket into v_before from public.sync_tickets where domain_id = p_domain_id;

  insert into public.sync_tickets (domain_id, next_ticket)
  values (p_domain_id, v_floor)
  on conflict (domain_id) do update
    set next_ticket = greatest(public.sync_tickets.next_ticket, v_floor);

  -- Compared against what was there, not against the floor: a domain that
  -- already happened to sit exactly on the floor has stranded nobody, and
  -- saying it moved would cost its members a full re-pull for nothing.
  return coalesce(v_before, 0) < v_floor;
end;
$$;

revoke all on function raise_sync_domain(uuid) from public;

comment on function raise_sync_domain(uuid) is
  'Starts a domain ahead of every cursor in the system. Call whenever a user is moved into it.';

-- ============================================================================
-- 3. Every domain change is a membership write
--
-- Joining points the member at the household's sequence; leaving points them
-- back at their own, which stopped at whatever it was the day they joined
-- while their rows climbed into the household's. Both directions strand a
-- cursor, so both are raised.
--
-- `after`, so the row is committed to the statement before the raise, and
-- **in the same transaction** as the writes that follow it — `accept_invite`
-- shares its categories immediately after inserting the membership, and those
-- twins must already be drawing on the raised sequence.
-- ============================================================================

create or replace function raise_sync_domain_for_membership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.deleted_at is null then
    perform public.raise_sync_domain(new.household_id);
  else
    perform public.raise_sync_domain(new.user_id);
  end if;
  return null;
end;
$$;

revoke all on function raise_sync_domain_for_membership() from public;

drop trigger if exists household_members_raise_sync_domain on household_members;

create trigger household_members_raise_sync_domain
  after insert or update of deleted_at on household_members
  for each row execute function raise_sync_domain_for_membership();

-- ============================================================================
-- 4. Repairing the households that are already stranded
--
-- A household built before this migration started at 1 and is very likely
-- still below its members' cursors — which is the live bug, on real phones,
-- right now. Raising the domain fixes every write from here on, but the
-- writes made *during* the stalled window carry tickets no cursor will ever
-- reach again, so the members also have to re-pull in full. That is what
-- `sync_epoch` is for, and it is bumped only for the domains that actually
-- moved: a household already ahead of its members costs nobody a wipe.
--
-- The global domain is skipped — it is denominated in `p_global_cursor` and
-- has nothing to do with any of this.
-- ============================================================================

-- Raised first, every epoch bumped after: an epoch bump writes `profiles`
-- rows, which raises the high-water mark, which would give each domain in the
-- loop a different floor depending on where it fell in the ordering. Doing
-- all the reads before any of the writes makes one pass over one number.
do $$
declare
  v_stranded uuid[];
begin
  select coalesce(array_agg(domain_id), '{}')
  into v_stranded
  from public.sync_tickets
  where domain_id <> public.sync_global_domain()
    and next_ticket <= public.sync_high_water();

  perform public.raise_sync_domain(d) from unnest(v_stranded) as d;

  update public.profiles set sync_epoch = sync_epoch + 1
  where id = any (v_stranded)
     or id in (
       select hm.user_id from public.household_members hm
       where hm.household_id = any (v_stranded) and hm.deleted_at is null
     );
end;
$$;
