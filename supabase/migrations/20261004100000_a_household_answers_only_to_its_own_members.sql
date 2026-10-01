-- A household answers only to its own members.
--
-- Finding 7 of the security audit of 2026-09-21. Two functions were reachable
-- by `authenticated` that answer questions the caller has no standing to ask.
-- Neither is called from the client; both were collateral from being granted
-- alongside the RPCs they support.
--
-- ## household_owner_id(uuid)
--
-- SECURITY DEFINER, so it sees every household, and it took an *arbitrary*
-- household id with no membership check. An outsider who came by a household
-- id got back that household's owner's user uuid — demonstrated during the
-- audit by a user in no household at all.
--
-- On its own that is a small leak: household ids are v4 and a bare user uuid
-- is not a credential. It mattered because it was the first link of a chain —
-- the other end of which was `link_card_to_account` (20261002100000), which
-- would write into whatever owner you could name. That end is closed now;
-- this closes the other, because a leak whose severity depends on no other
-- bug existing is not a leak anyone should have to keep re-assessing.
--
-- Kept callable rather than revoked, because the self-scoped question — "who
-- owns *my* household?" — is legitimate and asked in three places
-- (`apply_category_merges`, `unmerge_category_group`, `delete_tag_retagging`,
-- each gating an owner-only action) plus `household_member_profile`. All four
-- pass `my_household_id()`, so all four are unaffected.
--
-- ## unregistered_identity_columns()
--
-- The schema guard behind 20260911100000: it walks the catalog and names any
-- identity-bearing column that account deletion does not yet know about. That
-- is an ops and CI question, and the answer is a list of this app's table and
-- column names — of no use to a client and of some use to somebody mapping
-- the schema. `service_role` keeps it; the tests that assert on it already
-- run as `postgres`.

-- ---------------------------------------------------------------------------
-- 1. Your own household, or nothing.
-- ---------------------------------------------------------------------------

create or replace function public.household_owner_id(p_household_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.user_id
  from public.household_members m
  where m.household_id = p_household_id
    and m.deleted_at is null
    -- Added 20261004100000. The null-uid arm follows the same convention as
    -- `refresh_net_worth_daily`: a caller with no JWT is the cron or an edge
    -- function holding the service key — trusted server-side code, not a
    -- client, and the one case where asking about an arbitrary household is
    -- the point rather than the problem.
    and (
      (select auth.uid()) is null
      or p_household_id = public.my_household_id()
    )
  order by m.joined_at, m.user_id
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 2. The schema guard is not a client-facing question.
-- ---------------------------------------------------------------------------

revoke execute on function public.unregistered_identity_columns() from authenticated;
