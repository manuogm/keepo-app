-- Households: access model & viewer-scoped money (migration
-- 20260806090000_households.sql). Fixture A = 11111111-... (base EUR),
-- fixture B = 22222222-... (base USD) — deliberately different bases so a
-- viewer-scoped-conversion regression can't hide behind both fixtures
-- sharing one currency. The running app is single-member-household until
-- Phase 19's accept_invite exists, so "B joins A's household" is simulated
-- here by inserting the second household_members row as postgres —
-- exactly the precedent this suite exists to establish (see this
-- migration's header comment and keepo-v1-master-plan.md, Phase 7).

\ir _helpers.psql

begin;
select plan(26);

-- ----------------------------------------------------------------------------
-- Setup: A creates a household and two accounts (one to share, one to keep
-- private). B, not yet a member, gets one private account of her own.
-- ----------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

-- 1. Calling create_household() a second time raises — one household per user.
select throws_like(
  $$ select create_household() $$,
  '%already belong to a household%',
  'create_household raises if the caller already belongs to one'
);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-00000000a001', auth.uid(), auth.uid(), 'regular', 'A Shared', 'EUR', 10000000);
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a0000000-0000-0000-0000-00000000a002', auth.uid(), auth.uid(), 'regular', 'A Private', 'EUR', 5000000);
insert into categories (id, owner_id, kind, name)
values ('c0000000-0000-0000-0000-00000000a001', auth.uid(), 'expense', 'Test Expense');

select share_account('a0000000-0000-0000-0000-00000000a001');

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('b0000000-0000-0000-0000-00000000b001', auth.uid(), auth.uid(), 'regular', 'B Private', 'USD', 20000000);

-- 2. Before B joins any household, A's shared account is invisible to her —
-- "shared" means shared into a household B actually belongs to, not a
-- blanket exemption from RLS.
select is(
  (select count(*) from accounts where id = 'a0000000-0000-0000-0000-00000000a001'),
  0::bigint,
  'a shared account is invisible to a user who is not yet a household member'
);

-- 3. B can't share A's account — she doesn't own it.
select throws_like(
  $$ select share_account('a0000000-0000-0000-0000-00000000a001') $$,
  '%not owned by you%',
  'share_account refuses an account the caller does not own'
);

-- ----------------------------------------------------------------------------
-- B joins A's household (simulating Phase 19's accept_invite).
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);

insert into household_members (household_id, user_id)
select household_id, '22222222-2222-2222-2222-222222222222'
from household_members where user_id = '11111111-1111-1111-1111-111111111111';

