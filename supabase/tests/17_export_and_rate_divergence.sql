-- Export and the transfer rate-divergence guard — what is left of migration
-- 20260809100000_csv_import_export.sql after 20260909100000_remove_csv_import
-- took the import half away.
--
-- The first block asserts the removal itself. It is here rather than nowhere
-- because "the feature is gone" is exactly the kind of claim that quietly
-- stops being true: a later migration restating `needs_review` or
-- `fork_one_account` from an old copy would put the branch back, and nothing
-- else in the suite would notice.
--
-- Fixture A = 11111111-..., fixture B = 22222222-....

\ir _helpers.psql

begin;
select plan(10);

-- ----------------------------------------------------------------------------
-- CSV import is gone
-- ----------------------------------------------------------------------------

-- 1/2. The staging tables.
select hasnt_table('public', 'csv_import_batches', 'csv_import_batches is gone');
select hasnt_table('public', 'csv_import_candidates', 'csv_import_candidates is gone');

-- 3/4/5. And the three RPCs that drove them.
select hasnt_function('public', 'import_csv_rows', 'import_csv_rows is gone');
select hasnt_function('public', 'accept_import_candidate', 'accept_import_candidate is gone');
select hasnt_function('public', 'reject_import_candidate', 'reject_import_candidate is gone');

-- 6. But `csv_import` stays on `transaction_source`, deliberately: a
-- transaction a user accepted from an import before the feature was removed
-- still carries it, and that is a true fact about a real money record.
-- Dropping the label would mean destroying those rows or lying about where
-- they came from. See the migration's header.
select enum_has_labels(
  'public',
  'transaction_source',
  array['manual', 'capture', 'recurring', 'adjustment', 'csv_import'],
  'transaction_source keeps its csv_import label for transactions already imported'
);

-- ----------------------------------------------------------------------------
-- Export audit log
-- ----------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a3000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'A Checking', 'EUR', 0);

-- 7. One export, one audit row for the caller.
select log_export(array['a3000000-0000-0000-0000-000000000001']::uuid[], 5);
select is(
  (select count(*) from export_audit_log where owner_id = auth.uid()),
  1::bigint,
  'log_export writes one audit row for the calling user'
);

-- 8. Owner-scoped, never cross-visible even between household members — a
-- household member's export is still their own act.
select is(
  (select count(*) from export_audit_log where owner_id = '22222222-2222-2222-2222-222222222222'),
  0::bigint,
  'fixture A cannot see fixture B''s export audit rows'
);

-- ----------------------------------------------------------------------------
-- check_transfer_rate_divergence — reuses 05_fx.sql's fixture rate
-- (USD 0.90 to EUR, 10 days ago, carried forward to today by fx_rate_on).
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
delete from fx_rates where currency = 'USD';
set local role service_role;
select upsert_fx_rate('USD', current_date - 10, 0.90, 'ecb', now());
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 9. Market-consistent EUR->USD: fx_convert(1, 'EUR', 'USD', date) = 0.90, so
-- 100 EUR implies to_amount ~= 90 USD.
select is(
  (select diverges from check_transfer_rate_divergence('EUR', 'USD', 1000000, 900000, now())),
  false,
  'a transfer whose implied rate matches the market rate does not diverge'
);

-- 10. A "320 typed as 3200" style typo: 10x off.
select is(
  (select diverges from check_transfer_rate_divergence('EUR', 'USD', 1000000, 9000000, now())),
  true,
  'a transfer implying a rate 10x off the market rate is flagged as diverging'
);

select * from finish();
rollback;
