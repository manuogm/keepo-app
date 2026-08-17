-- Apple Pay capture (migration 20260807150000_capture.sql, revised by
-- 20260822100000_unmapped_capture_lands_locally.sql): an unmapped card now
-- still captures the transaction (account_id/currency null until resolved
-- via update_transaction), merchant-learned categorization, idempotency,
-- rate limiting, confirm/conflict, card-mapping management, and RLS
-- scoping. Fixture A = 11111111-..., fixture B = 22222222-....
--
-- Ordering note: now() is frozen for this whole transaction (per
-- _helpers.psql note 5), so every capture_transaction call anywhere in
-- this file counts toward the SAME one-minute rate-limit window — the
-- rate-limit section (9) must stay the LAST thing that calls
-- capture_transaction, or every subsequent call fails with "rate limit
-- exceeded" instead of whatever it's actually testing.

\ir _helpers.psql

begin;
select plan(32);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a2000000-0000-0000-0000-000000000001', auth.uid(), auth.uid(), 'ledger', 'credit_card', 'A Card', 'EUR', 0);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a2000000-0000-0000-0000-000000000002', auth.uid(), auth.uid(), 'valuation', 'investment', 'A Brokerage', 'EUR', 0);
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values ('a2000000-0000-0000-0000-000000000003', auth.uid(), auth.uid(), 'ledger', 'checking', 'A Checking', 'EUR', 0);
insert into categories (id, owner_id, kind, name)
values ('c2000000-0000-0000-0000-000000000001', auth.uid(), 'expense', 'Coffee');

-- 1. Capturing on a never-seen card now still creates the transaction —
-- pending, categorized (fallback "Other"), account/currency null — plus
-- the placeholder card_mappings row, same as before.
select is(
  (select mapped from capture_transaction(
    'd2000000-0000-0000-0000-000000000001', 'card-xyz', 'SQ *BLUE BOTTLE 001', 'BLUE BOTTLE',
    45000, now(), 'ext-1'
  )),
  false,
  'capturing on an unmapped card still returns mapped = false'
);

select is(
  (select count(*) from transactions where id = 'd2000000-0000-0000-0000-000000000001'),
  1::bigint,
  'an unmapped card capture now still creates a transaction'
);

select is(
  (select account_id is null and currency is null from transactions
   where id = 'd2000000-0000-0000-0000-000000000001'),
  true,
  'the unresolved capture has a null account_id and currency'
);

select is(
  (select card_identifier from transactions where id = 'd2000000-0000-0000-0000-000000000001'),
  'card-xyz',
  'the unresolved capture remembers its card_identifier for later auto-linking'
);

select is(
  (select count(*) from card_mappings where owner_id = auth.uid() and card_identifier = 'card-xyz' and account_id is null),
  1::bigint,
  'an unmapped card still gets a placeholder card_mappings row'
);

-- 2. It surfaces in needs_review as pending_capture, NOT ambiguous_card —
-- the pending_capture row is now the primary "needs your attention"
-- signal; showing both would double-count the same event.
select is(
  (select count(*) from needs_review where kind = 'pending_capture'
   and item_id = 'd2000000-0000-0000-0000-000000000001'),
  1::bigint,
  'the unresolved capture appears in needs_review as pending_capture'
);

select is(
  (select count(*) from needs_review where kind = 'ambiguous_card'),
  0::bigint,
  'the ambiguous_card entry is suppressed while a pending_capture already covers the same card'
);

-- 3. confirm_capture_transaction refuses a still-unresolved capture.
select throws_like(
  $$ select confirm_capture_transaction('d2000000-0000-0000-0000-000000000001', 1) $$,
  '%account%',
  'confirm_capture_transaction refuses a capture with no account yet'
);

-- 4. map_card refuses a non-ledger (valuation) account.
select throws_like(
  $$ select map_card('card-xyz', 'a2000000-0000-0000-0000-000000000002') $$,
  '%ledger%',
  'map_card refuses a valuation account'
);

