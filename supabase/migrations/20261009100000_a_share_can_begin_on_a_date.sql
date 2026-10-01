-- A share can begin on a date.
--
-- Phase 1 of the "Transfers & household sharing" workstream
-- (keepo-v1-master-plan.md). Server only, and no user-visible change: every
-- existing share has `history_from = null`, which means full history — what
-- every share has always meant — and nothing in this migration sets it. The
-- sharing API that lets an owner choose (Phase 4) and the sync that hands a
-- partner the balance carried into the start date (Phase 2) build on this.
--
-- ============================================================================
-- 1. household_accounts.history_from
-- ============================================================================
--
-- The moment from which a partner sees this account's transactions. Null is
-- full history. The boundary is on `occurred_at`, never `created_at`: a
-- backdated entry typed after the share would otherwise be both "before" the
-- balance carried into the start date and "after" it, and count twice.
--
-- ============================================================================
-- 2. One visibility predicate
-- ============================================================================
--
-- `can_read_account` answered "may this user see this account's rows?" with
-- no notion of when a row happened. Every place that decides whether a
-- transaction — or something that exists only because of transactions: a
-- tag link, a partner's tag, a category — reaches a partner now asks one
-- question instead:
--
--   transaction_shared_into(account, at)  the household a live share of this
--                                         account reaches at that moment
--   transaction_visible_to(user, account, at)
--                                         the owner, or a live member of
--                                         that household
--
-- Both are internal: they take any user or account, so exposing them would
-- let a caller probe somebody else's household. Policies and the client-
-- reachable functions go through two self-scoped wrappers:
--
--   can_read_transaction(account, owner, at)  reading, editing, deleting an
--                                             existing row. A row with no
--                                             account (an unassigned capture)
--                                             stays its owner's alone.
--   can_place_transaction(account, at)        putting a row somewhere: a
--                                             create, or a move to another
--                                             account. The date must be one
--                                             the caller can see, and the
--                                             account must be live — review
--                                             finding #16: create_transfer and
--                                             `transactions_insert` accepted a
--                                             deleted account.
--
-- A partner therefore cannot create, edit, delete or re-date anything before
-- the start date, and cannot move a row there.
--
-- `can_write_account` is unchanged and still answers account-level writes
-- (rename, archive, reorder, recurring rules). Rules stay visible whatever
-- the start date: they describe the future.
--
-- ============================================================================
-- 3. account_balance_on is gated, and runs as its definer
-- ============================================================================
--
-- It was SECURITY INVOKER, so under the new transaction policy a partner
-- would have summed only the rows they can see onto the untouched opening
-- balance — a wrong number, not a hidden one. As definer it returns the true
-- balance to anyone who can read the account, and nothing to anyone else.
-- A caller with no user at all (the service role, cron, a test) is trusted,
-- as `refresh_net_worth_daily` already does.
--
-- ============================================================================
-- 4. update_account stops writing the opening balance
-- ============================================================================
--
-- The form echoes the opening balance it loaded from the local mirror; a
-- balance change goes through `set_account_balance`, never through here.
-- Once a partner's mirror holds an adjusted opening (Phase 2), a partner's
-- rename would have written that figure over the owner's real one.
-- `p_opening_balance_e4` stays in the signature so the build already on a
-- phone keeps binding; it is ignored.

alter table public.household_accounts add column history_from timestamptz;

comment on column public.household_accounts.history_from is
  'The moment from which household members other than the owner see this account''s transactions '
  '(on occurred_at). Null = full history. See transaction_visible_to.';

-- ============================================================================
-- The predicate
-- ============================================================================

create function public.transaction_shared_into(p_account_id uuid, p_occurred_at timestamptz)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  -- At most one row: `household_accounts_one_household_per_account`.
  select ha.household_id
  from public.household_accounts ha
  where ha.account_id = p_account_id
    and ha.deleted_at is null
    and (ha.history_from is null or p_occurred_at >= ha.history_from);
$$;

