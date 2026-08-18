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
select plan(45);

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
insert into categories (id, owner_id, kind, name)
values ('c2000000-0000-0000-0000-000000000002', auth.uid(), 'expense', 'Dining Out');

-- 0. S-02: a raw client insert can no longer forge a source='capture' row
-- (which would skip capture_transaction's rate limiter and idempotency
-- entirely) or set external_id directly.
select throws_like(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency,
       occurred_at, source, status)
     values (auth.uid(), auth.uid(), 'a2000000-0000-0000-0000-000000000001',
       'c2000000-0000-0000-0000-000000000001', -1000, 'EUR', now(), 'capture', 'pending') $$,
  '%row-level security%',
  'a raw insert cannot forge source = capture, bypassing the rate limiter'
);

select throws_like(
  $$ insert into transactions (owner_id, created_by, account_id, category_id, amount_e4, currency,
       occurred_at, external_id)
     values (auth.uid(), auth.uid(), 'a2000000-0000-0000-0000-000000000001',
       'c2000000-0000-0000-0000-000000000001', -1000, 'EUR', now(), 'forged-ext-id') $$,
  '%row-level security%',
  'a raw insert cannot set external_id directly'
);

-- 1. Capturing on a never-seen card now still creates the transaction —
-- pending, categorized (fallback "Other"), account/currency null — plus
-- the placeholder card_mappings row, same as before.
-- capture_transaction returns void (X-05) — nothing has decoded its return
-- value since 20260822100000 made the insert unconditional, so "resolved
-- or not" is asserted against the row it wrote, not a return column.
select capture_transaction(
  'd2000000-0000-0000-0000-000000000001', 'card-xyz', 'SQ *BLUE BOTTLE 001', 'BLUE BOTTLE',
  45000, now(), 'ext-1'
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
select capture_transaction(
  'd2000000-0000-0000-0000-000000000002', 'card-xyz', 'SQ *BLUE BOTTLE 001', 'BLUE BOTTLE',
  45000, now(), 'ext-2'
);

select is(
  (select account_id from transactions where id = 'd2000000-0000-0000-0000-000000000002'),
  'a2000000-0000-0000-0000-000000000001'::uuid,
  'capturing on a mapped card resolves the account'
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
-- merchant_category_map's direct grants were revoked in S-02 (every real
-- write goes through review_capture_transaction/confirm_capture_transaction,
-- both SECURITY DEFINER) — this fixture pre-seeds a mapping the same way
-- those RPCs would, so it needs the same elevated privilege.
reset role;
insert into merchant_category_map (owner_id, merchant_pattern, category_id)
values (auth.uid(), 'BLUE BOTTLE', 'c2000000-0000-0000-0000-000000000001');
set local role authenticated;

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

select capture_transaction(
  'd2000000-0000-0000-0000-000000000005', 'card-review-link', 'BURGER KING', 'BURGER KING', 5000, now(), 'ext-5'
);

select is(
  (select account_id from transactions where id = 'd2000000-0000-0000-0000-000000000005'),
  'a2000000-0000-0000-0000-000000000003'::uuid,
  'a second capture on the now-auto-linked card resolves normally'
);

-- ----------------------------------------------------------------------------
-- 8b. review_capture_transaction — the one-write "review, then confirm"
-- path TransactionFormView.save() actually uses instead of update_transaction
-- + confirm_capture_transaction as two separate writes (migration
-- 20260825100000's whole reason for existing — see its header). Re-uses
-- fixture d2000000-...0003 (still pending, version 1, account resolved by
-- section 6/7's card-xyz mapping, category the learned Coffee mapping from
-- section 7 assigned — nothing since section 7 has touched it): proves the
-- edit and the confirm land atomically, and that reviewing re-teaches
-- merchant_category_map with whatever category the user actually picked,
-- not just what capture guessed. Placed here, before section 9's
-- idempotency check and section 10's rate limit — like section 8 above,
-- every capture_transaction call in this section must land before the
-- rate limit section per the file header note.
-- ----------------------------------------------------------------------------

select review_capture_transaction(
  'd2000000-0000-0000-0000-000000000003', 1, 'a2000000-0000-0000-0000-000000000001',
  'c2000000-0000-0000-0000-000000000002', -52500, 'EUR', now(), 'Blue Bottle Coffee', 'Reviewed'
);

select is(
  (select status::text from transactions where id = 'd2000000-0000-0000-0000-000000000003'),
  'confirmed',
  'review_capture_transaction confirms the row in the same write as the edit'
);

select is(
  (select category_id from transactions where id = 'd2000000-0000-0000-0000-000000000003'),
  'c2000000-0000-0000-0000-000000000002'::uuid,
  'review_capture_transaction applies the edited category atomically with the confirm'
);

select is(
  (select merchant_raw from transactions where id = 'd2000000-0000-0000-0000-000000000003'),
  'Blue Bottle Coffee',
  'review_capture_transaction applies the edited merchant_raw'
);

select is(
  (select category_id from merchant_category_map where owner_id = auth.uid() and merchant_pattern = 'BLUE BOTTLE'),
  'c2000000-0000-0000-0000-000000000002'::uuid,
  'reviewing a capture re-teaches merchant_category_map with the category actually chosen'
);

select capture_transaction(
  'd2000000-0000-0000-0000-000000000007', 'card-xyz', 'SQ *BLUE BOTTLE 003', 'BLUE BOTTLE', 60000, now(), 'ext-7'
);

select is(
  (select category_id from transactions where id = 'd2000000-0000-0000-0000-000000000007'),
  'c2000000-0000-0000-0000-000000000002'::uuid,
  'a later capture from the same merchant resolves to the re-taught category, not the original one'
);

select throws_like(
  $$ select review_capture_transaction(
    'd2000000-0000-0000-0000-000000000003', 2, 'a2000000-0000-0000-0000-000000000001',
    'c2000000-0000-0000-0000-000000000002', -52500, 'EUR', now()
  ) $$,
  '%not a pending capture%',
  'review_capture_transaction refuses a row that is already confirmed'
);

-- Captured here (before section 9/10's capture_transaction cutoff, per the
-- file header) so section 11 below can confirm it with no edit at all and
-- prove confirm_capture_transaction (migration 20260826100000) re-teaches
-- merchant_category_map exactly like review_capture_transaction already
-- does — a plain swipe-confirm of a resolved capture is just as much a
-- "the user agreed with this category" signal as an edited one.
select capture_transaction(
  'd2000000-0000-0000-0000-000000000008', 'card-xyz', 'CORNER CAFE', 'CORNER CAFE', 1200, now(), 'ext-8'
);

-- d2000000-...0004: resolved via update_transaction in section 8 (account
-- assigned, never confirmed) — still pending, version bumped to 2 by that
-- update. Called here with a deliberately stale version (1) to prove a
-- conflict logs instead of applying, and that the row is left completely
-- untouched rather than partially edited — the single-statement guarantee
-- migration 20260825100000 exists for.
select is(
  (select conflict from review_capture_transaction(
    'd2000000-0000-0000-0000-000000000004', 1, 'a2000000-0000-0000-0000-000000000003',
    (select category_id from transactions where id = 'd2000000-0000-0000-0000-000000000004'),
    -10660, 'EUR', now()
  )),
  true,
  'review_capture_transaction logs a conflict instead of applying on a stale expected_version'
);

select is(
  (select status::text from transactions where id = 'd2000000-0000-0000-0000-000000000004'),
  'pending',
  'a conflicted review leaves the row exactly as it was — still pending, not partially applied'
);

-- ----------------------------------------------------------------------------
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

-- 11b. confirm_capture_transaction (no edit) re-teaches merchant_category_map
-- with whatever category capture_transaction already assigned — same
-- upsert review_capture_transaction does, just on the plain-confirm path.
select confirm_capture_transaction('d2000000-0000-0000-0000-000000000008', 1);

select is(
  (select category_id from merchant_category_map where owner_id = auth.uid() and merchant_pattern = 'CORNER CAFE'),
  (select category_id from transactions where id = 'd2000000-0000-0000-0000-000000000008'),
  'a plain swipe-confirm re-teaches merchant_category_map with the capture''s own category'
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

-- Resolved by natural key (owner + current card_identifier), not by the
-- mapping's own row id — that id is server-generated and a client can't
-- reliably know it ahead of a sync pull, which is exactly what made a
-- capture's local-first write-through permanently fail "not found" on
-- retry when it guessed wrong (found chasing a real device bug).
select rename_card_mapping('card-review-link', 'Revolut');

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
-- takes its orphaned placeholder card_mappings row with it (fix B, 2026-08
-- device-testing batch) — deleting the purchase is a clear signal the user
-- doesn't want the card filed either, so both Needs Review items clear
-- together rather than leaving a bare "Unmapped card" item behind with
-- nothing left to explain it. Uses 'card-to-unmap' (captured just before
-- the rate-limit section) rather than 'card-xyz', which section 5 already
-- mapped to a real account and so was never a placeholder to begin with.
select delete_transaction('d2000000-0000-0000-0000-000000000006', 1);

select is(
  (select count(*) from needs_review where kind = 'ambiguous_card'
   and item_id = (select id from card_mappings where card_identifier = 'card-to-unmap')),
  0::bigint,
  'deleting an unresolved capture also retires its orphaned placeholder card_mappings row'
);

select is(
  (select deleted_at is not null from card_mappings
   where owner_id = auth.uid() and card_identifier = 'card-to-unmap'),
  true,
  'the placeholder mapping itself is soft-deleted, not merely hidden from needs_review'
);

-- Re-mapping a card that was ever unmapped (here: auto-retired by the
-- delete above) must resurrect it, not leave it soft-deleted forever
-- (item 1 fix): link_card_to_account's upsert set account_id on the
-- conflict branch but never cleared deleted_at, so a re-map "succeeded"
-- into a row no deleted_at-filtered read could ever see again — the
-- exact bug the Account edit sheet's "Add Card" flow hit.
select map_card('card-to-unmap', 'a2000000-0000-0000-0000-000000000001');

select is(
  (select account_id from card_mappings
   where owner_id = auth.uid() and card_identifier = 'card-to-unmap' and deleted_at is null),
  'a2000000-0000-0000-0000-000000000001'::uuid,
  're-mapping a previously unmapped card clears deleted_at, making it visible again'
);

-- ----------------------------------------------------------------------------
-- 13b. Unmapping a card must actually stop it routing new captures (fix A,
-- 2026-08 device-testing batch) — capture_transaction's own card lookup
-- used to ignore deleted_at, so a card the user had explicitly unmapped
-- kept silently auto-filing new purchases into the account it used to
-- belong to, even though every display read correctly showed it as
-- unmapped: a real discrepancy between what the app surfaced and what the
-- DB actually resolved. This must be the LAST capture_transaction call in
-- this file (see this file's own header note on the shared rate-limit
-- window) — the window is backdated first since section 9 already
-- exhausted this user's budget.
-- ----------------------------------------------------------------------------

select unmap_card('card-xyz');

reset role;
select set_config('request.jwt.claim.sub', '', true);
update ops_rate_limits set window_started_at = now() - interval '2 hours'
where function_name = 'capture_transaction' and subject = '11111111-1111-1111-1111-111111111111';
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select capture_transaction(
  'd2000000-0000-0000-0000-000000000009', 'card-xyz', 'SQ *BLUE BOTTLE 004', 'BLUE BOTTLE', 30000, now(), 'ext-9'
);

select is(
  (select account_id from transactions where id = 'd2000000-0000-0000-0000-000000000009'),
  null::uuid,
  'a capture on a card that was explicitly unmapped resolves to no account, not the account it used to route to'
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
  $$ select rename_card_mapping('Revolut', 'stolen') $$,
  '%not found%',
  'fixture B cannot rename fixture A''s card mapping by its identifier'
);

select throws_like(
  $$ select review_capture_transaction(
    'd2000000-0000-0000-0000-000000000004', 2, 'a2000000-0000-0000-0000-000000000003',
    gen_random_uuid(), -10660, 'EUR', now()
  ) $$,
  '%not found%',
  'fixture B cannot review fixture A''s pending capture'
);

select * from finish();
rollback;