-- 5. map_card assigns a ledger account going forward, but does NOT
-- retroactively fix the already-captured, still-unresolved transaction —
-- only reviewing that specific transaction (update_transaction) does that.
select map_card('card-xyz', 'a2000000-0000-0000-0000-000000000001');

select is(
  (select account_id from transactions where id = 'd2000000-0000-0000-0000-000000000001'),
  null::uuid,
  'mapping the card directly does not retroactively resolve an already-captured transaction'
);

-- 6. A second capture on the now-mapped card resolves normally.
select is(
  (select mapped from capture_transaction(
    'd2000000-0000-0000-0000-000000000002', 'card-xyz', 'SQ *BLUE BOTTLE 001', 'BLUE BOTTLE',
    45000, now(), 'ext-2'
  )),
  true,
  'capturing on a mapped card returns mapped = true'
);

select is(
  (select amount_e4 from transactions where id = 'd2000000-0000-0000-0000-000000000002'),
  -45000::bigint,
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
  'Other',
  'a capture with no merchant mapping shows as Other in needs_review'
);

-- 7. A learned merchant mapping is used on the next capture from the same
-- normalized merchant, and needs_review shows the suggestion.
insert into merchant_category_map (owner_id, merchant_pattern, category_id)
values (auth.uid(), 'BLUE BOTTLE', 'c2000000-0000-0000-0000-000000000001');

