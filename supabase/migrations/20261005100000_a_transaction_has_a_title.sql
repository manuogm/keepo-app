-- A transaction can have a title.
--
-- The user's words for a transaction — "Coffee with Beth", "Starbucks",
-- "Rent" — as distinct from the note, which is where more detail goes. A
-- title may happen to be a merchant's name but is not one: the merchant is
-- what the card network printed, the title is what the person calls it.
--
-- WHAT THIS MIGRATION IS CAREFUL ABOUT
--
-- 1. **"No title" is always null.** The CHECK requires a trimmed, non-empty
--    string, so "has a title" is a null check everywhere — the same shape
--    `original_currency` has. Every RPC normalizes its parameter with
--    `nullif(btrim(..), '')` so a sloppy or older client can pass whitespace
--    without tripping the constraint.
--
-- 2. **A capture never gets a title.** `capture_transaction` does not take
--    one. The user can add one while reviewing (`review_capture_transaction`).
--
-- 3. **A title never trains the merchant map.** Nothing here writes a title
--    into `merchant_category_map`. The title "memory" is derived on the
--    device from the user's own titled transactions (see
--    `TitleCategoryMatch` in the app), which is also why there is no new
--    table: re-filing a titled transaction updates the memory for free.
--
-- 4. **The capture side of that memory is a hint, not a second resolver.**
--    When a captured merchant has nothing learned, the device may have
--    matched it against a title the user typed before. The matching lives in
--    Swift only — the same one-implementation rule the merchant normalizer
--    follows, for the same reason (`version-logs/capture-hygiene-…`). What
--    reaches the server is the device's answer, as `p_category_hint`, which
--    `resolve_category_for_merchant` consults **after** its own merchant map
--    and **before** the default, and only if it names a live category of the
--    right kind that the owner owns. Same order on both sides, so the local
--    row and the server row cannot disagree and flip the category on the
--    next pull.
--
-- 5. **Every path that writes or copies a transaction carries it**: manual
--    insert (no RPC — the column is simply insertable), `update_transaction`,
--    `review_capture_transaction`, both transfer RPCs (both legs, exactly
--    like notes — a transfer is one act by the user), `materialize_recurring`
--    (every occurrence inherits its rule's title), and `fork_one_account`
--    (leaving a household must not strip the user's own words off their
--    history).
--
-- Every function below is restated from its LAST definition, extracted
-- programmatically and patched, never retyped — per lessons-learned.md:
--   resolve_category_for_merchant   20260830110000
--   capture_transaction             20260923100000
--   review_capture_transaction      20260923100000
--   update_transaction              20260923100000
--   create_transfer                 20260904100000
--   update_transfer                 20260904100000
--   materialize_recurring           20260930100000
--   fork_one_account                20260927100000
--   transactions_with_details       20260923100000
--
-- Backward compatibility with the build already on a phone: every added
-- parameter is defaulted and both columns are nullable, so PostgREST still
-- binds an older client's named-argument calls. One honest cost: an older
-- build that edits a titled transaction sends no `p_title` and so clears it
-- — the same thing it would do to a note it did not know about.

-- ============================================================================
-- 1. The columns
-- ============================================================================

alter table public.transactions add column title text;
alter table public.transactions add constraint transactions_title_shape
  check (title is null or (title = btrim(title) and char_length(title) between 1 and 80));

comment on column public.transactions.title is
  'The user''s own name for the transaction. Never set by capture, never used to train merchant_category_map.';

alter table public.recurring_rules add column title text;
alter table public.recurring_rules add constraint recurring_rules_title_shape
  check (title is null or (title = btrim(title) and char_length(title) between 1 and 80));

comment on column public.recurring_rules.title is
  'Mirrors transactions.title, which is where it lands on every occurrence.';

-- ============================================================================
-- 2. resolve_category_for_merchant — learned merchant, then the caller's
--    hint, then the default.
--
--    Dropped and recreated: a defaulted 4th parameter would otherwise create
--    a second overload and make every existing call ambiguous. Its only
--    remaining caller is capture_transaction, restated below.
-- ============================================================================

drop function public.resolve_category_for_merchant(uuid, text, category_kind);

create function public.resolve_category_for_merchant(
  p_owner uuid, p_merchant_normalized text, p_kind category_kind, p_hint uuid default null
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case when
    p_owner = (select auth.uid())
    or exists (
      select 1
      from public.accounts a
      join public.household_accounts ha on ha.account_id = a.id and ha.deleted_at is null
      join public.household_members hm on hm.household_id = ha.household_id
        and hm.user_id = (select auth.uid()) and hm.deleted_at is null
      where a.owner_id = p_owner
    )
  then coalesce(
    (
      select m.category_id
      from public.merchant_category_map m
      join public.categories c on c.id = m.category_id
      where m.owner_id = p_owner and m.merchant_pattern = p_merchant_normalized and c.kind = p_kind
    ),
    -- The caller's own resolution, consulted only when nothing was learned
    -- for this merchant, and only if it names a live category of the right
    -- kind that p_owner actually owns. A hint that fails any of those is
    -- ignored rather than raised: it is advice, and the default below is
    -- always a correct answer.
    (
      select h.id from public.categories h
      where h.id = p_hint and h.owner_id = p_owner and h.kind = p_kind and h.deleted_at is null
    ),
    (
      select id from public.categories
      where owner_id = p_owner and kind = p_kind and is_default and deleted_at is null
      limit 1
    )
  ) end;
$$;


revoke all on function public.resolve_category_for_merchant(uuid, text, category_kind, uuid) from public;
grant execute on function public.resolve_category_for_merchant(uuid, text, category_kind, uuid) to authenticated;

-- ============================================================================
-- 3. capture_transaction — + p_category_hint (never a title)
-- ============================================================================

drop function public.capture_transaction(uuid, text, text, text, bigint, timestamptz, text, text, text);

create function public.capture_transaction(
  p_id uuid, p_card_identifier text, p_merchant_raw text, p_merchant_normalized text, p_amount_e4 bigint,
  p_occurred_at timestamptz, p_external_id text, p_notes text default null,
  p_detected_currency text default null, p_category_hint uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_account_id uuid;
  v_currency text;
  v_category_id uuid;
  v_detected text := nullif(upper(trim(coalesce(p_detected_currency, ''))), '');
  v_paid bigint := -abs(p_amount_e4);
  v_amount bigint;
  v_original_amount bigint;
  v_original_currency text;
begin
  if not public.ops_check_own_rate_limit('capture_transaction', 20, 60) then
    raise exception 'capture rate limit exceeded';
  end if;

  insert into public.card_mappings (owner_id, card_identifier)
  values (v_owner, p_card_identifier)
  on conflict (owner_id, card_identifier) do nothing;

  -- `deleted_at is null` (20260901100000's fix A): an unmapped card must
  -- resolve to no account at all, landing the capture as an ordinary
  -- unresolved pending review, not silently back into the account it was
  -- unmapped from.
  select cm.account_id into v_account_id
  from public.card_mappings cm
  where cm.owner_id = v_owner and cm.card_identifier = p_card_identifier and cm.deleted_at is null;

  if v_account_id is not null then
    select a.currency into v_currency from public.accounts a where a.id = v_account_id;
  end if;

  -- A currency this app cannot price is the same as none detected. The
  -- client's detector is already restricted to the supported set; this is
  -- the server refusing to take its word for it.
  if v_detected is not null and not exists (select 1 from public.currencies c where c.code = v_detected) then
    v_detected := null;
  end if;

  v_amount := v_paid;

  if v_detected is not null and v_currency is not null and v_detected <> v_currency then
    -- The account is known, so the conversion can happen now and both
    -- figures go to review together. fx_rate_on(occurred_at), never
    -- today's rate: the purchase happened when it happened.
    v_original_amount := v_paid;
    v_original_currency := v_detected;
    v_amount := public.fx_convert(v_paid, v_detected, v_currency, p_occurred_at::date);

    if v_amount is null then
      -- No resolvable rate for that pair and date. There is no number that
      -- belongs in this account's currency, so the row does not claim one:
      -- it holds what was paid and waits. The trigger above has just asked
      -- for a backfill, so the rate usually exists by the time the user
      -- opens the review; if it still does not, the form shows `—` and the
      -- user types what their bank charged (money rule 5).
      v_amount := v_paid;
      v_account_id := null;
      v_currency := null;
    end if;
  elsif v_detected is not null and v_currency is null then
    -- The card is not mapped yet, so there is no account currency to
    -- compare against. Hold the pair; the review form converts once the
    -- user picks an account, which is also the moment a human first sees
    -- the number — the property money rule 6 turns on.
    v_original_amount := v_paid;
    v_original_currency := v_detected;
  end if;

  v_category_id := public.resolve_category_for_merchant(v_owner, p_merchant_normalized, 'expense', p_category_hint);

  insert into public.transactions (
    id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
    merchant_raw, merchant_normalized, notes, source, status, external_id, card_identifier,
    original_amount_e4, original_currency
  ) values (
    p_id, v_owner, v_owner, v_account_id, v_category_id, v_amount, v_currency, p_occurred_at,
    p_merchant_raw, p_merchant_normalized, p_notes, 'capture', 'pending', p_external_id, p_card_identifier,
    v_original_amount, v_original_currency
  );
end;
$$;


revoke all on function public.capture_transaction(
  uuid, text, text, text, bigint, timestamptz, text, text, text, uuid
) from public;
grant execute on function public.capture_transaction(
  uuid, text, text, text, bigint, timestamptz, text, text, text, uuid
) to authenticated;

-- ============================================================================
-- 4. review_capture_transaction and update_transaction — + p_title
-- ============================================================================

drop function public.review_capture_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text, bigint, text
);

create function public.review_capture_transaction(
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
         merchant_normalized
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  if v_current.source <> 'capture' or v_current.status <> 'pending' then
    raise exception 'transaction % is not a pending capture — use update_transaction', p_id;
  end if;

  if v_current.account_id is not null then
    if not public.can_write_account(v_current.account_id) then
      raise exception 'transaction not found or not accessible';
    end if;
  elsif v_current.owner_id <> v_owner then
    raise exception 'transaction not found or not accessible';
  end if;

  if not public.can_write_account(p_account_id)
     or exists (select 1 from public.accounts where id = p_account_id and deleted_at is not null) then
    raise exception 'account not found or not accessible';
  end if;

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
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);
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


revoke all on function public.review_capture_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text, bigint, text, text
) from public;
grant execute on function public.review_capture_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text, bigint, text, text
) to authenticated;

drop function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text, bigint, text
);

