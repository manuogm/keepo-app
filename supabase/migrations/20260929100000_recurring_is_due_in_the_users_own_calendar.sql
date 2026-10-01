-- ============================================================================
-- A recurring rule is due in the user's own calendar, and stops on an
-- account they have put away.
--
-- 20260928100000 fixed the *instant* an occurrence is stored at. This fixes
-- the three remaining gaps in the same feature, all found by walking it end
-- to end rather than by a failing test:
--
--   1. **Due-ness was decided in UTC.** The cron fired
--      `materialize_recurring(current_date)` — the *server's* today — so a
--      user west of UTC got an occurrence hours before their day began (a
--      row dated tomorrow, sitting in their ledger), and a user east of UTC
--      got it late. Neither is "on the day I chose".
--
--   2. **Archiving an account did not stop its rules.** `delete_account`
--      retires them; archival never did. Meanwhile the Recurring list and
--      the Upcoming widget both hide rules on archived accounts — so the
--      rule became **invisible while still minting transactions every
--      month**, onto an account the user had put away, with no surface
--      anywhere to stop it.
--
--   3. **A rule's `currency` was never checked against its account.**
--      `balance = opening_balance + SUM(amount)` requires every row to be in
--      its account's currency (money rule 1). Nothing enforced that the
--      column the client sends matches, and materialization trusted it for
--      the source leg while reading the account for the destination leg —
--      two sources of truth for one fact.
--
--   4. **Deleting a category orphaned the rules filed under it.**
--      `delete_category_and_reassign` moved every *transaction* onto the
--      owner's default category and left `recurring_rules` pointing at the
--      row it had just tombstoned. The rule then vanished from the Recurring
--      list — which resolves a rule's subject through a live category — while
--      continuing to mint a transaction every month under a category the user
--      had deleted. Same shape as (2): invisible, unstoppable, still writing.
-- ============================================================================

-- ============================================================================
-- validate_recurring_rule_sign — also the currency, now.
--
-- An account's currency is immutable (`update_account` has no parameter for
-- it), so this can only ever be wrong at creation — which is exactly where a
-- clear error is worth having, rather than a balance that silently stops
-- summing months later.
-- ============================================================================

