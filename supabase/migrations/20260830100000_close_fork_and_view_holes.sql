-- Wave 1 of the Supabase Advisor remediation (see keepo-security-remediation-plan.md).
-- Two independent one-line fixes, shipped together because both are
-- zero-risk removals of access nothing legitimate depends on.
--
-- 1. accounts_with_balances lost `security_invoker = true` when
--    20260819100000 had to DROP + CREATE it (CREATE OR REPLACE VIEW cannot
--    remove a column from the middle of the list, which dropping
--    counts_toward_fi required). Every other view in this schema carries
--    the clause; this one is the sole regression. Confirmed locally this
--    is not currently exploitable — account_balances/account_balances_base
--    are themselves security_invoker, so the join already narrows to the
--    caller's own rows — but that's an accident of the join list, not a
--    property of this view's own grant, and one future edit (a LEFT JOIN,
--    or reading accounts directly) turns it into a full-table leak with no
--    visible change in the app. Column list and grant are byte-identical
--    to the current definition; only the missing clause is restored.
create or replace view public.accounts_with_balances
with (security_invoker = true) as
select
  a.id as account_id, a.name, a.kind, a.subtype, a.currency, c.minor_unit,
  a.include_in_total, a.icon, a.color, a.archived_at,
  ab.balance_e4, abb.base_currency, bc.minor_unit as base_minor_unit,
  abb.balance_base_e4, abb.has_missing_rate, a.version,
  exists (select 1 from public.household_accounts ha where ha.account_id = a.id) as is_shared
from public.accounts a
  join public.account_balances ab on ab.account_id = a.id
  join public.currencies c on c.code = a.currency
  join public.account_balances_base abb on abb.account_id = a.id
  left join public.currencies bc on bc.code = abb.base_currency;

grant select on public.accounts_with_balances to authenticated, service_role;

-- 2. fork_one_account was written as an internal helper for
--    leave_household/unshare_account (both SECURITY DEFINER, both already
--    verify the caller before calling this) and carries no auth check of
--    its own — correct only as long as nothing else can reach it. Every
--    function in `public` is auto-published as a PostgREST RPC, and
--    Postgres grants EXECUTE to PUBLIC by default unless explicitly
--    revoked, which this function never was. Confirmed locally: calling it
--    as `anon`, with no session at all, against an arbitrary account id
--    successfully forks that account into attacker-chosen owners and
--    archives the original. Revoking here is the immediate stop; the
--    ownership check that should have been in the function body from the
--    start lands in Wave 2 as defence in depth.
revoke all on function public.fork_one_account(uuid, uuid, uuid) from public, anon, authenticated;