create function public.update_transaction(
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
  select id, version, account_id, transfer_group_id, deleted_at, owner_id, source, card_identifier
  into v_current
  from public.transactions
  where id = p_id;

  if v_current.id is null or v_current.deleted_at is not null then
    raise exception 'transaction not found or not accessible';
  end if;

  if v_current.transfer_group_id is not null then
    raise exception 'transaction % is a transfer leg — use update_transfer', p_id;
  end if;

  if v_current.account_id is not null then
    if not public.can_write_account(v_current.account_id) then
      raise exception 'transaction not found or not accessible';
    end if;
  elsif v_current.owner_id <> v_owner then
    raise exception 'transaction not found or not accessible';
  end if;

  if not public.can_write_account(p_account_id)
     or exists (select 1 from public.accounts where id = p_account_id and deleted_at is not null) then
    raise exception 'account not found or not accessible';
  end if;

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
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', p_id, v_owner, p_expected_version, v_current.version);

    return query select true, null::public.transactions;
    return;
  end if;

  if v_current.account_id is null and v_current.source = 'capture' and v_current.card_identifier is not null then
    perform public.link_card_to_account(v_owner, v_current.card_identifier, p_account_id);
  end if;

  return query select false, v_result;
end;
$$;


revoke all on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text, bigint, text, text
) from public;
grant execute on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text, bigint, text, text
) to authenticated;

