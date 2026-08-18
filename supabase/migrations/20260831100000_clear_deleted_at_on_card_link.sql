-- Item 1 (2026-08 UX-fix batch): re-mapping a card that was ever unmapped
-- before is invisible forever. `link_card_to_account` is the one chokepoint
-- every "route this card to an account" write goes through (map_card, the
-- Needs Review auto-link in review_capture_transaction/update_transaction),
-- and its upsert set `account_id`/`updated_at` but never cleared
-- `deleted_at` on the conflict branch — so a card that was ever unmapped
-- (soft-deleted) stayed soft-deleted after being re-mapped. Every read
-- filters `deleted_at is null` (MappedCardsView's list, the ambiguous_card
-- branch of needs_review, capture's own account-resolution lookup), so the
-- write silently "succeeded" into a row nothing could ever see again.

create or replace function public.link_card_to_account(p_owner uuid, p_card_identifier text, p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.accounts
    where id = p_account_id and owner_id = p_owner and kind = 'ledger'
      and deleted_at is null and archived_at is null
  ) then
    raise exception 'account not found, not accessible, archived, or not a spendable (ledger) account';
  end if;

  insert into public.card_mappings (owner_id, card_identifier, account_id)
  values (p_owner, p_card_identifier, p_account_id)
  on conflict (owner_id, card_identifier)
  do update set account_id = excluded.account_id, deleted_at = null, updated_at = now();
end;
$$;