revoke all on function public.transaction_shared_into(uuid, timestamptz) from public, anon, authenticated;

create function public.transaction_visible_to(p_user uuid, p_account_id uuid, p_occurred_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.accounts a where a.id = p_account_id and a.owner_id = p_user
  )
  or exists (
    select 1
    from public.household_members hm
    where hm.user_id = p_user
      and hm.deleted_at is null
      and hm.household_id = public.transaction_shared_into(p_account_id, p_occurred_at)
  );
$$;

revoke all on function public.transaction_visible_to(uuid, uuid, timestamptz) from public, anon, authenticated;

create function public.can_read_transaction(p_account_id uuid, p_owner_id uuid, p_occurred_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_account_id is null then p_owner_id = (select auth.uid())
    else public.transaction_visible_to((select auth.uid()), p_account_id, p_occurred_at)
  end;
$$;

revoke all on function public.can_read_transaction(uuid, uuid, timestamptz) from public, anon;
grant execute on function public.can_read_transaction(uuid, uuid, timestamptz) to authenticated, service_role;

create function public.can_place_transaction(p_account_id uuid, p_occurred_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.accounts a where a.id = p_account_id and a.deleted_at is null)
    and public.transaction_visible_to((select auth.uid()), p_account_id, p_occurred_at);
$$;

revoke all on function public.can_place_transaction(uuid, timestamptz) from public, anon;
grant execute on function public.can_place_transaction(uuid, timestamptz) to authenticated, service_role;

-- The same two questions, raising a message a person can act on. Only the
-- date question has its own text: every other refusal is the long-standing
-- "not found or not accessible", which says nothing about somebody else's
-- account.

create function public.assert_transaction_date_visible(p_account_id uuid, p_occurred_at timestamptz)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.transaction_visible_to((select auth.uid()), p_account_id, p_occurred_at) then
    raise exception 'That date is before this account was shared with you. Pick a later date.';
  end if;
end;
$$;

revoke all on function public.assert_transaction_date_visible(uuid, timestamptz) from public, anon, authenticated;

create function public.assert_transaction_placeable(p_account_id uuid, p_occurred_at timestamptz)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.accounts a where a.id = p_account_id and a.deleted_at is null)
     or not public.can_read_account(p_account_id) then
    raise exception 'account not found or not accessible';
  end if;

  perform public.assert_transaction_date_visible(p_account_id, p_occurred_at);
end;
$$;

-- `create_transfer` runs as its caller, so the caller needs it. It raises
-- only about the caller's own access.
revoke all on function public.assert_transaction_placeable(uuid, timestamptz) from public, anon;
grant execute on function public.assert_transaction_placeable(uuid, timestamptz) to authenticated, service_role;

-- ============================================================================
-- Policies
-- ============================================================================

alter policy transactions_select on public.transactions
  using (public.can_read_transaction(account_id, owner_id, occurred_at));

alter policy transactions_insert on public.transactions
  with check (
    public.can_place_transaction(account_id, occurred_at)
    and created_by = (select auth.uid())
    and source = any (array['manual'::public.transaction_source, 'csv_import'::public.transaction_source])
    and status = 'confirmed'::public.transaction_status
    and external_id is null
    and card_identifier is null
    and recurring_rule_id is null
  );

-- No UPDATE grant exists on `transactions` (every edit is an RPC); restated
-- so the policy cannot quietly disagree with the RPCs if one is ever added.
alter policy transactions_update on public.transactions
  using (public.can_read_transaction(account_id, owner_id, occurred_at))
  with check (public.can_read_transaction(account_id, owner_id, occurred_at));

alter policy transaction_tags_select on public.transaction_tags
  using (exists (
    select 1 from public.transactions t
    where t.id = transaction_tags.transaction_id
      and public.can_read_transaction(t.account_id, t.owner_id, t.occurred_at)
  ));

