-- Erasure left the card token on every captured transaction.
--
-- `erase_own_account()` nulls `merchant_raw` and `merchant_normalized` on
-- the caller's transactions, and (since 20260924100000) scrubs
-- `card_mappings.card_identifier`. It never touched
-- `transactions.card_identifier` — the same token, on the rows that
-- actually record the purchases. Erasure destroyed the index and left the
-- thing it indexed.
--
-- Invisible through the one live caller: `delete_own_account()` deletes
-- every transaction a few statements later, so nothing survives either way.
-- It matters because `erase_own_account()` is `grant execute ... to
-- authenticated` in its own right — a function whose entire purpose is
-- "destroy what identifies me" should not be judged by what happens to
-- follow it, and a user who calls it is entitled to have it mean what it
-- says.
--
-- `card_identifier` is nullable, carries no CHECK, and `transactions_insert`
-- already requires it to be null for every manual write — only capture sets
-- it. So null is the honest scrub here, and the same treatment the two
-- merchant columns beside it already get. Unlike `card_mappings` there is no
-- unique constraint to work around: that is why this one can be null and
-- that one needed 'erased:<row id>'.
--
-- **Consequence, deliberately accepted.** `needs_review`'s `ambiguous_card`
-- arm hides an unmapped mapping while a pending capture for the same
-- `card_identifier` exists, correlating the two tables on that column.
-- After an erase the two sides no longer match — mappings hold
-- 'erased:<id>', transactions hold null — so a card that was suppressed can
-- surface as an extra "Unmapped card" row. That is the correct trade: the
-- alternative is keeping a raw card token on disk so a review list stays
-- tidy. Nothing here is wrong afterwards, only noisier, and only for a
-- standalone erase.
--
-- `transactions_stamp_sync_seq` fires `BEFORE INSERT OR UPDATE`, so this
-- scrub propagates to the user's other devices through the ordinary
-- incremental pull. No `sync_epoch` bump is needed or wanted — see the note
-- on that at the bottom of this file.
--
-- Verbatim `pg_get_functiondef` copy again, with exactly one change: the
-- transactions UPDATE.
-- ============================================================================

create or replace function erase_own_account()
returns void language plpgsql security definer set search_path = ''
as $$
declare
  v_household_id uuid := public.my_household_id();
  v_me uuid := (select auth.uid());
  v_other uuid;
  v_event_id uuid;
begin
  if v_household_id is not null then
    select user_id into v_other from public.household_members
    where household_id = v_household_id and user_id <> v_me and deleted_at is null;

    if v_other is not null then
      perform public.fork_household_accounts(v_household_id, v_me, v_other);
    end if;

    update public.household_members set deleted_at = now()
    where household_id = v_household_id and user_id = v_me and deleted_at is null;

    perform public.unlink_shared_categories(v_me);

    -- Stays inside this branch on purpose. The epoch exists to force a
    -- device whose sync *domain* changed to wipe and re-pull from zero
    -- (app-architecture.md LH2/LH3, and 20260827100000's S-06 note):
    -- leaving a household moves the caller out of the household's ticket
    -- sequence and back into their own, so every cached cursor is
    -- denominated in a counter that no longer applies. A caller with no
    -- household changes no domain, and the scrubs below carry themselves
    -- through the ordinary pull via each table's stamp_sync_seq trigger.
    -- Bumping unconditionally would hand every solo erase a full
    -- wipe-and-re-pull to deliver two UPDATEs that were already on their
    -- way. Checked, and left exactly as it was.
    update public.profiles set sync_epoch = sync_epoch + 1 where id = v_me;

    insert into public.household_events (household_id, actor_id, kind)
    values (v_household_id, v_me, 'member_erased')
    returning id into v_event_id;

    perform public.notify_household(v_event_id);
  end if;

  -- The card token belongs here as much as the merchant does. See header.
  update public.transactions
  set merchant_raw = null, merchant_normalized = null, card_identifier = null
  where owner_id = v_me
    and (merchant_raw is not null or merchant_normalized is not null or card_identifier is not null);

  -- One scrubbed value per row, unique by construction. See 20260924100000.
  update public.card_mappings set card_identifier = 'erased:' || id::text
  where owner_id = v_me;
end;
$$;

revoke all on function erase_own_account() from public;
grant execute on function erase_own_account() to authenticated;

comment on function erase_own_account() is
  'Forks the household, departs it, and scrubs the caller''s free text: '
  'merchant_raw, merchant_normalized and card_identifier on transactions, '
  'and card_identifier on card_mappings (to ''erased:<row id>'', never a '
  'shared literal — that column is unique per owner).';
