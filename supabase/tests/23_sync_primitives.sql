-- L2: sync primitives — tickets, sync_seq stamping, pull_changes, epoch
-- bumps, and fork-on-unshare re-stamping (keepo-local-first-plan.md).
--
-- The single-integer-cursor ordering GUARANTEE (a lower ticket committed
-- first) is fundamentally a cross-transaction property — next_ticket()'s
-- `for update` row lock only means anything when two sessions actually
-- overlap. A single pgTAP test file is one transaction, so it cannot
-- exercise that guarantee at all; see scripts/two_session_ticket_order.sh
-- for the real (two concurrent psql sessions) version of that assertion.
-- This file covers everything pgTAP CAN see: stamping, domain resolution,
-- pull_changes' RLS-for-free filtering, LH3 re-stamp on share, and the
-- epoch bumps on gain/loss of access.
--
-- A cursor is only meaningful WITHIN one domain's ticket space — a value
-- from before a domain change (solo <-> household) is denominated in a
-- different counter entirely, which is exactly why a domain change bumps
-- sync_epoch and forces a fresh pull from 0 rather than trusting the old
-- cursor. So every scenario below that compares a "before" cursor to an
-- "after" pull keeps both sides in the SAME, already-stable domain —
-- the household is formed first, before any of the accounts under test.

\ir _helpers.psql

begin;

select plan(23);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 1. Before any household exists, B genuinely cannot see A's account
-- (plain cross-domain RLS, not yet about sync_seq at all).
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('e0000000-0000-0000-0000-00000000e000', auth.uid(), auth.uid(), 'ledger', 'checking', 'Presolo', 'EUR', 0);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (
    select count(*) from jsonb_array_elements(
      (select payload -> 'accounts' from pull_changes(0))
    ) row where row ->> 'id' = 'e0000000-0000-0000-0000-00000000e000'
  ),
  0::bigint,
  'pull_changes never returns a private account belonging to another user (RLS, not an explicit filter)'
);

-- ----------------------------------------------------------------------------
-- Form the household FIRST, so every scenario below stays in one stable
-- domain — a cursor compared across a domain change is meaningless (that's
-- exactly what sync_epoch exists to signal), so this test proves LH3 within
-- one domain rather than conflating it with a domain change.
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
insert into household_members (household_id, user_id)
values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111');
insert into household_members (household_id, user_id)
select household_id, '22222222-2222-2222-2222-222222222222'
from household_members where user_id = '11111111-1111-1111-1111-111111111111';

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 2. A fresh insert is stamped with a positive sync_seq, not the column
-- default of 0.
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('e0000000-0000-0000-0000-00000000e001', auth.uid(), auth.uid(), 'ledger', 'checking', 'Sync A1', 'EUR', 0);

select ok(
  (select sync_seq from accounts where id = 'e0000000-0000-0000-0000-00000000e001') > 0,
  'a freshly inserted account is stamped with a positive sync_seq'
);

-- 3. Two writes to the SAME domain get strictly increasing tickets.
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('e0000000-0000-0000-0000-00000000e002', auth.uid(), auth.uid(), 'ledger', 'cash', 'Sync A2', 'EUR', 0);

select ok(
  (select sync_seq from accounts where id = 'e0000000-0000-0000-0000-00000000e002')
    > (select sync_seq from accounts where id = 'e0000000-0000-0000-0000-00000000e001'),
  'sequential writes to one domain get strictly increasing tickets'
);

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
select 'f0000000-0000-0000-0000-00000000f001', auth.uid(), auth.uid(), 'e0000000-0000-0000-0000-00000000e001',
       id, -50000, 'EUR', now()
from categories where owner_id = auth.uid() and kind = 'expense' and is_default;

-- 4. pull_changes(0) returns A's own accounts, and a positive next_cursor.
select ok(
  (select jsonb_array_length(payload -> 'accounts') from pull_changes(0)) >= 2,
  'pull_changes(0) returns every account sync_seq > 0 for the caller'
);

select ok(
  (select next_cursor from pull_changes(0)) >= (select sync_seq from accounts where id = 'e0000000-0000-0000-0000-00000000e002'),
  'pull_changes'' next_cursor advances to at least the highest sync_seq returned'
);