-- ============================================================================
-- 5. create_transfer and update_transfer — + p_title, on both legs
-- ============================================================================

drop function public.create_transfer(uuid, uuid, bigint, bigint, timestamptz, uuid, uuid, text);

create function public.create_transfer(
  p_from_account_id uuid, p_to_account_id uuid, p_from_amount_e4 bigint, p_to_amount_e4 bigint default null,
  p_occurred_at timestamptz default now(), p_from_id uuid default null, p_to_id uuid default null,
  p_notes text default null, p_title text default null
)
returns setof transactions
language plpgsql
set search_path = ''
as $$
declare
  v_from_owner uuid;
  v_from_currency text;
  v_to_owner uuid;
  v_to_currency text;
  v_to_amount_e4 bigint;
  v_group uuid := gen_random_uuid();
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
      coalesce(p_from_id, gen_random_uuid()), v_from_owner, (select auth.uid()), p_from_account_id,
      -p_from_amount_e4, v_from_currency, p_occurred_at, v_group, 'manual', p_notes, v_title
    ),
    (
      coalesce(p_to_id, gen_random_uuid()), v_to_owner, (select auth.uid()), p_to_account_id,
      v_to_amount_e4, v_to_currency, p_occurred_at, v_group, 'manual', p_notes, v_title
    );

  return query select * from public.transactions where transfer_group_id = v_group;
