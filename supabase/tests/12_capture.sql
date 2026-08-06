-- Apple Pay capture (migration 20260807150000_capture.sql): unmapped-card
-- placeholder + needs_review, mapping, merchant-learned categorization,
-- idempotency, rate limiting, confirm/conflict, and RLS scoping. Fixture
-- A = 11111111-..., fixture B = 22222222-....

\ir _helpers.psql

begin;
select plan(20);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a2000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'credit_card', 'A Card', 'EUR', 0);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance)
values ('a2000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'valuation', 'investment', 'A Brokerage', 'EUR', 0);
insert into categories (id, owner_id, kind, name)
values ('c2000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Coffee');

-- 1. Capturing on a never-seen card creates the placeholder mapping, not a
-- transaction — there is no account to attach the amount to yet.
select is(
  (select mapped from capture_transaction(
    'd2000000-0000-0000-0000-000000000001', 'card-xyz', 'SQ *BLUE BOTTLE 001', 'BLUE BOTTLE',
    4.50, now(), 'ext-1'
  )),
  false,
  'capturing on an unmapped card returns mapped = false'
);

select is(
  (select count(*) from transactions where id = 'd2000000-0000-0000-0000-000000000001'),
  0::bigint,
  'no transaction is created for an unmapped card'
);

select is(
  (select count(*) from card_mappings where owner_id = auth.uid() and card_identifier = 'card-xyz' and account_id is null),
  1::bigint,
  'an unmapped card gets a placeholder card_mappings row'
);

-- 2. It surfaces in needs_review as ambiguous_card.
select is(
  (select count(*) from needs_review where kind = 'ambiguous_card'
   and item_id = (select id from card_mappings where card_identifier = 'card-xyz')),
  1::bigint,
  'an unmapped card appears in needs_review as ambiguous_card'
);

-- 3. map_card refuses a non-ledger (valuation) account.
select throws_like(
  $$ select map_card('card-xyz', 'a2000000-0000-0000-0000-000000000002') $$,
  '%ledger%',
  'map_card refuses a valuation account'
);

-- 4. map_card assigns a ledger account; the ambiguous_card row disappears.
select map_card('card-xyz', 'a2000000-0000-0000-0000-000000000001');

select is(
  (select count(*) from needs_review where kind = 'ambiguous_card'),
  0::bigint,
  'mapping the card removes its ambiguous_card row'
);

-- 5. Capturing again on the now-mapped card creates a pending, categorized
-- (fallback Uncategorized), negative-signed transaction in the mapped
-- account's currency.
select is(
  (select mapped from capture_transaction(
    'd2000000-0000-0000-0000-000000000002', 'card-xyz', 'SQ *BLUE BOTTLE 001', 'BLUE BOTTLE',
    4.50, now(), 'ext-2'
  )),
  true,
  'capturing on a mapped card returns mapped = true'
);

select is(
  (select amount from transactions where id = 'd2000000-0000-0000-0000-000000000002'),
  -4.50::numeric(20, 4),
  'the captured row is negative-signed'
);

select is(
  (select currency from transactions where id = 'd2000000-0000-0000-0000-000000000002'),
  'EUR',
  'the captured row takes its currency from the mapped account'
);

select is(
  (select status::text from transactions where id = 'd2000000-0000-0000-0000-000000000002'),
  'pending',
  'the captured row starts pending'
);

select is(
  (select source::text from transactions where id = 'd2000000-0000-0000-0000-000000000002'),
  'capture',
  'the captured row is source=capture'
);

select is(
  (select subtitle from needs_review where kind = 'pending_capture' and item_id = 'd2000000-0000-0000-0000-000000000002'),
  'Uncategorized',
  'a capture with no merchant mapping shows as Uncategorized in needs_review'
);

-- 6. A learned merchant mapping is used on the next capture from the same
-- normalized merchant, and needs_review shows the suggestion.
insert into merchant_category_map (owner_id, merchant_pattern, category_id)
values (auth.uid(), 'BLUE BOTTLE', 'c2000000-0000-0000-0000-000000000001');

select capture_transaction(
  'd2000000-0000-0000-0000-000000000003', 'card-xyz', 'SQ *BLUE BOTTLE 002', 'BLUE BOTTLE', 5.25, now(), 'ext-3'
);

select is(
  (select category_id from transactions where id = 'd2000000-0000-0000-0000-000000000003'),
  'c2000000-0000-0000-0000-000000000001'::uuid,
  'a learned merchant mapping supplies the category on capture'
);

select is(
  (select subtitle from needs_review where kind = 'pending_capture' and item_id = 'd2000000-0000-0000-0000-000000000003'),
  'Suggested: Coffee',
  'needs_review shows the learned category as a suggestion'
);

-- 7. Idempotency: retrying with the exact same client-generated id hits the
-- primary key, not a duplicate row — same pattern as create_transaction.
select throws_ok(
  $$ select capture_transaction(
    'd2000000-0000-0000-0000-000000000003', 'card-xyz', 'SQ *BLUE BOTTLE 002', 'BLUE BOTTLE', 5.25, now(), 'ext-3'
  ) $$,
  '23505', null,
  'retrying a capture with the same client-generated id raises a duplicate-key error, never a second row'
);

-- 8. Rate limit: top up to exactly the threshold (accounting for whatever
-- already landed above), then confirm the next one is rejected. now() is
-- frozen for this whole transaction (per _helpers.psql note 5), so every
-- row inserted here counts toward the same one-minute window.
do $$
declare
  i int;
  remaining int;
begin
  select 20 - count(*) into remaining from transactions
  where owner_id = auth.uid() and source = 'capture' and created_at > now() - interval '1 minute';

  for i in 1..remaining loop
    perform capture_transaction(
      gen_random_uuid(), 'card-xyz', 'RATE TEST', 'RATE TEST', 1.00, now(), 'rate-' || i
    );
  end loop;
end;
$$;

select throws_like(
  $$ select capture_transaction(gen_random_uuid(), 'card-xyz', 'RATE TEST', 'RATE TEST', 1.00, now(), 'rate-over') $$,
  '%rate limit%',
  'the capture past the per-minute threshold is rejected by the rate guard'
);

-- 9. confirm_capture_transaction flips status and removes it from needs_review.
select confirm_capture_transaction('d2000000-0000-0000-0000-000000000002', 1);

select is(
  (select status::text from transactions where id = 'd2000000-0000-0000-0000-000000000002'),
  'confirmed',
  'confirm_capture_transaction flips status to confirmed'
);

select is(
  (select count(*) from needs_review where item_id = 'd2000000-0000-0000-0000-000000000002' and kind = 'pending_capture'),
  0::bigint,
  'confirming a capture removes it from needs_review'
);

-- 10. A stale expected_version logs a sync_conflicts row instead of confirming.
select confirm_capture_transaction('d2000000-0000-0000-0000-000000000003', 999);

select is(
  (select count(*) from sync_conflicts where row_id = 'd2000000-0000-0000-0000-000000000003' and resolved_at is null),
  1::bigint,
  'confirming with a stale version logs a sync_conflicts row instead of applying'
);

-- ----------------------------------------------------------------------------
-- 11. RLS: fixture B never sees fixture A's card mappings, merchant map, or
-- captured transactions.
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select count(*) from card_mappings) + (select count(*) from merchant_category_map)
    + (select count(*) from needs_review where kind in ('pending_capture', 'ambiguous_card')),
  0::bigint,
  'fixture B sees none of fixture A''s card mappings, merchant map, or capture-related needs_review rows'
);

select * from finish();
rollback;