-- 5. Pulling again from that next_cursor returns nothing new — proves the
-- cursor threshold is exclusive and idempotent.
select is(
  (select jsonb_array_length(payload -> 'accounts') from pull_changes((select next_cursor from pull_changes(0)))),
  0,
  'pulling from the just-advanced cursor returns zero further accounts'
);

-- ----------------------------------------------------------------------------
-- LH3: sharing re-stamps rows that predate the share, so a normal pull
-- from a cursor taken BEFORE the share still delivers them afterward.
-- ----------------------------------------------------------------------------

-- B's cursor, captured once she's already in the household but before A
-- has shared anything — the account and its transaction already exist at
-- this point, just not visible to B yet.
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

create temp table b_cursor_before as select next_cursor from pull_changes(0);

-- 6. Before sharing, B's pull (from her own cursor) sees nothing of A's
-- account or its transaction — still private.
select is(
  (
    select count(*) from jsonb_array_elements(
      (select payload -> 'accounts' from pull_changes((select next_cursor from b_cursor_before)))
    ) row where row ->> 'id' = 'e0000000-0000-0000-0000-00000000e001'
  ),
  0::bigint,
  'before sharing, B''s pull still does not see A''s private account'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select share_account('e0000000-0000-0000-0000-00000000e001');

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- 7. After sharing, B's pull from the SAME pre-share cursor now delivers
-- both the account and its pre-existing transaction — the whole point of
-- the LH3 re-stamp.
select is(
  (
    select count(*) from jsonb_array_elements(
      (select payload -> 'accounts' from pull_changes((select next_cursor from b_cursor_before)))
    ) row where row ->> 'id' = 'e0000000-0000-0000-0000-00000000e001'
  ),
  1::bigint,
  'LH3: after share_account, a pull from B''s pre-share cursor now delivers the account'
);

select is(
  (
    select count(*) from jsonb_array_elements(
      (select payload -> 'transactions' from pull_changes((select next_cursor from b_cursor_before)))
    ) row where row ->> 'id' = 'f0000000-0000-0000-0000-00000000f001'
  ),
  1::bigint,
  'LH3: the account''s pre-existing transaction is re-stamped and delivered too'
);

-- 8. Sharing doesn't touch A's own version — restamp_account_for_sync's
-- keepo.restamp_only escape hatch actually worked, not just the ticket.
select is(
  (select version from accounts where id = 'e0000000-0000-0000-0000-00000000e001'),
  1,
  'sharing an account does not bump its version (only sync_seq changes)'
);

-- 9. Sharing an account does not bump the sharer's own sync_epoch — she
-- never lost anything. Read as postgres: profiles_select is id = auth.uid(),
-- and the active role here is still B's, who can't see A's own row.
reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select sync_epoch from profiles where id = '11111111-1111-1111-1111-111111111111'),
  1::bigint,
  'share_account does not bump the sharer''s own sync_epoch'
);

-- ----------------------------------------------------------------------------
-- LH4/LH12: unshare with a fork bumps only the OTHER member's epoch.
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select unshare_account('e0000000-0000-0000-0000-00000000e001');

-- 10-12. Read the effects as postgres — RLS would otherwise hide each
-- identity's row/account from the other (A is still the active role here).
reset role;
select set_config('request.jwt.claim.sub', '', true);

-- 10. B (who just lost the shared account) gets her epoch bumped.
select is(
  (select sync_epoch from profiles where id = '22222222-2222-2222-2222-222222222222'),
  2::bigint,
  'unshare_account bumps the losing (other) member''s sync_epoch'
);

-- 11. A (the sharer, unaffected) does not.
select is(
  (select sync_epoch from profiles where id = '11111111-1111-1111-1111-111111111111'),
  1::bigint,
  'unshare_account does not bump the sharer''s own sync_epoch'
);

-- 12. B got a full independent fork of the account, not just a lost
-- reference.
select is(
  (
    select count(*) from accounts
    where owner_id = '22222222-2222-2222-2222-222222222222' and name = 'Sync A1' and archived_at is null
  ),
  1::bigint,
  'unshare_account with another member present forks a full replica for the other member'
);

