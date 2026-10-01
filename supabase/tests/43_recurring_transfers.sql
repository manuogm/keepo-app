-- Recurring transfers (migration 20260927100000_recurring_transfers.sql):
-- the two shapes a rule may take, the three things a transfer rule is
-- refused for, the PAIR materialize_recurring mints for one, and the
-- widened delete_account retirement.
--
-- The pair is the part worth the most assertions. A transfer rule that
-- materialized only its outflow would read as an expense that quietly
-- shrank the user's net worth every month, and the ledger would show one
-- orphan leg rather than a folded transfer — so both legs, their shared
-- group, their opposite signs and their idempotency are each pinned
-- separately.
--
-- Fixture A = 11111111-..., fixture B = 22222222-....

\ir _helpers.psql

begin;
select plan(18);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a4300000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'A Current', 'EUR', 10000000),
  ('a4300000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'regular', 'A Savings', 'EUR', 0),
  ('a4300000-0000-0000-0000-000000000003', auth.uid(), auth.uid(), 'regular', 'A Dollars', 'USD', 0);

insert into categories (id, owner_id, kind, name)
values ('c4300000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Rent');

-- ----------------------------------------------------------------------------
-- 1-5. The shape. A rule is an expense/income (category, no destination) or
-- a transfer (destination, no category) — never both, never neither.
-- ----------------------------------------------------------------------------

-- 1. The valid transfer rule. `to_account_id` set, `category_id` null,
-- amount negative because it is the outflow from the source account.
insert into recurring_rules (
  id, account_id, to_account_id, amount_e4, currency, frequency, next_due_at, created_by
) values (
  'e4300000-0000-0000-0000-000000000001', 'a4300000-0000-0000-0000-000000000001',
  'a4300000-0000-0000-0000-000000000002', -5000000, 'EUR', 'monthly', current_date,
  '11111111-1111-1111-1111-111111111111'
);

select is(
  (select owner_id from recurring_rules where id = 'e4300000-0000-0000-0000-000000000001'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'a transfer rule derives owner_id from its source account, same trigger as any other rule'
);

-- 2. Both halves of the shape at once.
select throws_ok(
  $$
    insert into recurring_rules (
      account_id, to_account_id, category_id, amount_e4, currency, frequency, next_due_at, created_by
    ) values (
      'a4300000-0000-0000-0000-000000000001', 'a4300000-0000-0000-0000-000000000002',
      'c4300000-0000-0000-0000-000000000001', -5000000, 'EUR', 'monthly', current_date,
      '11111111-1111-1111-1111-111111111111'
    )
  $$,
  '23514', null,
  'a rule carrying both a category and a destination account is refused'
);

-- 3. Neither half.
select throws_ok(
  $$
    insert into recurring_rules (account_id, amount_e4, currency, frequency, next_due_at, created_by)
    values (
      'a4300000-0000-0000-0000-000000000001', -5000000, 'EUR', 'monthly', current_date,
      '11111111-1111-1111-1111-111111111111'
    )
  $$,
  '23514', null,
  'a rule with neither a category nor a destination account is refused'
);

-- 4. A transfer to the account it came from moves no money and would
-- materialize two legs onto one account.
select throws_ok(
  $$
    insert into recurring_rules (
      account_id, to_account_id, amount_e4, currency, frequency, next_due_at, created_by
    ) values (
      'a4300000-0000-0000-0000-000000000001', 'a4300000-0000-0000-0000-000000000001',
      -5000000, 'EUR', 'monthly', current_date, '11111111-1111-1111-1111-111111111111'
    )
  $$,
  '23514', null,
  'a transfer rule pointing at its own source account is refused'
);

-- 5. The sign. Money rule 1 — the stored amount is the outflow and nothing
-- re-signs it on the way to materialization, so a positive one would mint a
-- pair that credited both accounts.
select throws_like(
  $$
    insert into recurring_rules (
      account_id, to_account_id, amount_e4, currency, frequency, next_due_at, created_by
    ) values (
      'a4300000-0000-0000-0000-000000000001', 'a4300000-0000-0000-0000-000000000002',
      5000000, 'EUR', 'monthly', current_date, '11111111-1111-1111-1111-111111111111'
    )
  $$,
  '%must be negative%',
  'a positive transfer amount is refused — the stored figure is the outflow'
);

-- 6. Cross-currency. There is no honest destination amount to store for a
-- rule that fires unattended (see the migration's header), so the pair is
-- refused at creation rather than guessed at every month.
select throws_like(
  $$
    insert into recurring_rules (
      account_id, to_account_id, amount_e4, currency, frequency, next_due_at, created_by
    ) values (
      'a4300000-0000-0000-0000-000000000001', 'a4300000-0000-0000-0000-000000000003',
      -5000000, 'EUR', 'monthly', current_date, '11111111-1111-1111-1111-111111111111'
    )
  $$,
  '%same currency%',
  'a cross-currency transfer rule is refused at creation'
);

-- 7. The ordinary shape still works, unchanged.
insert into recurring_rules (
  id, account_id, category_id, amount_e4, currency, frequency, next_due_at, created_by
) values (
  'e4300000-0000-0000-0000-000000000002', 'a4300000-0000-0000-0000-000000000001',
  'c4300000-0000-0000-0000-000000000001', -9000000, 'EUR', 'monthly', current_date,
  '11111111-1111-1111-1111-111111111111'
);

select is(
  (select count(*) from recurring_rules where account_id = 'a4300000-0000-0000-0000-000000000001'),
  2::bigint,
  'an ordinary expense rule is unaffected by the widened shape'
);

-- ----------------------------------------------------------------------------
-- 8-14. Materialization mints a PAIR for a transfer rule.
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  materialize_recurring(current_date),
  3,
  'one due transfer rule and one due expense rule mint 3 rows — two legs and one expense'
);

select is(
  (select count(*) from transactions where recurring_rule_id = 'e4300000-0000-0000-0000-000000000001'),
  2::bigint,
  'the transfer rule minted exactly two legs'
);

select is(
  (select count(distinct transfer_group_id) from transactions
   where recurring_rule_id = 'e4300000-0000-0000-0000-000000000001'),
  1::bigint,
  'both legs share one transfer_group_id, so the ledger folds them into one row'
);

-- Both legs carry the rule id. This is what the ledger's recurring glyph and
-- "edit all future occurrences" read, and it is the reason the migration
-- restricts a transfer rule to one owner: transactions_recurring_rule_owner_fk
-- is composite, so a destination leg owned by somebody else could not be
-- stamped at all.
select is(
  (select count(*) from transactions
   where recurring_rule_id = 'e4300000-0000-0000-0000-000000000001' and source = 'recurring'),
  2::bigint,
  'both legs are stamped source=recurring and carry the rule id'
);

select is(
  (select amount_e4 from transactions
   where recurring_rule_id = 'e4300000-0000-0000-0000-000000000001'
     and account_id = 'a4300000-0000-0000-0000-000000000001'),
  -5000000::bigint,
  'the source account''s leg is the negative outflow'
);

select is(
  (select amount_e4 from transactions
   where recurring_rule_id = 'e4300000-0000-0000-0000-000000000001'
     and account_id = 'a4300000-0000-0000-0000-000000000002'),
  5000000::bigint,
  'the destination account''s leg is the matching positive inflow'
);

-- The pair nets to nothing across the two accounts — a transfer moves money,
-- it does not create or destroy it (money rule 1).
select is(
  (select sum(amount_e4)::bigint from transactions
   where recurring_rule_id = 'e4300000-0000-0000-0000-000000000001'),
  0::bigint,
  'the two legs net to zero — a recurring transfer never changes net worth'
);

-- ----------------------------------------------------------------------------
-- 15-16. Idempotency. Each leg carries its own external_id suffix; a single
-- shared one would let the second insert be swallowed by the first's
-- conflict and leave a permanently one-sided transfer.
-- ----------------------------------------------------------------------------

select is(
  materialize_recurring(current_date),
  0,
  're-running materialize_recurring mints neither leg a second time'
);

select is(
  (select count(distinct external_id) from transactions
   where recurring_rule_id = 'e4300000-0000-0000-0000-000000000001'),
  2::bigint,
  'the two legs carry DISTINCT external_ids, which is what makes the pair idempotent'
);

-- ----------------------------------------------------------------------------
-- 17. transactions_with_details reports the pair as a transfer, so the
-- ledger draws it exactly like a hand-entered one.
-- ----------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select count(*) from transactions_with_details
   where recurring_rule_id = 'e4300000-0000-0000-0000-000000000001' and kind = 'transfer'),
  2::bigint,
  'both materialized legs report kind=transfer through transactions_with_details'
);

-- ----------------------------------------------------------------------------
-- 18. delete_account retires a rule reached through its DESTINATION.
--
-- Without this, materialize_recurring — which selects on `active and
-- next_due_at <= …` and never asks whether the accounts still exist — would
-- keep minting a pair onto the account the user just deleted.
-- ----------------------------------------------------------------------------

select delete_account(
  'a4300000-0000-0000-0000-000000000002',
  (select version from accounts where id = 'a4300000-0000-0000-0000-000000000002'),
  true
);
-- Forced, because this account holds halves of the pairs the rule minted,
-- and the delete used to leave their partners as lone legs — which
-- check_transfer_integrity refuses at COMMIT. Without this line that failure
-- was invisible here: a deferred trigger never fires in a file that rolls
-- back. 20261007100000 keeps those halves as anchors; this is what proves it.
set constraints all immediate;
set constraints all deferred;

reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select active from recurring_rules where id = 'e4300000-0000-0000-0000-000000000001'),
  false,
  'deleting the DESTINATION account retires the transfer rule aimed at it'
);

select * from finish();
rollback;