end;
$$;


revoke all on function public.create_transfer(uuid, uuid, bigint, bigint, timestamptz, uuid, uuid, text, text)
  from public;
grant execute on function public.create_transfer(uuid, uuid, bigint, bigint, timestamptz, uuid, uuid, text, text)
  to authenticated;

drop function public.update_transfer(uuid, integer, integer, bigint, bigint, timestamptz, text);

create function public.update_transfer(
  p_transfer_group_id uuid, p_from_expected_version integer, p_to_expected_version integer,
  p_from_amount_e4 bigint, p_to_amount_e4 bigint, p_occurred_at timestamptz, p_notes text default null,
  p_title text default null
)
returns table(conflict boolean, transaction transactions)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner uuid := (select auth.uid());
  v_from record;
  v_to record;
  v_conflict boolean := false;
  v_title text := nullif(btrim(p_title), '');
begin
  if p_from_amount_e4 is null or p_from_amount_e4 <= 0 or p_to_amount_e4 is null or p_to_amount_e4 <= 0 then
    raise exception 'from_amount and to_amount must be positive magnitudes';
  end if;

  select id, version, account_id into v_from
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 < 0;

  select id, version, account_id into v_to
  from public.transactions
  where transfer_group_id = p_transfer_group_id and deleted_at is null and amount_e4 > 0;

  if v_from.id is null or v_to.id is null
     or not public.can_write_account(v_from.account_id)
     or not public.can_write_account(v_to.account_id) then
    raise exception 'transfer % not found or not accessible', p_transfer_group_id;
  end if;

  if v_from.version <> p_from_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_from.id, v_owner, p_from_expected_version, v_from.version);
    v_conflict := true;
  end if;

  if v_to.version <> p_to_expected_version then
    insert into public.sync_conflicts (table_name, row_id, owner_id, client_version, server_version)
    values ('transactions', v_to.id, v_owner, p_to_expected_version, v_to.version);
    v_conflict := true;
  end if;

  if v_conflict then
    return query select true, null::public.transactions;
    return;
  end if;

  update public.transactions set amount_e4 = -p_from_amount_e4, occurred_at = p_occurred_at, notes = p_notes,
    title = v_title
  where id = v_from.id and version = p_from_expected_version;

  update public.transactions set amount_e4 = p_to_amount_e4, occurred_at = p_occurred_at, notes = p_notes,
    title = v_title
  where id = v_to.id and version = p_to_expected_version;

  return query select false, t from public.transactions t where t.transfer_group_id = p_transfer_group_id;
end;
$$;


revoke all on function public.update_transfer(uuid, integer, integer, bigint, bigint, timestamptz, text, text)
  from public;