alter policy transaction_tags_insert on public.transaction_tags
  with check (
    public.can_read_tag(tag_id)
    and exists (
      select 1 from public.transactions t
      where t.id = transaction_tags.transaction_id
        and public.can_read_transaction(t.account_id, t.owner_id, t.occurred_at)
    )
  );

alter policy transaction_tags_update on public.transaction_tags
  using (exists (
    select 1 from public.transactions t
    where t.id = transaction_tags.transaction_id
      and public.can_read_transaction(t.account_id, t.owner_id, t.occurred_at)
  ))
  with check (exists (
    select 1 from public.transactions t
    where t.id = transaction_tags.transaction_id
      and public.can_read_transaction(t.account_id, t.owner_id, t.occurred_at)
  ));

-- ============================================================================
-- What exists only because of transactions
-- ============================================================================

-- A partner's tag is readable through a link on a transaction the household
-- sees — not merely one on a shared account.
create or replace function public.can_read_tag(p_tag_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.tags where id = p_tag_id and owner_id = (select auth.uid())
  )
  or exists (
    select 1
    from public.transaction_tags tt
    join public.transactions t on t.id = tt.transaction_id
    where tt.tag_id = p_tag_id
      and tt.deleted_at is null
      and t.deleted_at is null
      and public.transaction_shared_into(t.account_id, t.occurred_at) = public.my_household_id()
  );
$$;

