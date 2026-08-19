-- CSV import & export (migration 20260809100000_csv_import_export.sql):
-- import matching, accept/reject, needs_review branch, RLS across a shared
-- household account, export audit log, and the transfer rate-divergence
-- guard. Fixture A = 11111111-..., fixture B = 22222222-....

\ir _helpers.psql

begin;
select plan(19);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a3000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'A Checking', 'EUR', 0);
insert into categories (id, owner_id, kind, name)
values ('c3000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Groceries');

-- An existing transaction to match against.
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values (
  'd3000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'a3000000-0000-0000-0000-000000000001',
  'c3000000-0000-0000-0000-000000000001', -420000, 'EUR', now() - interval '1 day'
);

-- 1/2. import_csv_rows: one matching row (same amount/currency, within 3
-- days), one non-matching row.
select is(
  (
    select count(*) from import_csv_rows(
      'a3000000-0000-0000-0000-000000000001', 'statement.csv',
      jsonb_build_array(
        jsonb_build_object(
          'occurred_at', (now() - interval '1 day')::text, 'amount_e4', '-420000', 'currency', 'EUR',
          'merchant_raw', 'SUPERMARKET', 'merchant_normalized', 'SUPERMARKET'
        ),
        jsonb_build_object(
          'occurred_at', now()::text, 'amount_e4', '-99900', 'currency', 'EUR',
          'merchant_raw', 'CAFE', 'merchant_normalized', 'CAFE'
        )
      )
    )
  ),
  2::bigint,
  'import_csv_rows inserts one candidate per row'
);

select is(
  (select matched_transaction_id from csv_import_candidates where amount_e4 = -420000 and account_id = 'a3000000-0000-0000-0000-000000000001'),
  'd3000000-0000-0000-0000-000000000001'::uuid,
  'a row within 3 days at the exact amount matches the existing transaction'
);

select is(
  (select matched_transaction_id from csv_import_candidates where amount_e4 = -99900),
  null::uuid,
  'a row with no equivalent existing transaction is unmatched'
);

-- 3. Every fresh candidate starts pending.
select is(
  (select count(*) from csv_import_candidates where status <> 'pending' and account_id = 'a3000000-0000-0000-0000-000000000001'),
  0::bigint,
  'every freshly imported candidate starts pending'
);

-- 4/5. accept_import_candidate creates a real transaction and flips status,
-- even for the matched (possible-duplicate) row — the reviewer's call.
select is(
  (select (accept_import_candidate(id)).conflict from csv_import_candidates where amount_e4 = -99900),
  false,
  'accepting an unmatched candidate succeeds'
);

select is(
  (select count(*) from transactions where account_id = 'a3000000-0000-0000-0000-000000000001' and amount_e4 = -99900 and source = 'csv_import'),
  1::bigint,
  'accepting a candidate inserts a confirmed transaction with source csv_import'
);

select is(
  (select status from csv_import_candidates where amount_e4 = -99900),
  'accepted'::import_candidate_status,
  'the candidate itself flips to accepted'
);

-- 6. Accepting an already-reviewed candidate raises.
select throws_ok(
  $$ select accept_import_candidate((select id from csv_import_candidates where amount_e4 = -99900)) $$,
  null::char(5), null,
  're-accepting an already-reviewed candidate raises'
);

-- 7/8. reject_import_candidate flips the matched (duplicate) row without
-- ever touching transactions, and is idempotent on a second call (the
-- RLS-filtered-UPDATE-doesn't-raise lesson: a WHERE status = 'pending' that
-- matches zero rows the second time just no-ops).
select reject_import_candidate((select id from csv_import_candidates where amount_e4 = -420000));

select is(
  (select status from csv_import_candidates where amount_e4 = -420000),
  'rejected'::import_candidate_status,
  'rejecting a matched (likely-duplicate) candidate flips it to rejected'
);

select is(
  (select count(*) from transactions where account_id = 'a3000000-0000-0000-0000-000000000001' and amount_e4 = -420000 and source = 'csv_import'),
  0::bigint,
  'rejecting a candidate never inserts a transaction'
);

select lives_ok(
  $$ select reject_import_candidate((select id from csv_import_candidates where amount_e4 = -420000)) $$,
  'rejecting an already-rejected candidate is a no-op, not an error'
);

-- 9. needs_review carries the still-pending import candidates; the
-- reviewed ones (accepted/rejected) drop out.
select is(
  (select count(*) from needs_review where kind = 'csv_import_candidate' and item_id in (select id from csv_import_candidates where account_id = 'a3000000-0000-0000-0000-000000000001')),
  0::bigint,
  'needs_review carries no rows once every candidate for this account has been reviewed'
);

select import_csv_rows(
  'a3000000-0000-0000-0000-000000000001', 'still-pending.csv',
  jsonb_build_array(jsonb_build_object('occurred_at', now()::text, 'amount_e4', '10000000', 'currency', 'EUR'))
);
select is(
  (select count(*) from needs_review where kind = 'csv_import_candidate' and amount_e4 = 10000000),
  1::bigint,
  'a freshly imported, still-pending candidate surfaces in needs_review'
);

-- 10. RLS: fixture B, with no access to fixture A's private account, gets
-- an empty view row and a raising RPC — never a silently wrong number.
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select throws_ok(
  $$ select import_csv_rows('a3000000-0000-0000-0000-000000000001', 'x.csv', '[]'::jsonb) $$,
  null::char(5), null,
  'a user with no write access to the account cannot start an import batch'
);

select is(
  (select count(*) from csv_import_candidates where account_id = 'a3000000-0000-0000-0000-000000000001'),
  0::bigint,
  'fixture B cannot see fixture A private-account import candidates at all'
);

-- 11. export_audit_log: owner-scoped, never cross-visible even between
-- household members (a household member's export is still their own act).
select log_export(array['a3000000-0000-0000-0000-000000000001']::uuid[], 5);
select is(
  (select count(*) from export_audit_log where owner_id = auth.uid()),
  1::bigint,
  'log_export writes one audit row for the calling user'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  (select count(*) from export_audit_log where owner_id = '22222222-2222-2222-2222-222222222222'),
  0::bigint,
  'fixture A cannot see fixture B''s export audit rows'
);

-- 12/13. check_transfer_rate_divergence: reuses 05_fx.sql's fixture rate
-- (USD 0.90 to EUR, 10 days ago — carried forward to today by fx_rate_on).
reset role;
select set_config('request.jwt.claim.sub', '', true);
delete from fx_rates where currency = 'USD';
set local role service_role;
select upsert_fx_rate('USD', current_date - 10, 0.90, 'ecb', now());
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- Market-consistent EUR->USD: fx_convert(1, 'EUR', 'USD', date) = 0.90, so
-- 100 EUR implies to_amount ~= 90 USD.
select is(
  (select diverges from check_transfer_rate_divergence('EUR', 'USD', 1000000, 900000, now())),
  false,
  'a transfer whose implied rate matches the market rate does not diverge'
);

-- A "320 typed as 3200" style typo: 10x off.
select is(
  (select diverges from check_transfer_rate_divergence('EUR', 'USD', 1000000, 9000000, now())),
  true,
  'a transfer implying a rate 10x off the market rate is flagged as diverging'
);

select * from finish();
rollback;
