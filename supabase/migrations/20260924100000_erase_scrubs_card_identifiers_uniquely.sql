-- Deleting your account was impossible for anyone with two mapped cards.
--
-- Found in the hosted `delete-account` function's logs, from a real attempt:
--
--   delete-account: delete_own_account failed duplicate key value violates
--   unique constraint "card_mappings_owner_id_card_identifier_key"
--
-- `erase_own_account()` ends by scrubbing the card identifiers, which are
-- the one piece of free text `card_mappings` carries:
--
--   update public.card_mappings set card_identifier = 'erased'
--   where owner_id = v_me;
--
-- `card_mappings` is `unique (owner_id, card_identifier)` (20260807150000).
-- A single literal therefore only survives for a user with exactly **one**
-- mapped card. The second card collides with the first, the statement
-- aborts, and because `delete_own_account()` calls `erase_own_account()` as
-- its first act, the entire deletion transaction rolls back: no rows
-- destroyed, no identity deleted, and — until the client fix that landed
-- alongside this — no message on screen either. The user taps Delete
-- Account and nothing whatsoever happens, forever.
--
-- The bug selects precisely for engaged users. One card is the new-signup
-- case; two is what you have after actually using capture for a while. So
-- the people structurally unable to delete their account were the ones with
-- the most data to delete, which is the exact population App Store Review
-- 5.1.1(v) and GDPR Art. 17 exist to protect.
--
-- The fix is to scrub to a value that is unique by construction. The row's
-- own primary key already is one, and it identifies nothing about the card
-- — it is a random uuid that the erasure keeps rather than a fact about the
-- person. The statement stays idempotent: a second run rewrites each row to
-- the value it already holds.
--
-- Nothing anywhere reads the literal `'erased'` — checked across the
-- migrations, the Edge Functions and the client before changing it. The
-- only other user of that literal scrubbed `csv_import_batches.filename`,
-- on a table 20260909100000 dropped.
--
-- `create or replace` restates the whole function, so this is a **verbatim**
-- copy of the definition as `pg_get_functiondef` returns it today, with two
-- changes and no others:
--
--   1. The scrub, as described above.
--   2. Indentation. The live text indents `unlink_shared_categories` and the
--      `sync_epoch` bump as though they sat outside the `if v_household_id
--      is not null` block. They do not, and never did — `end if` comes after
--      `notify_household`. Only the whitespace changes here; both statements
--      stay exactly where they have always run. (That the epoch bump is
--      inside the household branch means a solo user's erase does not bump
--      it. Harmless in the one live caller — `delete_own_account` deletes
--      the profile outright a few statements later — and deliberately left
--      alone rather than fixed in passing under a migration about something
--      else.)
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

    update public.profiles set sync_epoch = sync_epoch + 1 where id = v_me;

    insert into public.household_events (household_id, actor_id, kind)
    values (v_household_id, v_me, 'member_erased')
    returning id into v_event_id;

    perform public.notify_household(v_event_id);
  end if;

  update public.transactions set merchant_raw = null, merchant_normalized = null
  where owner_id = v_me and (merchant_raw is not null or merchant_normalized is not null);

  -- One scrubbed value per row, unique by construction. See the header.
  update public.card_mappings set card_identifier = 'erased:' || id::text
  where owner_id = v_me;
end;
$$;

revoke all on function erase_own_account() from public;
grant execute on function erase_own_account() to authenticated;

comment on function erase_own_account() is
  'Forks the household, departs it, and scrubs the caller''s free text. '
  'Card identifiers are scrubbed to ''erased:<row id>'', never a shared '
  'literal — (owner_id, card_identifier) is unique, so a single literal '
  'made erasure impossible for anyone with two mapped cards.';
