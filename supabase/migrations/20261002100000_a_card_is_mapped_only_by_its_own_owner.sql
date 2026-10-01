-- A card is mapped only by its own owner.
--
-- Found by the security audit of 2026-09-21, and confirmed with a working
-- exploit before this was written.
--
-- `link_card_to_account` is the primitive underneath card mapping, and it
-- takes the owner as a *parameter* — `p_owner uuid` — because its callers
-- are server-side code acting on somebody's behalf: `map_card` passes
-- `auth.uid()`, and the capture path passes the owner it already resolved.
-- The only check in the function is that the account belongs to `p_owner`.
-- That is the right check for a trusted caller and no check at all for an
-- untrusted one, because an untrusted caller simply names a different owner.
--
-- It was granted `EXECUTE` to `authenticated` alongside `map_card`, so any
-- signed-in user could name any other user as `p_owner` and rewrite their
-- `card_mappings` row. Demonstrated end to end: an attacker for whom
-- `can_read_account` returned false on both accounts moved the victim's
-- card from their Checking account to their Savings account.
--
-- The damage is not abstract for this app in particular. A card mapping is
-- what decides where an Apple Pay charge lands, so a rewritten mapping
-- silently misfiles every future purchase on that card — and because a
-- balance is a running sum, it keeps being wrong until somebody notices and
-- unpicks it by hand.
--
-- **Nothing calls this as `authenticated`.** The Swift client reaches card
-- mapping through `map_card` (the `auth.uid()`-scoped wrapper) and the one
-- mention of `link_card_to_account` in the app is a code comment. So this is
-- a revoke and nothing else: no signature change, no caller changes.
--
-- `map_card`, `capture_transaction`, `review_capture_transaction` and
-- `confirm_capture_transaction` are unaffected. All four are SECURITY
-- DEFINER owned by `postgres`, so the effective user inside them is
-- `postgres`, which keeps its own EXECUTE.

revoke execute on function
  public.link_card_to_account(uuid, text, uuid, card_mapping_source)
  from authenticated;

-- `service_role` keeps it: the capture path runs as service_role and has
-- already established whose card it is holding.
