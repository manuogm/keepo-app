-- ============================================================================
-- Recurring transfers.
--
-- `recurring_rules` was built around a single account_id/category_id pair,
-- so app-architecture.md §2 recorded "recurring transfers aren't in the
-- spec" and the transaction form hid its "Make recurring" button for the
-- transfer kind. A standing transfer into savings is the single most
-- ordinary recurring instruction there is, so the shape gets widened here
-- rather than the feature staying refused.
--
-- The rule is now one of two shapes, and the CHECK below is what says so:
--
--   expense/income  category_id set,  to_account_id null
--   transfer        category_id null, to_account_id set
--
-- **Same owner, both legs.** `to_account_id` carries the same composite FK
-- to (id, owner_id) that account_id and category_id already carry, which
-- means a recurring transfer can only move money between two accounts of
-- one owner. That is not a stylistic restriction. `materialize_recurring`
-- stamps `recurring_rule_id` on BOTH legs it inserts, and
-- `transactions_recurring_rule_owner_fk` is itself composite — so a
-- destination leg owned by somebody else could not point back at the rule
-- that created it. The alternatives were to leave that leg unstamped (the
-- ledger's recurring glyph and "edit all future occurrences" would then
-- work from one leg and not the other) or to widen a foreign key on
-- `transactions`, which is a great deal of blast radius for a standing
-- instruction to move another person's money on a schedule — a household
-- settlement, and a different feature.
--
-- **Same currency, both legs.** Enforced in `validate_recurring_rule_sign`
-- rather than by a CHECK, because it needs to read two accounts. A
-- cross-currency transfer needs a destination amount, and there is no
-- honest value to store: a figure fixed today is wrong by next month, and
-- money rule 6 only permits a stored conversion *because a user is present
-- to correct it with what their bank actually charged*. Nobody is present
-- at 2am when the cron fires. Converting at materialization time instead
-- would leave the job to decide what to do when no rate resolves, which
-- money rule 5 answers with "—" — not something a row can hold. A standing
-- FX instruction is its own feature; this migration declines to guess at it.
-- ============================================================================

alter table recurring_rules alter column category_id drop not null;

alter table recurring_rules add column to_account_id uuid;

alter table recurring_rules add constraint recurring_rules_to_account_owner_fk
  foreign key (to_account_id, owner_id) references accounts (id, owner_id) deferrable initially deferred;

alter table recurring_rules add constraint recurring_rules_shape_check check (
  (category_id is not null and to_account_id is null)
  or (category_id is null and to_account_id is not null and to_account_id <> account_id)
);

create index recurring_rules_to_account_id_idx on recurring_rules (to_account_id)
  where to_account_id is not null;

-- ============================================================================
-- validate_recurring_rule_sign — now validates both shapes.
--
-- Same reasoning as the original: a wrong sign or an impossible pair would
-- otherwise surface as a CHECK violation inside a 2am cron job's insert.
-- Caught at the point the rule is created or edited instead.
--
-- A transfer's `amount_e4` is the OUTFLOW from `account_id` and so is
-- negative, exactly like the leg `create_transfer` writes — money rule 1,
-- and nothing re-signs it on the way to `materialize_recurring`.
-- ============================================================================

create or replace function public.validate_recurring_rule_sign()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind public.category_kind;
  v_from_currency text;
  v_to_currency text;
begin
  if new.to_account_id is not null then
    if new.amount_e4 >= 0 then
      raise exception 'a recurring transfer''s amount must be negative — it is the outflow from the source account';
    end if;

    select currency into v_from_currency from public.accounts where id = new.account_id;
    select currency into v_to_currency from public.accounts where id = new.to_account_id;

    if v_from_currency is distinct from v_to_currency then
      raise exception 'a recurring transfer must be between two accounts in the same currency';
    end if;

    return new;
  end if;

  select kind into v_kind from public.categories where id = new.category_id;

  if v_kind = 'expense' and new.amount_e4 >= 0 then
    raise exception 'an expense recurring rule''s amount must be negative';
  elsif v_kind = 'income' and new.amount_e4 <= 0 then
    raise exception 'an income recurring rule''s amount must be positive';
  end if;

  return new;
end;
$$;

