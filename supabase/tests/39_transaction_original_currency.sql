-- A purchase made in a currency other than its account's
-- (20260923100000_transaction_original_currency.sql). Covers the three new
-- constraints, capture_transaction's five arms, the two RPCs that store
-- rather than compute, and the two views.
--
-- Read CLAUDE.md money rule 6 before changing anything here. The property
-- under test throughout is that Keepo converts ONLY where no human has seen
-- the number yet (capture_transaction), and stores what it is given
-- everywhere a human has (review/update) — because the ECB reference rate
-- is not the rate the bank charged.
--
-- Ordering note, same as 12_capture.sql: now() is frozen for this whole
-- transaction, so every capture_transaction call here counts toward ONE
-- rate-limit window (20/minute). There are nine.

\ir _helpers.psql

begin;
select plan(31);

-- Rates, as postgres → service_role: EUR is structurally 1, so a EUR→USD
-- conversion is just the USD factor. Two USD rates thirty days apart, very
-- deliberately different, so "which date was used" is answerable from the
-- resulting number alone. THB is CLEARED: a currency you are travelling in
-- is precisely one you hold no account in, so "no rate at all" is the
-- common case for this feature, not an exotic one.
reset role;
delete from fx_rates where currency in ('USD', 'THB');

set local role service_role;
select upsert_fx_rate('USD', current_date - 30, 1.2000, 'ecb', now());
select upsert_fx_rate('USD', current_date, 1.0800, 'ecb', now());

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a3900000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'regular', 'A Dollars', 'USD', 0);
insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values ('a3900000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'regular', 'A Euros', 'EUR', 0);
insert into categories (id, owner_id, kind, name)
values ('c3900000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Travel');

-- The USD account's card is known; the second card is not.
select map_card('card-usd', 'a3900000-0000-0000-0000-000000000001');

-- ============================================================================
-- 1. The constraints
-- ============================================================================

select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency,
       occurred_at, original_amount_e4)
     values (auth.uid(), auth.uid(), 'a3900000-0000-0000-0000-000000000001',
       'c3900000-0000-0000-0000-000000000001', -540000, 'USD', now(), -500000) $$,
  '23514', null,
  'an original amount without its currency is refused'
);

select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency,
       occurred_at, original_currency)
     values (auth.uid(), auth.uid(), 'a3900000-0000-0000-0000-000000000001',
       'c3900000-0000-0000-0000-000000000001', -540000, 'USD', now(), 'EUR') $$,
  '23514', null,
  'an original currency without its amount is refused'
);

-- Non-null originals are what "this was foreign" MEANS, so an original in
-- the row's own currency is not merely redundant, it is a lie.
select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency,
       occurred_at, original_amount_e4, original_currency)
     values (auth.uid(), auth.uid(), 'a3900000-0000-0000-0000-000000000001',
       'c3900000-0000-0000-0000-000000000001', -540000, 'USD', now(), -540000, 'USD') $$,
  '23514', null,
  'an original in the row''s own currency is refused'
);

-- €50 paid cannot have charged +$54.
select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency,
       occurred_at, original_amount_e4, original_currency)
     values (auth.uid(), auth.uid(), 'a3900000-0000-0000-0000-000000000001',
       'c3900000-0000-0000-0000-000000000001', -540000, 'USD', now(), 500000, 'EUR') $$,
  '23514', null,
  'an original whose sign disagrees with the amount is refused'
);

select throws_ok(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency,
       occurred_at, original_amount_e4, original_currency)
     values (auth.uid(), auth.uid(), 'a3900000-0000-0000-0000-000000000001',
       'c3900000-0000-0000-0000-000000000001', -540000, 'USD', now(), -500000, 'ZZZ') $$,
  '23503', null,
  'an original currency Keepo cannot price is refused'
);

-- A manual foreign entry — the shape the transaction form writes.
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency,
  occurred_at, original_amount_e4, original_currency)
values ('d3900000-0000-0000-0000-00000000000f', auth.uid(), auth.uid(),
  'a3900000-0000-0000-0000-000000000001', 'c3900000-0000-0000-0000-000000000001',
  -540000, 'USD', now(), -500000, 'EUR');

select is(
  (select original_currency from transactions where id = 'd3900000-0000-0000-0000-00000000000f'),
  'EUR',
  'a manual entry in another currency is accepted'
);

-- ============================================================================
-- 2. capture_transaction — the only place that converts without a human
-- ============================================================================

-- (a) No currency detected: exactly the behaviour that shipped before this
-- migration existed. This is the regression guard for every ordinary
-- capture.
select capture_transaction(
  'd3900000-0000-0000-0000-000000000001', 'card-usd', 'STARBUCKS', 'STARBUCKS',
  45000, now(), 'ext-39-1'
);

select results_eq(
  $$ select amount_e4, currency, original_amount_e4, original_currency
     from transactions where id = 'd3900000-0000-0000-0000-000000000001' $$,
  $$ values (-45000::bigint, 'USD'::text, null::bigint, null::text) $$,
  'a capture with no detected currency is unchanged: no conversion, no original'
);