-- 13. The original is archived, not deleted — history is never destroyed.
select is(
  (select archived_at is not null from accounts where id = 'e0000000-0000-0000-0000-00000000e001'),
  true,
  'the original shared account is archived after an unshare-with-fork, never deleted'
);

-- 14. household_accounts holds a tombstone (soft-deleted), not a hard
-- delete — the remaining relationship state is still visible to a
-- subsequent pull as a removal signal, per LH2/LH4's design.
select is(
  (select deleted_at is not null from household_accounts where account_id = 'e0000000-0000-0000-0000-00000000e001'),
  true,
  'unshare leaves household_accounts as a tombstone (deleted_at set), not a hard delete'
);

-- ----------------------------------------------------------------------------
-- Domain-change epoch bumps: leaving/accepting changes what my_household_id
-- resolves to, so the acting user's own cursor is meaningless afterward.
-- ----------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select leave_household();

-- 15. Leaving bumps the LEAVER's own epoch (not the other member's).
select is(
  (select sync_epoch from profiles where id = '11111111-1111-1111-1111-111111111111'),
  2::bigint,
  'leave_household bumps the leaving member''s own sync_epoch (domain change)'
);

-- 16. A former member can rejoin the SAME household without the 2-member
-- cap or the household_members PK blocking it — enforce_household_member_
-- cap must ignore a tombstoned row, and accept_invite must reactivate one
-- rather than colliding on it.
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

create temp table rejoin_token as select create_invite() as token;

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select lives_ok(
  $$ select accept_invite((select token from rejoin_token)) $$,
  'a former member can rejoin the same household — the tombstoned row is reactivated, not collided with'
);

-- 17. Accepting bumps the ACCEPTOR's own epoch too (domain change the
-- other direction: solo -> household).
select is(
  (select sync_epoch from profiles where id = '11111111-1111-1111-1111-111111111111'),
  3::bigint,
  'accept_invite bumps the accepting member''s own sync_epoch (domain change)'
);

-- ----------------------------------------------------------------------------
-- Global domain: currencies/fx_rates share one fixed domain, independent of
-- any user's own domain.
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);

insert into currencies (code, minor_unit) values ('ZZZ', 2);

select ok(
  (select sync_seq from currencies where code = 'ZZZ') > 0,
  'a global reference row (currencies) is stamped via the shared global domain'
);

select ok(
  (select next_ticket - 1 from sync_tickets where domain_id = sync_global_domain())
    >= (select sync_seq from currencies where code = 'ZZZ'),
  'the global domain''s own ticket counter has advanced past the row it just stamped'
);

-- ----------------------------------------------------------------------------
-- L5 fix: pull_changes must not let to_jsonb(row) turn a `numeric` column
-- into a JSON number — the client would decode it through a binary
-- floating-point type before re-encoding it as the local TEXT decimal
-- string, silently reintroducing the imprecision L1 eliminated.
-- rate_to_eur/withdrawal_rate/real_return_rate are the only three numeric
-- columns left in the syncable set.
-- ----------------------------------------------------------------------------

insert into fx_rates (currency, rate_date, rate_to_eur, source)
values ('ZZZ', current_date, 0.9000, 'ecb')
on conflict (currency, rate_date) do update set rate_to_eur = excluded.rate_to_eur;

select is(
  (
    select jsonb_typeof(row -> 'rate_to_eur') from jsonb_array_elements(
      (select payload -> 'fx_rates' from pull_changes(0, 0))
    ) row where row ->> 'currency' = 'ZZZ'
  ),
  'string',
  'pull_changes renders fx_rates.rate_to_eur as a JSON string, never a JSON number'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

update fi_settings set withdrawal_rate = 0.0425 where owner_id = auth.uid();

select is(
  (
    select row -> 'withdrawal_rate' from jsonb_array_elements(
      (select payload -> 'fi_settings' from pull_changes(0, 0))
    ) row where row ->> 'owner_id' = '11111111-1111-1111-1111-111111111111'
  ),
  to_jsonb('0.0425'::text),
  'pull_changes renders fi_settings.withdrawal_rate as the exact decimal string, not a rounded/re-encoded JSON number'
);

select * from finish();
rollback;