revoke all on function public.validate_recurring_rule_sign() from public;

-- ============================================================================
-- RLS — a transfer rule names two accounts, so both have to be readable and
-- both writable. Reading a rule you can only half see would hand you the id
-- of an account you have no business knowing about; writing one would let
-- you aim a standing instruction at an account you cannot write to.
--
-- Policies are dropped and recreated rather than altered: `alter policy`
-- cannot change a USING clause and a WITH CHECK clause in one statement,
-- and two statements is how one of them ends up forgotten.
-- ============================================================================

drop policy recurring_rules_select on recurring_rules;
drop policy recurring_rules_insert on recurring_rules;
drop policy recurring_rules_update on recurring_rules;

create policy recurring_rules_select on recurring_rules
  for select to authenticated
  using (
    can_read_account(account_id)
    and (to_account_id is null or can_read_account(to_account_id))
  );

create policy recurring_rules_insert on recurring_rules
  for insert to authenticated
  with check (
    can_write_account(account_id)
    and (to_account_id is null or can_write_account(to_account_id))
    and created_by = (select auth.uid())
  );

create policy recurring_rules_update on recurring_rules
  for update to authenticated
  using (
    can_write_account(account_id)
    and (to_account_id is null or can_write_account(to_account_id))
  )
  with check (
    can_write_account(account_id)
    and (to_account_id is null or can_write_account(to_account_id))
  );

-- RLS grants nothing (CLAUDE.md) — reasserted rather than assumed to have
-- survived, which is this repo's standing habit around anything security
-- relevant.
grant select, insert, update on recurring_rules to authenticated, service_role;

-- ============================================================================
-- materialize_recurring — still the only writer of recurring-sourced
-- transactions, now minting a pair for a transfer rule.
--
-- **The idempotency backstop is unchanged and is what makes the pair safe.**
-- Both legs go in under the same partial unique index on
-- (owner_id, source, external_id), each with its own suffix, so a re-run
-- inserts neither. A single external_id shared by both legs would let the
-- second insert be swallowed by the first's conflict and leave a transfer
-- with one side — a phantom expense the balance would then carry forever.
--
-- `found` after an `insert ... on conflict do nothing` reports whether the
-- LAST statement touched a row, so the two-leg branch counts its legs
-- separately instead of asking once for both.
-- ============================================================================

create or replace function public.materialize_recurring(p_through date default current_date)
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
  v_to_currency text;