-- The household through which a tag reaches the other member. A link on a
-- transaction before the start date reaches nobody.
create or replace function public.household_sharing_tag(p_tag_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select public.transaction_shared_into(t.account_id, t.occurred_at)
  from public.transaction_tags tt
  join public.transactions t on t.id = tt.transaction_id
  where tt.tag_id = p_tag_id
    and tt.deleted_at is null
    and t.deleted_at is null
    and public.transaction_shared_into(t.account_id, t.occurred_at) is not null
  limit 1;
$$;

create or replace function public.can_read_category(p_category_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.categories c
    where c.id = p_category_id
      and (
        -- yours
        c.owner_id = (select auth.uid())
        -- or deliberately shared by a member of your household
        or (
          c.shared_group_id is not null
          and exists (
            select 1
            from public.household_members mine
            join public.household_members theirs on theirs.household_id = mine.household_id
            where mine.user_id = (select auth.uid()) and mine.deleted_at is null
              and theirs.user_id = c.owner_id and theirs.deleted_at is null
          )
        )
        -- or it labels a transaction you can see
        or exists (
          select 1 from public.transactions t
          where t.category_id = c.id
            and t.account_id is not null
            and t.deleted_at is null
            and public.transaction_visible_to((select auth.uid()), t.account_id, t.occurred_at)
        )
      )
  );
$$;

-- ============================================================================
-- Transaction write paths
-- ============================================================================

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

create or replace function public.update_transaction(
  p_id uuid, p_expected_version integer, p_account_id uuid, p_category_id uuid, p_amount_e4 bigint,
  p_currency text, p_occurred_at timestamptz, p_merchant_raw text default null, p_notes text default null,
  p_original_amount_e4 bigint default null, p_original_currency text default null, p_title text default null
)
returns table(conflict boolean, transaction transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.transactions;
  v_original_amount bigint := p_original_amount_e4;
  v_original_currency text := nullif(upper(trim(coalesce(p_original_currency, ''))), '');
  v_title text := nullif(btrim(p_title), '');
begin
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, card_identifier, occurred_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null
     or not public.can_read_transaction(v_current.account_id, v_current.owner_id, v_current.occurred_at) then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  perform public.assert_transaction_placeable(p_account_id, p_occurred_at);

  if v_original_currency is null or v_original_currency = p_currency then
    v_original_amount := null;
    v_original_currency := null;
  end if;

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount_e4 = p_amount_e4,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw,
    notes = p_notes,
    title = v_title,
    original_amount_e4 = v_original_amount,
    original_currency = v_original_currency
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    perform public.record_transaction_conflict(p_id, p_expected_version, v_current.version, jsonb_build_object(
      'rpc', 'update_transaction', 'account_id', p_account_id, 'category_id', p_category_id,
      'amount_e4', p_amount_e4, 'currency', p_currency, 'occurred_at', p_occurred_at,
      'merchant_raw', p_merchant_raw, 'notes', p_notes, 'original_amount_e4', v_original_amount,
      'original_currency', v_original_currency, 'title', v_title
    ));

    return query select true, null::public.transactions;
    return;
  end if;

  if v_current.account_id is null and v_current.source = 'capture' and v_current.card_identifier is not null then
    perform public.link_card_to_account(v_owner, v_current.card_identifier, p_account_id);
  end if;

  return query select false, v_result;
end;
$$;

create or replace function public.review_capture_transaction(
  p_id uuid, p_expected_version integer, p_account_id uuid, p_category_id uuid, p_amount_e4 bigint,
  p_currency text, p_occurred_at timestamptz, p_merchant_raw text default null, p_notes text default null,
  p_original_amount_e4 bigint default null, p_original_currency text default null, p_title text default null
)
returns table(conflict boolean, transaction transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_current record;
  v_result public.transactions;
  v_original_amount bigint := p_original_amount_e4;
  v_original_currency text := nullif(upper(trim(coalesce(p_original_currency, ''))), '');
  v_title text := nullif(btrim(p_title), '');
begin
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, status, card_identifier,
         merchant_normalized, occurred_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null
     or not public.can_read_transaction(v_current.account_id, v_current.owner_id, v_current.occurred_at) then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  if v_current.source <> 'capture' or v_current.status <> 'pending' then
    raise exception 'transaction % is not a pending capture — use update_transaction', p_id;
  end if;

  perform public.assert_transaction_placeable(p_account_id, p_occurred_at);

  if v_original_currency is null or v_original_currency = p_currency then
    v_original_amount := null;
    v_original_currency := null;
  end if;

  update public.transactions
  set
    account_id = p_account_id,
    category_id = p_category_id,
    amount_e4 = p_amount_e4,
    currency = p_currency,
    occurred_at = p_occurred_at,
    merchant_raw = p_merchant_raw,
    notes = p_notes,
    title = v_title,
    status = 'confirmed',
    original_amount_e4 = v_original_amount,
    original_currency = v_original_currency
  where id = p_id and version = p_expected_version
  returning * into v_result;

  if v_result.id is null then
    perform public.record_transaction_conflict(p_id, p_expected_version, v_current.version, jsonb_build_object(
      'rpc', 'review_capture_transaction', 'account_id', p_account_id, 'category_id', p_category_id,
      'amount_e4', p_amount_e4, 'currency', p_currency, 'occurred_at', p_occurred_at,
      'merchant_raw', p_merchant_raw, 'notes', p_notes, 'original_amount_e4', v_original_amount,
      'original_currency', v_original_currency, 'title', v_title
    ));
    return query select true, null::public.transactions;
    return;
  end if;

  if v_current.account_id is null and v_current.card_identifier is not null then
    perform public.link_card_to_account(v_owner, v_current.card_identifier, p_account_id);
  end if;

  if v_current.merchant_normalized is not null then
    insert into public.merchant_category_map (owner_id, merchant_pattern, category_id)
    values (v_owner, v_current.merchant_normalized, p_category_id)
    on conflict (owner_id, merchant_pattern) do update set category_id = excluded.category_id, updated_at = now();
  end if;

  return query select false, v_result;
end;
$$;

create or replace function public.delete_transaction(p_id uuid, p_expected_version integer)
returns table(conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current record;
  v_updated integer;
begin
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, card_identifier, occurred_at
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null
     or not public.can_read_transaction(v_current.account_id, v_current.owner_id, v_current.occurred_at) then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use delete_transfer', p_id;
  end if;

  update public.transactions
  set deleted_at = now()
  where id = p_id and version = p_expected_version;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    perform public.record_transaction_conflict(
      p_id, p_expected_version, v_current.version, jsonb_build_object('rpc', 'delete_transaction')
    );
    return query select true;
    return;
  end if;

  -- Fix B: the placeholder mapping this capture created has nothing left
  -- to justify it — retire it with the purchase instead of leaving a bare
  -- "Unmapped card" item behind. Placeholders only (`account_id is null`),
  -- and only once no other live pending capture still needs it.
  if v_current.source = 'capture' and v_current.card_identifier is not null then
    update public.card_mappings cm
    set deleted_at = now()
    where cm.owner_id = v_current.owner_id and cm.card_identifier = v_current.card_identifier
      and cm.account_id is null and cm.deleted_at is null
      and not exists (
        select 1 from public.transactions t2
        where t2.owner_id = cm.owner_id and t2.card_identifier = cm.card_identifier
          and t2.source = 'capture' and t2.status = 'pending' and t2.deleted_at is null
      );
  end if;

  return query select false;
end;
$$;

-- The date travels with the question now: a leg moves onto an account only
-- at a moment the caller can see there.
drop function public.transfer_leg_target_currency(uuid, uuid);

create function public.transfer_leg_target_currency(p_account_id uuid, p_leg_owner uuid, p_occurred_at timestamptz)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_account record;
begin
  perform public.assert_transaction_placeable(p_account_id, p_occurred_at);

  select owner_id, currency into v_account from public.accounts where id = p_account_id;

  if v_account.owner_id <> p_leg_owner then
    raise exception 'A transfer can only be moved to another account belonging to the same person.';
  end if;

  return v_account.currency;
end;
$$;

revoke all on function public.transfer_leg_target_currency(uuid, uuid, timestamptz) from public, anon, authenticated;

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

create or replace function public.delete_transfer(
  p_transfer_group_id uuid,
  p_from_expected_version integer,
  p_to_expected_version integer
)
returns table(conflict boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from record;
  v_to record;
begin
  select id, version, account_id, owner_id, occurred_at into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 < 0;

  select id, version, account_id, owner_id, occurred_at into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 > 0;

  if v_from.id is null or v_to.id is null
     or not public.can_read_transaction(v_from.account_id, v_from.owner_id, v_from.occurred_at)
     or not public.can_read_transaction(v_to.account_id, v_to.owner_id, v_to.occurred_at) then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  if v_from.version <> p_from_expected_version or v_to.version <> p_to_expected_version then
    perform public.record_transaction_conflict(
      v_from.id,
      case when v_from.version <> p_from_expected_version then p_from_expected_version else p_to_expected_version end,
      case when v_from.version <> p_from_expected_version then v_from.version else v_to.version end,
      jsonb_build_object('rpc', 'delete_transfer', 'transfer_group_id', p_transfer_group_id)
    );
    return query select true;
    return;
  end if;

  update public.transactions set deleted_at = now()
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set deleted_at = now()
  where id = v_to.id and version = p_to_expected_version;

  return query select false;
end;
$$;

-- ============================================================================
-- Balances and accounts
-- ============================================================================

create or replace function public.account_balance_on(p_account_id uuid, p_date date)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select a.opening_balance_e4 + coalesce((
    select sum(t.amount_e4)
    from public.transactions t
    where t.account_id = a.id
      and t.deleted_at is null
      and t.status = 'confirmed'
      and t.occurred_at <= least(p_date::timestamptz + interval '1 day', now())
  ), 0)
  from public.accounts a
  where a.id = p_account_id
    and ((select auth.uid()) is null or public.can_read_account(a.id));
$$;

create or replace function public.update_account(
  p_id uuid,
  p_expected_version integer,
  p_name text,
  p_opening_balance_e4 bigint,
  p_include_in_total boolean,
  p_icon text,
  p_color text
)
returns table(conflict boolean, account accounts)
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

  -- `p_opening_balance_e4` is ignored: see this migration's header, section 4.
  update public.accounts
  set
    name = p_name,
    include_in_total = p_include_in_total,
    icon = p_icon,
    color = p_color
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
