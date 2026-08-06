-- Phase 14: recurring transactions. Store the rule, never future rows
-- (spec) — `next_occurrences()` projects upcoming instances at read time;
-- `materialize_recurring()` is the only thing that ever turns a due
-- occurrence into a real `transactions` row, and only up to today.

create type recurring_frequency as enum ('weekly', 'monthly', 'yearly');

-- ============================================================================
-- recurring_rules — household-aware from day one via can_read_account/
-- can_write_account (the same functions accounts/transactions already use),
-- not a raw owner_id check. This is deliberately NOT the H2/H3 mistake this
-- project already paid for twice (accounts, then update_account/
-- archive_account/delete_account) — a hardcoded owner check here would need
-- an identical retrofit the moment someone creates a recurring rule against
-- a shared account.
-- ============================================================================

create table recurring_rules (
  id uuid primary key default gen_random_uuid(),
  -- Derived from account_id by trigger below, never client-set — same
  -- reasoning as transactions.account_kind/category_kind: it's what lets
  -- the composite FKs below enforce "same owner as the account"
  -- declaratively rather than trusting application code.
  owner_id uuid not null references auth.users (id) deferrable initially deferred,
  created_by uuid not null references auth.users (id) deferrable initially deferred,
  account_id uuid not null,
  category_id uuid not null,
  amount numeric(20, 4) not null check (amount <> 0),
  currency text not null,
  frequency recurring_frequency not null,
  next_due_at date not null,
  last_materialized_at date,
  active boolean not null default true,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_id),
  foreign key (account_id, owner_id) references accounts (id, owner_id) deferrable initially deferred,
  foreign key (category_id, owner_id) references categories (id, owner_id) deferrable initially deferred
);

alter table recurring_rules enable row level security;

create policy recurring_rules_select on recurring_rules
  for select to authenticated
  using (can_read_account(account_id));

create policy recurring_rules_insert on recurring_rules
  for insert to authenticated
  with check (can_write_account(account_id) and created_by = (select auth.uid()));

create policy recurring_rules_update on recurring_rules
  for update to authenticated
  using (can_write_account(account_id))
  with check (can_write_account(account_id));

grant select, insert, update on recurring_rules to authenticated, service_role;

create index recurring_rules_account_id_idx on recurring_rules (account_id);
create index recurring_rules_due_idx on recurring_rules (next_due_at) where active;

create trigger recurring_rules_set_updated_at
  before update on recurring_rules
  for each row execute function set_updated_at();

create trigger recurring_rules_bump_version
  before update on recurring_rules
  for each row execute function bump_version();

create function set_recurring_rule_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select owner_id into new.owner_id from public.accounts where id = new.account_id;
  return new;
end;
$$;

revoke all on function set_recurring_rule_owner() from public;

create trigger recurring_rules_set_owner
  before insert or update on recurring_rules
  for each row execute function set_recurring_rule_owner();

-- A wrong sign here would only surface as a mysterious CHECK violation
-- inside a 2am cron job's insert — validated up front instead, at the
-- point the rule is actually created or edited, same reasoning as
-- transactions' own sign_matches_category_kind but enforced via trigger
-- since recurring_rules has no derived category_kind column of its own.
create function validate_recurring_rule_sign()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind public.category_kind;
begin
  select kind into v_kind from public.categories where id = new.category_id;

  if v_kind = 'expense' and new.amount >= 0 then
    raise exception 'an expense recurring rule''s amount must be negative';
  elsif v_kind = 'income' and new.amount <= 0 then
    raise exception 'an income recurring rule''s amount must be positive';
  end if;

  return new;
end;
$$;

revoke all on function validate_recurring_rule_sign() from public;

create trigger recurring_rules_validate_sign
  before insert or update on recurring_rules
  for each row execute function validate_recurring_rule_sign();

-- ============================================================================
-- transactions.recurring_rule_id — nullable, set only by materialize_recurring.
-- Composite FK to (id, owner_id), same pattern as category_id/account_id,
-- so a materialized row can never reference another owner's rule.
-- ============================================================================

alter table transactions add column recurring_rule_id uuid;

alter table transactions add constraint transactions_recurring_rule_owner_fk
  foreign key (recurring_rule_id, owner_id) references recurring_rules (id, owner_id) deferrable initially deferred;

create index transactions_recurring_rule_id_idx on transactions (recurring_rule_id) where recurring_rule_id is not null;

create or replace view transactions_with_details
with (security_invoker = true) as
select
  t.id as transaction_id,
  t.account_id,
  a.name as account_name,
  t.category_id,
  c.name as category_name,
  t.amount,
  t.currency,
  cur.minor_unit,
  t.occurred_at,
  t.merchant_raw,
  t.merchant_normalized,
  t.transfer_group_id,
  t.source,
  t.status,
  case
    when t.transfer_group_id is not null then 'transfer'
    when t.amount < 0 then 'expense'
    else 'income'
  end as kind,
  t.created_by,
  t.created_at,
  t.version,
  p.base_currency,
  bc.minor_unit as base_minor_unit,
  fx_convert(t.amount, t.currency, p.base_currency, t.occurred_at::date) as amount_base,
  (fx_convert(t.amount, t.currency, p.base_currency, t.occurred_at::date) is null) as has_missing_rate,
  t.recurring_rule_id