grant execute on function public.update_transfer(uuid, integer, integer, bigint, bigint, timestamptz, text, text)
  to authenticated;

-- ============================================================================
-- 6. materialize_recurring — every occurrence inherits its rule's title,
--    on both legs of a transfer (like the note, unlike the tags: nothing
--    sums a title).
--
--    Same signature, so `create or replace` keeps its grants.
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
          notes, title, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id, v_rule.category_id,
          v_rule.amount_e4, v_currency, v_at,
          v_rule.notes, v_rule.title, 'recurring', v_rule.id::text || '|' || v_occurrence::text, v_rule.id
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
          notes, title, transfer_group_id, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.account_id,
          v_rule.amount_e4, v_currency, v_at,
          v_rule.notes, v_rule.title, v_group, 'recurring', v_rule.id::text || '|' || v_occurrence::text || '|from', v_rule.id
        )
        on conflict (owner_id, source, external_id) where external_id is not null do nothing
        returning id into v_new_id;

        if v_new_id is not null then
          v_inserted := v_inserted + 1;
        end if;

        insert into public.transactions (
          id, owner_id, created_by, account_id, amount_e4, currency, occurred_at,
          notes, title, transfer_group_id, source, external_id, recurring_rule_id
        ) values (
          gen_random_uuid(), v_rule.owner_id, v_rule.owner_id, v_rule.to_account_id,
          -v_rule.amount_e4, v_to_currency, v_at,
          v_rule.notes, v_rule.title, v_group, 'recurring', v_rule.id::text || '|' || v_occurrence::text || '|to', v_rule.id
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


-- ============================================================================
-- 7. fork_one_account — both copies keep the title
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
    merchant_raw, merchant_normalized, title, source, status
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
    t.amount_e4, t.currency, t.occurred_at, t.merchant_raw, t.merchant_normalized, t.title,
    case when t.transfer_group_id is not null then 'adjustment'::public.transaction_source else t.source end,
    t.status
  from public.transactions t
  cross join lateral (values (p_member_a, v_new_for_a), (p_member_b, v_new_for_b)) as fork (fork_owner, fork_account_id)
  where t.account_id = p_old_account_id and t.deleted_at is null;

  insert into public.recurring_rules (
    created_by, account_id, category_id, to_account_id, amount_e4, currency, title, frequency, next_due_at, active
  )
  select rr.created_by, fork.fork_account_id,
         case when rr.category_id is null then null else public.fork_category_id(fork.fork_owner, rr.category_id) end,
         rr.to_account_id,
         rr.amount_e4, rr.currency, rr.title, rr.frequency, rr.next_due_at, rr.active
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



-- ============================================================================
-- 8. transactions_with_details — + title, appended at the end, the only
--    place CREATE OR REPLACE VIEW allows a new column.
-- ============================================================================

create or replace view transactions_with_details
with (security_invoker = true) as
select
  t.id as transaction_id,
  t.account_id,
  a.name as account_name,
  t.category_id,
  c.name as category_name,
  t.amount_e4,
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
    when t.amount_e4 < 0 then 'expense'
    else 'income'
  end as kind,
  t.created_by,
  t.created_at,
  t.version,
  p.base_currency,
  bc.minor_unit as base_minor_unit,
  fx_convert(t.amount_e4, t.currency, p.base_currency, t.occurred_at::date) as amount_base_e4,
  (fx_convert(t.amount_e4, t.currency, p.base_currency, t.occurred_at::date) is null) as has_missing_rate,
  t.recurring_rule_id,
  t.notes,
  t.original_amount_e4,
  t.original_currency,
  ocur.minor_unit as original_minor_unit,
  t.title
from transactions t
left join accounts a on a.id = t.account_id
left join categories c on c.id = t.category_id
left join currencies cur on cur.code = t.currency
left join profiles p on p.id = (select auth.uid())
left join currencies bc on bc.code = p.base_currency
left join currencies ocur on ocur.code = t.original_currency
where t.deleted_at is null;