select capture_transaction(
  'd2000000-0000-0000-0000-000000000003', 'card-xyz', 'SQ *BLUE BOTTLE 002', 'BLUE BOTTLE', 52500, now(), 'ext-3'
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

-- ----------------------------------------------------------------------------
-- 8. update_transaction resolving a null account auto-links the card for
-- every future capture on it — the review-and-save flow, not map_card.
-- Placed before the rate-limit section (10) since that section must stay
-- the LAST thing to call capture_transaction — see the file header note.
-- ----------------------------------------------------------------------------

select capture_transaction(
  'd2000000-0000-0000-0000-000000000004', 'card-review-link', 'BURGER KING', 'BURGER KING', 10660, now(), 'ext-4'
);

select is(
  (select account_id from transactions where id = 'd2000000-0000-0000-0000-000000000004'),
  null::uuid,
  'a fresh unmapped card still captures with a null account'
);

select update_transaction(
  'd2000000-0000-0000-0000-000000000004', 1, 'a2000000-0000-0000-0000-000000000003',
  (select category_id from transactions where id = 'd2000000-0000-0000-0000-000000000004'),
  -10660, 'EUR', now()
);

select is(
  (select account_id from transactions where id = 'd2000000-0000-0000-0000-000000000004'),
  'a2000000-0000-0000-0000-000000000003'::uuid,
  'update_transaction assigns the chosen account to the previously-unresolved capture'
);

select is(
  (select account_id from card_mappings where owner_id = auth.uid() and card_identifier = 'card-review-link'),
  'a2000000-0000-0000-0000-000000000003'::uuid,
  'resolving the capture via update_transaction auto-links the card to that account'
);

select is(
  (select mapped from capture_transaction(
    'd2000000-0000-0000-0000-000000000005', 'card-review-link', 'BURGER KING', 'BURGER KING', 5000, now(), 'ext-5'
  )),
  true,
  'a second capture on the now-auto-linked card resolves normally'
);

-- Captured now (before the rate-limit section, per the file-wide
-- ordering note) so section 13 below can delete it and prove the
-- ambiguous_card/unmap_card interaction without needing another capture
-- after the rate limit has already been topped up.
select capture_transaction(
  'd2000000-0000-0000-0000-000000000006', 'card-to-unmap', 'GHOST STORE', 'GHOST STORE', 100, now(), 'ext-6'
);

-- 9. Idempotency: retrying with the exact same client-generated id hits the
-- primary key, not a duplicate row — same pattern as create_transaction.
select throws_ok(
  $$ select capture_transaction(
    'd2000000-0000-0000-0000-000000000003', 'card-xyz', 'SQ *BLUE BOTTLE 002', 'BLUE BOTTLE', 52500, now(), 'ext-3'
  ) $$,
  '23505', null,
  'retrying a capture with the same client-generated id raises a duplicate-key error, never a second row'
);

-- 10. Rate limit: top up to exactly the threshold (accounting for whatever
-- already landed above), then confirm the next one is rejected. Must stay
-- the LAST section that calls capture_transaction — see file header.
do $$
declare
  i int;
  remaining int;
begin
  select 20 - count(*) into remaining from transactions
  where owner_id = auth.uid() and source = 'capture' and created_at > now() - interval '1 minute';

  for i in 1..remaining loop
    perform capture_transaction(
      gen_random_uuid(), 'card-xyz', 'RATE TEST', 'RATE TEST', 10000, now(), 'rate-' || i
    );
  end loop;
end;
$$;

select throws_like(
  $$ select capture_transaction(gen_random_uuid(), 'card-xyz', 'RATE TEST', 'RATE TEST', 10000, now(), 'rate-over') $$,
  '%rate limit%',
  'the capture past the per-minute threshold is rejected by the rate guard'
);

-- 11. confirm_capture_transaction flips status and removes it from needs_review.
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

-- 12. A stale expected_version logs a sync_conflicts row instead of confirming.
select confirm_capture_transaction('d2000000-0000-0000-0000-000000000003', 999);

select is(
  (select count(*) from sync_conflicts where row_id = 'd2000000-0000-0000-0000-000000000003' and resolved_at is null),
  1::bigint,
  'confirming with a stale version logs a sync_conflicts row instead of applying'
);

-- ----------------------------------------------------------------------------
-- 13. rename_card_mapping / unmap_card — the Account edit sheet's "manage
-- mapped cards" RPCs.
-- ----------------------------------------------------------------------------

select rename_card_mapping(
  (select id from card_mappings where owner_id = auth.uid() and card_identifier = 'card-review-link'),
  'Revolut'
);

select is(
  (select count(*) from card_mappings where owner_id = auth.uid() and card_identifier = 'Revolut'
   and account_id = 'a2000000-0000-0000-0000-000000000003'),
  1::bigint,
  'rename_card_mapping changes the card_identifier without touching the account'
);

-- A capture with no pending review still attached to it (deleted via the
-- real delete_transaction RPC, as if the user deleted it without ever
-- assigning an account — delete_transaction needed the same null-account
-- ownership fallback update_transaction did, found by this exact test)
-- makes its still-unmapped card_mappings row ambiguous_card again, then
-- unmap_card removes it from needs_review entirely via deleted_at, not by
-- resurrecting it unmapped. Uses 'card-to-unmap' (captured just before the
-- rate-limit section) rather than 'card-xyz', which section 5 already
-- mapped to a real account and so could never show as ambiguous_card again.
select delete_transaction('d2000000-0000-0000-0000-000000000006', 1);

select is(
  (select count(*) from needs_review where kind = 'ambiguous_card'
   and item_id = (select id from card_mappings where card_identifier = 'card-to-unmap')),
  1::bigint,
  'a deleted, still-unresolved capture lets its card_mappings row reappear as ambiguous_card'
);

select unmap_card((select id from card_mappings where owner_id = auth.uid() and card_identifier = 'card-to-unmap'));

select is(
  (select count(*) from needs_review where kind = 'ambiguous_card'),
  0::bigint,
  'unmap_card removes the mapping from needs_review via deleted_at, not by leaving it unmapped'
);

-- ----------------------------------------------------------------------------
-- 14. RLS: fixture B never sees fixture A's card mappings, merchant map, or
-- captured transactions — and can't rename/unmap A's mappings either.
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

select throws_like(
  $$ select rename_card_mapping(
    (select id from card_mappings limit 1), 'stolen'
  ) $$,
  '%not found%',
  'fixture B cannot rename a card mapping (finds none of its own, and can''t see A''s to target one)'
);

select * from finish();
rollback;
