-- Found chasing a real bug: dismissing an unmapped-card Needs Review item
-- (unmap_card) failed on the hosted backend with "42501: permission denied
-- for function unmap_card" even though 20260822100000 already grants
-- execute on it — `supabase migration list --linked` shows that migration
-- recorded as fully applied, so something about that specific statement
-- didn't take even though the migration as a whole did. Re-asserting is a
-- safe no-op wherever the grant already exists; this is the fix regardless
-- of which exact statement silently didn't land.

grant execute on function public.rename_card_mapping(uuid, text) to authenticated;
grant execute on function public.unmap_card(uuid) to authenticated;
grant execute on function public.map_card(text, uuid) to authenticated;
grant execute on function public.capture_transaction(
  uuid, text, text, text, bigint, timestamptz, text, text
) to authenticated;
grant execute on function public.update_transaction(
  uuid, integer, uuid, uuid, bigint, text, timestamptz, text, text
) to authenticated;
grant execute on function public.confirm_capture_transaction(uuid, int) to authenticated;
grant execute on function public.delete_transaction(uuid, integer) to authenticated;