-- (b) Detected currency equal to the account's: still nothing to record.
select capture_transaction(
  'd3900000-0000-0000-0000-000000000002', 'card-usd', 'TARGET', 'TARGET',
  45000, now(), 'ext-39-2', null, 'USD'
);

select results_eq(
  $$ select amount_e4, currency, original_amount_e4, original_currency
     from transactions where id = 'd3900000-0000-0000-0000-000000000002' $$,
  $$ values (-45000::bigint, 'USD'::text, null::bigint, null::text) $$,
  'a detected currency matching the account records no original'
);

-- (c) The case the feature exists for: €50.00 paid on a USD card.
select capture_transaction(
  'd3900000-0000-0000-0000-000000000003', 'card-usd', 'CAFE PARIS', 'CAFE PARIS',
  500000, now(), 'ext-39-3', null, 'EUR'
);

select results_eq(
  $$ select amount_e4, currency, original_amount_e4, original_currency
     from transactions where id = 'd3900000-0000-0000-0000-000000000003' $$,
  $$ values (-540000::bigint, 'USD'::text, -500000::bigint, 'EUR'::text) $$,
  'a foreign purchase on a known card is converted, and what was paid is kept'
);

-- (d) The rate date is the purchase's, never today's. Same €50 dated
-- thirty days back, when the factor was 1.2000 rather than 1.0800 — so
-- $60.00, and reading $54.00 here would mean today''s rate leaked in.
select capture_transaction(
  'd3900000-0000-0000-0000-000000000004', 'card-usd', 'CAFE ROMA', 'CAFE ROMA',
  500000, now() - interval '30 days', 'ext-39-4', null, 'EUR'
);

select is(
  (select amount_e4 from transactions where id = 'd3900000-0000-0000-0000-000000000004'),
  -600000::bigint,
  'the conversion uses the rate on the day of the purchase, not today''s'
);

-- (e) No resolvable rate. The row must not claim an account, because there
-- is no number that belongs in that account's currency — money rule 5.
select capture_transaction(
  'd3900000-0000-0000-0000-000000000005', 'card-usd', 'BANGKOK MARKET', 'BANGKOK MARKET',
  25000000, now(), 'ext-39-5', null, 'THB'
);

select results_eq(
  $$ select amount_e4, account_id, currency, original_amount_e4, original_currency
     from transactions where id = 'd3900000-0000-0000-0000-000000000005' $$,
  $$ values (-25000000::bigint, null::uuid, null::text, -25000000::bigint, 'THB'::text) $$,
  'with no resolvable rate the row holds what was paid and claims no account'
);

-- (f) The card is unknown, so there is no account currency to compare
-- against. Hold the pair until the review form supplies one.
select capture_transaction(
  'd3900000-0000-0000-0000-000000000006', 'card-new', 'LISBOA TRAM', 'LISBOA TRAM',
  300000, now(), 'ext-39-6', null, 'EUR'
);

select results_eq(
  $$ select amount_e4, account_id, currency, original_amount_e4, original_currency
     from transactions where id = 'd3900000-0000-0000-0000-000000000006' $$,
  $$ values (-300000::bigint, null::uuid, null::text, -300000::bigint, 'EUR'::text) $$,
  'an unmapped card holds the detected currency instead of discarding it'
);

-- (g) A currency Keepo cannot price is the same as none detected — the
-- server does not take the client's word for it.
select capture_transaction(
  'd3900000-0000-0000-0000-000000000007', 'card-usd', 'ELSEWHERE', 'ELSEWHERE',
  45000, now(), 'ext-39-7', null, 'ZZZ'
);

select results_eq(
  $$ select currency, original_amount_e4, original_currency
     from transactions where id = 'd3900000-0000-0000-0000-000000000007' $$,
  $$ values ('USD'::text, null::bigint, null::text) $$,
  'an unsupported detected currency is ignored, not stored'
);

-- (h) Case is not the client's to get right.
select capture_transaction(
  'd3900000-0000-0000-0000-000000000008', 'card-usd', 'CAFE NICE', 'CAFE NICE',
  500000, now(), 'ext-39-8', null, '  eur '
);

select is(
  (select original_currency from transactions where id = 'd3900000-0000-0000-0000-000000000008'),
  'EUR',
  'a detected currency is normalized before use'
);

-- (i) The original always carries the amount's own sign.
select ok(
  (select original_amount_e4 < 0 from transactions where id = 'd3900000-0000-0000-0000-000000000003'),
  'the original is signed like the amount it replaced'
);

-- ============================================================================
-- 3. review_capture_transaction stores; it does not recompute
--
-- $58.00 is deliberately NOT what fx_convert would produce for €50 (that is
-- $54.00) — it is what a bank charged after its spread. Reading 540000 back
-- here would mean the RPC overwrote a real charge with an estimate, which
-- is the single failure money rule 6 exists to prevent.
-- ============================================================================

select is(
  (select conflict from review_capture_transaction(
    'd3900000-0000-0000-0000-000000000003', 1, 'a3900000-0000-0000-0000-000000000001',
    'c3900000-0000-0000-0000-000000000001', -580000, 'USD', now(), 'CAFE PARIS', null,
    -500000, 'EUR')),
  false,
  'reviewing a foreign capture succeeds'
);