-- **Repaired before the check exists, not after.**
--
-- This check fires on every future insert AND update of a rule. A row already
-- carrying a currency that disagrees with its account would therefore not
-- merely be wrong — it would become **unfixable through the app** and would
-- take two unrelated operations down with it, because both write to
-- `recurring_rules`: `delete_category_and_reassign` re-points rules at the
-- default category, and `fork_one_account` copies them when a household
-- splits. A user would find they could no longer delete a category.
--
-- Such a row is possible: `RecurringRuleRepository.create` historically sent
-- `selectedAccount?.currency ?? "EUR"`, so an account that was not in the
-- loaded list at save time wrote "EUR" against whatever the account really
-- was. The account's currency is the authoritative value (money rule 1 — the
-- balance is a running sum over rows in it), so conforming the rule to the
-- account is the repair, never the reverse.
--
-- Touches only rows that violate the invariant, so it is idempotent and a
-- no-op on a database that never had one. Runs under the OLD trigger, whose
-- sign/kind rules this does not disturb.
update public.recurring_rules r
set currency = a.currency
from public.accounts a
where a.id = r.account_id
  and r.currency is distinct from a.currency;

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
  select currency into v_from_currency from public.accounts where id = new.account_id;

  -- Money rule 1: every row in an account's currency, because the balance is
  -- a running sum over them. A rule that disagrees with its own account
  -- would materialize rows that cannot be summed with the rest.
  if new.currency is distinct from v_from_currency then
    raise exception 'a recurring rule''s currency must match its account''s (% vs %)',
      new.currency, v_from_currency;
  end if;

  if new.to_account_id is not null then
    if new.amount_e4 >= 0 then
      raise exception 'a recurring transfer''s amount must be negative — it is the outflow from the source account';
    end if;

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
-- materialize_recurring — due in the owner's calendar, dormant on a put-away
-- account, and taking the currency from the account itself.
--
-- **`p_through` now defaults to null, meaning "each owner's own today".**
-- Passing a date still forces one calendar for every rule, which is what the
-- pgTAP suite and any ops backfill want — so the existing surface is
-- unchanged and only the default moved. The cron is re-scheduled below to
-- stop passing `current_date`, which was the bug.
--
-- **Dormant, not retired.** A rule on an archived account skips its inserts
-- but still advances `next_due_at`. Skipping without advancing would make
-- `recurring_materialization_check()` report it overdue forever, and would
-- flood the ledger with months of backdated rows the moment the account came
-- back. Advancing without inserting says the honest thing: the instruction
-- was dormant while the account was away, those occurrences did not happen,
-- and unarchiving resumes from the next one. `active` is deliberately left
-- alone, so the user's own pause state survives an archive/unarchive round
-- trip — which is why this is not simply `delete_account`'s approach.
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
begin
  for v_rule in
    select * from public.recurring_rules where active
    order by id
    for update
  loop
    -- The rule's owner, not the caller: this runs as a cron job with no
    -- `auth.uid()`, and each rule in the loop can belong to somebody else.
    select public.safe_time_zone(p.time_zone) into v_tz
    from public.profiles p where p.id = v_rule.owner_id;
    v_tz := coalesce(v_tz, 'UTC');

    -- **The whole point.** `current_date` here would be the server's day;
    -- what decides whether a rule is due is the day it is *where its owner
    -- is*. An explicit p_through overrides for every rule, which is what a
    -- test or a deliberate backfill means by it.
    v_through := coalesce(p_through, (now() at time zone v_tz)::date);

    continue when v_rule.next_due_at > v_through;

    -- Both ends have to be usable. A rule reached only through its
    -- destination counts: minting the outflow while the inflow has nowhere
    -- to land would leave a one-sided transfer.
    select not (
      a.deleted_at is null and a.archived_at is null
      and (v_rule.to_account_id is null or (d.deleted_at is null and d.archived_at is null))
    )
    into v_dormant
    from public.accounts a
    left join public.accounts d on d.id = v_rule.to_account_id
    where a.id = v_rule.account_id;
    v_dormant := coalesce(v_dormant, true);

    -- From the account, never from the rule's own copy: money rule 1 makes
    -- the account's currency the only thing a balance can be summed in, and
    -- the destination leg has always read it this way.
    select currency into v_currency from public.accounts where id = v_rule.account_id;
    v_to_currency := null;
    if v_rule.to_account_id is not null then
      select currency into v_to_currency from public.accounts where id = v_rule.to_account_id;
    end if;

    v_occurrence := v_rule.next_due_at;

    while v_occurrence <= v_through loop
      v_at := v_occurrence::timestamp at time zone v_tz;

      if v_dormant then
        null;  -- see the header: skipped, but the walk below still advances.
      elsif v_rule.to_account_id is null then
        insert into public.transactions (
          id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
          source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id, v_rule.category_id,
          v_rule.amount_e4, v_currency, v_at,
          'recurring', v_rule.id::text || '|' || v_occurrence::text, v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing;

        if found then
          v_inserted := v_inserted + 1;
        end if;
      else
        v_group := gen_random_uuid();

        insert into public.transactions (
          id, owner_id, created_by, account_id, amount_e4, currency, occurred_at,
          transfer_group_id, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id,
          v_rule.amount_e4, v_currency, v_at,
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
          -v_rule.amount_e4, v_to_currency, v_at,
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
    set next_due_at = v_occurrence, last_materialized_at = v_through
    where id = v_rule.id;
  end loop;

  return v_inserted;
end;
$$;

revoke all on function public.materialize_recurring(date) from public;
grant execute on function public.materialize_recurring(date) to service_role;

-- ============================================================================
-- The schedule.
--
-- **Hourly, not daily.** With due-ness decided per zone, a daily 02:00 UTC
-- run still lands an occurrence on the correct local day everywhere — but as
-- much as twenty-three hours into it, so a user could reach bedtime before
-- the rent they expected that morning appeared. Hourly bounds the wait to
-- under an hour of local midnight for every zone on earth.
--
-- Frequency is a free parameter precisely because of the idempotency
-- backstop: every insert is guarded by the partial unique index on
-- (owner_id, source, external_id), so a run with nothing newly due inserts
-- nothing and touches only the `next_due_at` of rules it actually advanced.
-- The partial index `recurring_rules_due_idx (next_due_at) where active`
-- makes the scan cheap.
--
-- Unscheduled via a select over `cron.job` rather than by name:
-- `cron.unschedule('name')` raises when the job is absent, which would make
-- this migration fail on any database where the schedule was never created.
-- ============================================================================

select cron.unschedule(jobid) from cron.job where jobname = 'materialize-recurring-daily';
select cron.unschedule(jobid) from cron.job where jobname = 'materialize-recurring-hourly';

select cron.schedule(
  'materialize-recurring-hourly', '0 * * * *', $$select public.materialize_recurring()$$
);

-- ============================================================================
-- delete_category_and_reassign — recurring rules move too.
--
-- The transactions filed under a deleted category are reassigned to the
-- owner's default one; a standing instruction to keep filing more of them is
-- the same fact about the same category, and was simply missed. Leaving it
-- behind made the rule invisible (the Recurring list resolves a subject
-- through a live category) while `materialize_recurring` went on writing
-- rows under a tombstone.
--
-- **Rebased onto `20260814100100`'s body, not `20260812100000`'s.** The
-- first draft here restated the original, which still referenced
-- `categories.system_key` — a column dropped in between. Second time in two
-- migrations that a restatement reached for a stale revision; this one the
-- test suite caught immediately, `fork_one_account`'s it could not have.
-- `grep -l '<function>' supabase/migrations/*.sql | tail -1` before restating
-- anything, every time.
--
-- `v_other_id` is guaranteed to be the same `kind`, so
-- `validate_recurring_rule_sign`'s expense/income check still passes on the
-- rows this touches — the same guarantee the transactions update above it
-- already relies on. Transfer rules carry no category and are untouched by
-- construction.
-- ============================================================================

create or replace function public.delete_category_and_reassign(p_category_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_category record;
  v_other_id uuid;
  v_reassigned integer;
begin
  select id, kind, is_default, owner_id, deleted_at
  into v_category
  from public.categories
  where id = p_category_id;

  if v_category.id is null or v_category.owner_id <> v_owner or v_category.deleted_at is not null then
    raise exception 'category not found or not accessible';
  end if;

  if v_category.is_default then
    raise exception 'this category cannot be deleted';
  end if;

  select id into v_other_id
  from public.categories
  where owner_id = v_owner and kind = v_category.kind and is_default and deleted_at is null;

  if v_other_id is null then
    raise exception 'no default category found to reassign into';
  end if;

  update public.transactions
  set category_id = v_other_id
  where category_id = p_category_id and owner_id = v_owner and deleted_at is null;

  get diagnostics v_reassigned = row_count;

  -- The standing instructions that would otherwise keep filing new rows
  -- under the tombstone. Deliberately NOT counted in the return value: it
  -- reports how many transactions moved, which is what the client shows the
  -- user, and a rule is not a transaction.
  update public.recurring_rules
  set category_id = v_other_id
  where category_id = p_category_id and owner_id = v_owner;

  update public.categories
  set deleted_at = now()
  where id = p_category_id;

  return v_reassigned;
end;
$$;

revoke all on function public.delete_category_and_reassign(uuid) from public;
grant execute on function public.delete_category_and_reassign(uuid) to authenticated;