begin
  for v_rule in
    select * from public.recurring_rules where active and next_due_at <= p_through
    order by id
    for update
  loop
    v_occurrence := v_rule.next_due_at;
    v_to_currency := null;

    if v_rule.to_account_id is not null then
      select currency into v_to_currency from public.accounts where id = v_rule.to_account_id;
    end if;

    while v_occurrence <= p_through loop
      if v_rule.to_account_id is null then
        insert into public.transactions (
          id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
          source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id, v_rule.category_id,
          v_rule.amount_e4, v_rule.currency, v_occurrence::timestamptz,
          'recurring', v_rule.id::text || '|' || v_occurrence::text, v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing;

        if found then
          v_inserted := v_inserted + 1;
        end if;
      else
        -- One group id per occurrence, so each month's pair folds into one
        -- row in the ledger exactly like a hand-entered transfer does.
        v_group := gen_random_uuid();

        insert into public.transactions (
          id, owner_id, created_by, account_id, amount_e4, currency, occurred_at,
          transfer_group_id, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id,
          v_rule.amount_e4, v_rule.currency, v_occurrence::timestamptz,
          v_group, 'recurring', v_rule.id::text || '|' || v_occurrence::text || '|from', v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing;

        if found then
          v_inserted := v_inserted + 1;
        end if;

        insert into public.transactions (
          id, owner_id, created_by, account_id, amount_e4, currency, occurred_at,
          transfer_group_id, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.to_account_id,
          -v_rule.amount_e4, v_to_currency, v_occurrence::timestamptz,
          v_group, 'recurring', v_rule.id::text || '|' || v_occurrence::text || '|to', v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing;

        if found then
          v_inserted := v_inserted + 1;
        end if;
      end if;

      v_occurrence := public.next_occurrence_date(v_occurrence, v_rule.frequency);
    end loop;

    update public.recurring_rules
    set next_due_at = v_occurrence, last_materialized_at = p_through
    where id = v_rule.id;
  end loop;

  return v_inserted;
end;
$$;

revoke all on function public.materialize_recurring(date) from public;
grant execute on function public.materialize_recurring(date) to service_role;

-- ============================================================================
-- delete_account — a rule pointing at the deleted account from EITHER end
-- has to be retired, for the reason 20260917100000 gives for the source
-- end: `materialize_recurring` selects on `active and next_due_at <= …` and
-- never asks whether the accounts still exist. A transfer rule whose
-- destination was deleted would keep minting a pair onto it, quietly
-- undoing the delete the user just confirmed.
-- ============================================================================

create or replace function public.delete_account(
  p_id uuid,
  p_expected_version integer,
  p_cascade boolean default false
)
returns table (conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_updated integer;
begin
  select id, version, deleted_at
  into v_current
  from public.accounts
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null or not public.can_write_account(p_id) then
    raise exception 'account not found or not accessible';
  end if;

  update public.accounts
  set deleted_at = now()
  where id = p_id and version = p_expected_version;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('accounts', p_id, v_owner, p_expected_version, v_current.version);

    return query select true;
    return;
  end if;

  if exists (select 1 from public.transactions where account_id = p_id and deleted_at is null) then
    if not p_cascade then
      raise exception 'This account still has transactions, so it cannot be deleted on its own.';
    end if;

    update public.transactions
    set deleted_at = now()
    where account_id = p_id and deleted_at is null;
  end if;

  update public.recurring_rules
  set active = false
  where (account_id = p_id or to_account_id = p_id) and active;

  return query select false;
end;
$$;

revoke all on function public.delete_account(uuid, integer, boolean) from public;
grant execute on function public.delete_account(uuid, integer, boolean) to authenticated;

-- ============================================================================
-- restamp_account_for_sync — same widening. A rule reached only through its
-- destination still has to re-stamp, or the other device never learns that
-- the account on the far end of it moved.
-- ============================================================================

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
  update public.recurring_rules set id = id
  where account_id = p_account_id or to_account_id = p_account_id;
  perform set_config('keepo.restamp_only', 'false', true);
end;
$$;

revoke all on function public.restamp_account_for_sync(uuid) from public, anon, authenticated;
grant execute on function public.restamp_account_for_sync(uuid) to postgres;

-- ============================================================================
-- fork_one_account — a household splitting in two.
--
-- An expense/income rule is copied to both members, as before: the category
-- is forked per owner and the rule means the same thing on each side of the
-- split.
--
-- **A transfer rule is copied only to the member who already owned it.**
-- Its other leg is an account that is NOT being forked, and that account
-- belongs to one person — so the other member's copy would name a stranger's
-- account and fail the composite FK this migration added. It would also be
-- wrong if it succeeded: a standing transfer into my own savings is not an
-- instruction my ex-partner inherits. `rr.owner_id` is the account's owner
-- by trigger, which before the fork is the shared account's owner, so the
-- comparison is against the member the rule actually belonged to.
--
-- A transfer rule reached through its DESTINATION is left alone here and
-- retired by `delete_account`/archival if the account goes; re-pointing it
-- at one of two forks would be the app choosing which half of a dissolved
-- household keeps receiving the money.
--
-- **The body below is `20260914100000`'s verbatim, with only the recurring
-- insert changed.** The first draft of this migration was built on
-- `20260909100000`'s copy instead, which is one revision older — and the
-- revision in between is the one that fixed the household lookup (it now
-- joins `household_members` for BOTH members rather than deriving the
-- household from the account alone, where `select ... into` over several
-- rows silently takes an arbitrary one and told a user they were not a
-- member of their own household). Restating the older body would have
-- reverted that fix on a `CREATE OR REPLACE`, silently, with every test
-- still green — nothing in the suite exercises a user in two households.
-- Caught by listing every migration that defines this function before
-- pushing, which is the only reliable check: grep the function name across
-- `supabase/migrations/`, take the LAST one, and diff against it.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fork_one_account(p_old_account_id uuid, p_member_a uuid, p_member_b uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_household_id uuid;
  v_new_for_a uuid;
  v_new_for_b uuid;
begin
  -- The household is the one containing **both** members being split, which
  -- is what this function is about and what both callers already knew.
  -- Deriving it from the account alone was the bug: nothing constrained that
  -- lookup to one row, and `select ... into` over several does not raise in
  -- plpgsql — it takes an arbitrary one. Picking the wrong household made the
  -- membership check below fail on a caller who *was* a member of the
  -- household actually being forked, and the raise took the whole
  -- `leave_household` transaction down with it.
  select ha.household_id into v_household_id
  from public.household_accounts ha
  join public.household_members hm_a
    on hm_a.household_id = ha.household_id
   and hm_a.user_id = p_member_a
   and hm_a.deleted_at is null
  join public.household_members hm_b
    on hm_b.household_id = ha.household_id
   and hm_b.user_id = p_member_b
   and hm_b.deleted_at is null
  where ha.account_id = p_old_account_id and ha.deleted_at is null
  limit 1;

  if v_household_id is null then
    raise exception 'account not found or not shared with a household';
  end if;

  if not exists (
    select 1 from public.household_members hm
    where hm.household_id = v_household_id and hm.user_id = (select auth.uid()) and hm.deleted_at is null
  ) then
    raise exception 'caller is not a member of this account''s household';
  end if;

  if (
    select count(*) from public.household_members hm
    where hm.household_id = v_household_id and hm.deleted_at is null
      and hm.user_id in (p_member_a, p_member_b)
  ) <> 2 or p_member_a = p_member_b then
    raise exception 'p_member_a and p_member_b must be the two distinct members of this household';
  end if;

  insert into public.accounts (
    owner_id, created_by, kind, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, icon, color
  )
  select p_member_a, p_member_a, kind, name, currency,
         opening_balance_e4, opening_balance_at, include_in_total, icon, color
  from public.accounts where id = p_old_account_id
  returning id into v_new_for_a;

  insert into public.accounts (
    owner_id, created_by, kind, name, currency,
    opening_balance_e4, opening_balance_at, include_in_total, icon, color
  )
  select p_member_b, p_member_b, kind, name, currency,
         opening_balance_e4, opening_balance_at, include_in_total, icon, color
  from public.accounts where id = p_old_account_id
  returning id into v_new_for_b;

  insert into public.transactions (
    owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, source, status
  )
  select
    fork.fork_owner, t.created_by, fork.fork_account_id,
    case
      when t.transfer_group_id is not null then (
        select id from public.categories
        where owner_id = fork.fork_owner
          and kind = case when t.amount_e4 < 0 then 'expense'::public.category_kind else 'income'::public.category_kind end
          and is_default and deleted_at is null
      )
      else public.fork_category_id(fork.fork_owner, t.category_id)
    end,
    t.amount_e4, t.currency, t.occurred_at, t.merchant_raw, t.merchant_normalized,
    case when t.transfer_group_id is not null then 'adjustment'::public.transaction_source else t.source end,
    t.status
  from public.transactions t
  cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
  where t.account_id = p_old_account_id and t.deleted_at is null;

  insert into public.recurring_rules (
    created_by, account_id, category_id, to_account_id, amount_e4, currency, frequency, next_due_at, active
  )
  select rr.created_by, fork.fork_account_id,
         case when rr.category_id is null then null else public.fork_category_id(fork.fork_owner, rr.category_id) end,
         rr.to_account_id,
         rr.amount_e4, rr.currency, rr.frequency, rr.next_due_at, rr.active
  from public.recurring_rules rr
  cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
  where rr.account_id = p_old_account_id
    and (rr.to_account_id is null or fork.fork_owner = rr.owner_id);

  update public.card_mappings
  set account_id = case when owner_id = p_member_a then v_new_for_a else v_new_for_b end
  where account_id = p_old_account_id;

  delete from public.net_worth_daily where account_id = p_old_account_id;
  update public.household_accounts set deleted_at = now()
  where account_id = p_old_account_id and deleted_at is null;
  update public.accounts set archived_at = coalesce(archived_at, now()) where id = p_old_account_id;
end;
$function$;


revoke all on function public.fork_one_account(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.fork_one_account(uuid, uuid, uuid) to postgres;