select results_eq(
  $$ select amount_e4, currency, original_amount_e4, original_currency, status::text
     from transactions where id = 'd3900000-0000-0000-0000-000000000003' $$,
  $$ values (-580000::bigint, 'USD'::text, -500000::bigint, 'EUR'::text, 'confirmed'::text) $$,
  'review stores the charged amount the user confirmed, never a recomputed one'
);

-- The held case resolving: the user picks the EUR account for the card
-- that was never mapped, so what was paid IS the account's currency and
-- the original stops meaning anything.
select is(
  (select conflict from review_capture_transaction(
    'd3900000-0000-0000-0000-000000000006', 1, 'a3900000-0000-0000-0000-000000000002',
    'c3900000-0000-0000-0000-000000000001', -300000, 'EUR', now(), 'LISBOA TRAM', null,
    -300000, 'EUR')),
  false,
  'resolving a held capture into an account of the same currency succeeds'
);

select results_eq(
  $$ select currency, original_amount_e4, original_currency
     from transactions where id = 'd3900000-0000-0000-0000-000000000006' $$,
  $$ values ('EUR'::text, null::bigint, null::text) $$,
  'an original equal to the chosen account''s currency is normalized away, not refused'
);

select is(
  (select account_id from card_mappings where owner_id = auth.uid() and card_identifier = 'card-new'),
  'a3900000-0000-0000-0000-000000000002'::uuid,
  'resolving a held capture still links the card it came from'
);

-- ============================================================================
-- 4. update_transaction — same contract, for the whole life of the row
-- ============================================================================

select is(
  (select conflict from update_transaction(
    'd3900000-0000-0000-0000-00000000000f', 1, 'a3900000-0000-0000-0000-000000000001',
    'c3900000-0000-0000-0000-000000000001', -555000, 'USD', now(), null, null,
    -500000, 'EUR')),
  false,
  'editing a foreign transaction succeeds'
);

select results_eq(
  $$ select amount_e4, original_amount_e4, original_currency
     from transactions where id = 'd3900000-0000-0000-0000-00000000000f' $$,
  $$ values (-555000::bigint, -500000::bigint, 'EUR'::text) $$,
  'an edit keeps the original and stores the corrected charge'
);

-- Correcting a row that was never foreign: omitting the pair clears it.
select is(
  (select conflict from update_transaction(
    'd3900000-0000-0000-0000-00000000000f', 2, 'a3900000-0000-0000-0000-000000000001',
    'c3900000-0000-0000-0000-000000000001', -540000, 'USD', now())),
  false,
  'editing without an original succeeds'
);

select results_eq(
  $$ select original_amount_e4, original_currency
     from transactions where id = 'd3900000-0000-0000-0000-00000000000f' $$,
  $$ values (null::bigint, null::text) $$,
  'an edit that names no original clears one that was there'
);

-- ============================================================================
-- 5. The views
-- ============================================================================

select results_eq(
  $$ select original_amount_e4, original_currency, original_minor_unit
     from transactions_with_details where transaction_id = 'd3900000-0000-0000-0000-000000000003' $$,
  $$ values (-500000::bigint, 'EUR'::text, 2::smallint) $$,
  'transactions_with_details exposes the original, with its own minor_unit'
);

-- Both of these guard the near-miss this migration's own header records:
-- transactions_with_details was almost restated from a 20260815 copy that
-- INNER JOINs accounts and omits notes, which would have hidden every
-- unresolved capture — including the ones this migration now creates.
select is(
  (select count(*) from transactions_with_details
    where transaction_id = 'd3900000-0000-0000-0000-000000000005'),
  1::bigint,
  'a capture with no account is still visible in transactions_with_details'
);

select has_column('public', 'transactions_with_details', 'notes', 'transactions_with_details still carries notes');

-- A held capture has no account currency yet, so the inbox labelled its
-- amount against nothing. While held, the amount IS what was paid.
select results_eq(
  $$ select amount_e4, currency from needs_review
     where item_id = 'd3900000-0000-0000-0000-000000000005' and kind = 'pending_capture' $$,
  $$ values (-25000000::bigint, 'THB'::text) $$,
  'Needs Review labels a held capture with the currency it was paid in'
);

select is(
  (select currency from needs_review
    where item_id = 'd3900000-0000-0000-0000-000000000001' and kind = 'pending_capture'),
  'USD',
  'an ordinary capture still shows its account currency in Needs Review'
);

-- ============================================================================
-- 6. A currency you transact in is a currency in use
-- ============================================================================

select has_trigger(
  'public', 'transactions', 'transactions_backfill_fx_on_new_original_currency',
  'a newly transacted currency asks for a rate backfill'
);

select isnt_empty(
  $$ select 1 from pg_proc where proname = 'trigger_fx_backfill_on_new_original_currency'
     and pronamespace = 'public'::regnamespace and prosecdef $$,
  'the backfill trigger function is SECURITY DEFINER, like its two siblings'
);

select * from finish();
rollback;