-- 4. The 2-member cap rejects a third.
select throws_like(
  $$ insert into household_members (household_id, user_id)
     select household_id, '33333333-3333-3333-3333-333333333333'
     from household_members where user_id = '11111111-1111-1111-1111-111111111111' $$,
  '%cannot have more than 2 members%',
  'a household cannot admit a third member'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- 5. Now B can see the shared account.
select is(
  (select count(*) from accounts where id = 'a0000000-0000-0000-0000-00000000a001'),
  1::bigint,
  'once B joins the household, the shared account becomes visible to her'
);

-- 6. H9 regression: the shared account must NOT be dropped from
-- accounts_with_balances (the exact bug the owner-scoped profiles join
-- would have caused — a missing row, not a wrong number).
select is(
  (select name from accounts_with_balances where account_id = 'a0000000-0000-0000-0000-00000000a001'),
  'A Shared',
  'H9 regression: a shared account owned by the other member still appears in accounts_with_balances'
);

-- 7. A's private account is still invisible to B.
select is(
  (select count(*) from accounts where id = 'a0000000-0000-0000-0000-00000000a002'),
  0::bigint,
  'an account never shared stays invisible to the other household member'
);

-- 7b. A transfer between two accounts that are each still PRIVATE (A's
-- never-shared account, B's not-yet-shared one) fails via RLS visibility
-- itself — create_transfer can't even read the other party's private
-- account. Must run here, before B shares her account below, or both
-- accounts become mutually visible and this stops testing what it claims to.
select throws_like(
  $$ select create_transfer('a0000000-0000-0000-0000-00000000a002', 'b0000000-0000-0000-0000-00000000b001', 50000) $$,
  '%not found or are not accessible%',
  'a transfer between two private accounts of different, unrelated owners is rejected'
);

-- 8. B can write a transaction on the shared account (can_write_account now
-- recognizes household membership).
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (
  'd0000000-0000-0000-0000-00000000d001', '11111111-1111-1111-1111-111111111111', auth.uid(),
  'a0000000-0000-0000-0000-00000000a001', 'c0000000-0000-0000-0000-00000000a001', -400000, 'EUR', now()
);

select is(
  (select count(*) from transactions where id = 'd0000000-0000-0000-0000-00000000d001'),
  1::bigint,
  'a household member can write a transaction on a shared account she does not own'
);

-- 9. transactions.owner_id stays the account owner; created_by records who
-- actually entered it — the composite FK forces the former, this confirms
-- the latter is exactly the acting member, not the account owner.
select is(
  (select created_by from transactions where id = 'd0000000-0000-0000-0000-00000000d001'),
  '22222222-2222-2222-2222-222222222222'::uuid,
  'created_by on a shared-account transaction records the acting member, not the account owner'
);

-- 10. H9 regression for the transactions view too.
select is(
  (select count(*) from transactions_with_details where transaction_id = 'd0000000-0000-0000-0000-00000000d001'),
  1::bigint,
  'H9 regression: a shared account''s transaction still appears in transactions_with_details for the other member'
);

-- 11. B can also update/archive the shared account itself, even though A
-- owns it (Phase 6's update_account/archive_account addendum to H2).
select is(
  (select conflict from update_account(
    'a0000000-0000-0000-0000-00000000a001', 1, 'A Shared (renamed by B)', 10000000, true,
    'banknote', '#8E8E93'
  )),
  false,
  'a household member can call update_account on a shared account she does not own'
);

-- 12. B shares her own account into the household; A can now see it.
select share_account('b0000000-0000-0000-0000-00000000b001');

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select count(*) from accounts where id = 'b0000000-0000-0000-0000-00000000b001'),
  1::bigint,
  'A can see B''s account once B shares it into their shared household'
);

-- 13. H10: a transfer between two accounts with DIFFERENT owners succeeds
-- when both accounts share a household — the exact case check_transfer_
-- integrity's original "exactly one owner" rule would have rejected.
-- check_transfer_integrity is DEFERRABLE INITIALLY DEFERRED, so it would
-- never actually run inside this whole-file transaction (see _helpers.psql's
-- gotcha #2) without forcing it — without this line, the assertion below
-- would pass vacuously regardless of whether the relaxed rule is correct.
-- A's shared account is EUR, B's is USD — cross-currency, so to_amount must
-- be supplied explicitly (create_transfer's own rule, unrelated to households).
select create_transfer('a0000000-0000-0000-0000-00000000a001', 'b0000000-0000-0000-0000-00000000b001', 1000000, 900000);
set constraints all immediate;
set constraints all deferred;

select is(
  (select count(*) from transactions
    where transfer_group_id = (
      select transfer_group_id from transactions
      where account_id = 'a0000000-0000-0000-0000-00000000a001' and transfer_group_id is not null
      order by created_at desc limit 1
    )
    and deleted_at is null),
  2::bigint,
  'H10: a cross-owner transfer succeeds when both legs'' accounts share a household'
);

-- ----------------------------------------------------------------------------
-- net_worth(scope) — total is always me + household, never subtraction (H5).
-- ----------------------------------------------------------------------------

select ok(net_worth('me') is not null, 'net_worth(''me'') is computable for A (no missing rates in scope)');
select ok(net_worth('household') is not null, 'net_worth(''household'') is computable for A');

select is(
  net_worth('total'),
  net_worth('me') + net_worth('household'),
  'net_worth(''total'') is always me + household, never assembled by subtraction'
);

-- 15. Viewer-scoped base currency (H1/H9's actual money-facing consequence):
-- A (base EUR) and B (base USD) see the SAME shared EUR account converted
-- through their OWN base currency, not a shared/owner-derived one.
reset role;
select upsert_fx_rate('USD', current_date, 0.9, 'ecb', now());
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select base_currency from account_balances_base where account_id = 'a0000000-0000-0000-0000-00000000a001'),
  'EUR',
  'A (base EUR) sees the shared EUR account converted through her own base currency'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select base_currency from account_balances_base where account_id = 'a0000000-0000-0000-0000-00000000a001'),
  'USD',
  'B (base USD) sees the SAME shared account converted through HER base currency, not A''s'
);

select isnt(
  (select balance_base_e4 from account_balances_base where account_id = 'a0000000-0000-0000-0000-00000000a001'),
  (select balance_e4 from account_balances_base where account_id = 'a0000000-0000-0000-0000-00000000a001'),
  'B''s converted balance for the shared EUR account differs from the raw EUR balance (a real conversion happened)'
);

-- 16. unshare_account is not a fork — the account row itself is completely
-- unchanged, and visibility for the other member simply disappears.
select unshare_account('b0000000-0000-0000-0000-00000000b001');

select is(
  (select owner_id from accounts where id = 'b0000000-0000-0000-0000-00000000b001'),
  '22222222-2222-2222-2222-222222222222'::uuid,
  'unshare_account never changes the account''s owner_id — no fork, no copy'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select count(*) from accounts where id = 'b0000000-0000-0000-0000-00000000b001'),
  0::bigint,
  'after unshare_account, the other member loses visibility into the account immediately'
);

-- ----------------------------------------------------------------------------
-- No raw client write path onto any of the four new tables — every write
-- goes through create_household/share_account/unshare_account (and, in
-- Phase 19, the invite RPCs). Same "write only through a vetted function"
-- precedent as sync_conflicts and fx_rates.
-- ----------------------------------------------------------------------------

select throws_ok(
  $$ insert into households (id) values (gen_random_uuid()) $$,
  null::char(5), null,
  'authenticated has no raw INSERT grant on households'
);

select throws_ok(
  $$ insert into household_members (household_id, user_id) values (gen_random_uuid(), auth.uid()) $$,
  null::char(5), null,
  'authenticated has no raw INSERT grant on household_members'
);

select throws_ok(
  $$ insert into household_accounts (household_id, account_id) values (gen_random_uuid(), gen_random_uuid()) $$,
  null::char(5), null,
  'authenticated has no raw INSERT grant on household_accounts'
);

select throws_ok(
  $$ insert into household_invites (household_id, invited_by, token_hash, expires_at)
     values (gen_random_uuid(), auth.uid(), 'x', now()) $$,
  null::char(5), null,
  'authenticated has no raw INSERT grant on household_invites'
);

select * from finish();
rollback;