from transactions t
join accounts a on a.id = t.account_id
left join categories c on c.id = t.category_id
join currencies cur on cur.code = t.currency
left join profiles p on p.id = (select auth.uid())
left join currencies bc on bc.code = p.base_currency
where t.deleted_at is null;

grant select on transactions_with_details to authenticated, service_role;

-- ============================================================================
-- next_occurrence_date — the one place a frequency turns into "add this
-- much time." Postgres's own date+interval arithmetic already clamps a
-- month-end/leap-day overflow sensibly (Jan 31 + 1 month = Feb 29 in a leap
-- year, Feb 28 otherwise; re-adding a month from that clamped date lands on
-- Mar 31, not a permanently-shifted day) — confirmed empirically, not
-- assumed, before relying on it here. No custom "anchor day" logic on top;
-- the spec doesn't ask for one.
-- ============================================================================

create function next_occurrence_date(p_date date, p_frequency recurring_frequency)
returns date
language sql
immutable
as $$
  select case p_frequency
    when 'weekly' then p_date + interval '7 days'
    when 'monthly' then p_date + interval '1 month'
    when 'yearly' then p_date + interval '1 year'
  end::date;
$$;

-- ============================================================================
-- next_occurrences — read-time projection ONLY. Never writes anything;
-- exists so the client can show "next: Aug 12, Sep 12, Oct 12" without a
-- single row existing for any of them.
-- ============================================================================

create function next_occurrences(p_rule_id uuid, p_count int default 5)
returns table (occurrence_date date)
language plpgsql
security invoker
stable
set search_path = ''
as $$
declare
  v_rule record;
  v_date date;
  i int;
begin
  select * into v_rule from public.recurring_rules where id = p_rule_id;
  if v_rule.id is null then
    return;
  end if;

  v_date := v_rule.next_due_at;
  for i in 1..p_count loop
    occurrence_date := v_date;
    return next;
    v_date := public.next_occurrence_date(v_date, v_rule.frequency);
  end loop;
end;
$$;

revoke all on function next_occurrences(uuid, int) from public;
grant execute on function next_occurrences(uuid, int) to authenticated, service_role;

-- ============================================================================
-- materialize_recurring — the only writer of recurring-sourced transactions.
-- `on conflict ... do nothing` against the existing partial unique index on
-- (owner_id, source, external_id) is the idempotency backstop: re-running
-- this for a date range already materialized inserts zero rows, by
-- construction, not by a separate "already materialized" check. Runs as
-- SECURITY DEFINER (pg_cron calls it as postgres) — RLS is irrelevant here,
-- this walks every owner's due rules in one pass, like every other
-- cross-owner scheduled job in this codebase (sync-fx-rates, ops_health).
-- ============================================================================

create function materialize_recurring(p_through date default current_date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule record;
  v_occurrence date;
  v_inserted integer := 0;
begin
  for v_rule in
    select * from public.recurring_rules where active and next_due_at <= p_through
    order by id
    for update
  loop
    v_occurrence := v_rule.next_due_at;

    while v_occurrence <= p_through loop
      insert into public.transactions (
        id, owner_id, created_by, account_id, category_id, amount, currency, occurred_at,
        source, external_id, recurring_rule_id
      ) values (
        gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id, v_rule.category_id,
        v_rule.amount, v_rule.currency, v_occurrence::timestamptz,
        'recurring', v_rule.id::text || '|' || v_occurrence::text, v_rule.id
      )
      on conflict (owner_id, source, external_id) where external_id is not null do nothing;

      if found then
        v_inserted := v_inserted + 1;
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

revoke all on function materialize_recurring(date) from public;
grant execute on function materialize_recurring(date) to service_role;

select cron.schedule('materialize-recurring-daily', '0 2 * * *', $$select public.materialize_recurring(current_date)$$);

-- ============================================================================
-- recurring_materialization_check — replaces Phase 13's deliberate stub
-- now that recurring_rules actually exists. Fixed forward in this new
-- migration rather than editing the already-hosted Phase 13 file, per this
-- project's established precedent for anything already pushed.
-- ============================================================================

create or replace function recurring_materialization_check()
returns table (healthy boolean, detail text)
language sql
security invoker
stable
set search_path = ''
as $$
  select
    not exists (
      select 1 from public.recurring_rules where active and next_due_at < current_date - 1
    ),
    (
      select count(*)::text from public.recurring_rules
      where active and next_due_at < current_date - 1
    ) || ' active recurring rule(s) overdue for materialization';
$$;
