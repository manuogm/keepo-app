-- The owner keeps the account (20261012100000_the_owner_keeps_the_account.sql).
--
-- Three ways a share ends, each from the same household, each rolled back to
-- the same savepoint:
--
--   U. The owner unshares one account while the household goes on.
--   L. A member leaves, ending the household.
--   D. The partner deletes their Keepo account, with older data (a transfer
--      and a tag) left over from forks before this one (#1).
--
-- Every scenario fires the deferred constraints — the transfer-integrity
-- trigger and the foreign keys — so a lone half or a dangling tag fails the
-- file rather than a commit in production. At top level, not in `lives_ok`:
-- run inside its subtransaction, `set constraints all immediate` stayed in
-- force after the rollback to the savepoint, and the next scenario's fork
-- tripped over its own half-built pairs mid-function.
--
-- Fixture A = 11111111-... (owner of X, Y, Z), fixture B = 22222222-...
-- (owner of W). X and W are shared with full history, Y from 30 days ago, Z
-- is private.

\ir _helpers.psql

begin;
select plan(38);

-- ============================================================================
-- Setup, as postgres
-- ============================================================================

insert into households (id) values ('54000000-0000-0000-0000-000000000001');
insert into household_members (household_id, user_id)
values
  ('54000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('54000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a5400000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Everyday', 'EUR', 500000),
  ('a5400000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A From A Date', 'EUR', 1000000),
  ('a5400000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Private', 'EUR', 0),
  ('a5400000-0000-0000-0000-000000000011', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'regular', 'B Joint', 'EUR', 0);

insert into household_accounts (household_id, account_id, history_from)
values
  ('54000000-0000-0000-0000-000000000001', 'a5400000-0000-0000-0000-000000000001', null),
  ('54000000-0000-0000-0000-000000000001', 'a5400000-0000-0000-0000-000000000002', now() - interval '30 days'),
  ('54000000-0000-0000-0000-000000000001', 'a5400000-0000-0000-0000-000000000011', null);

insert into categories (id, owner_id, kind, name)
values
  ('c5400000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Groceries'),
  ('c5400000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'expense', 'Hobby'),
  ('c5400000-0000-0000-0000-000000000011', '22222222-2222-2222-2222-222222222222', 'expense', 'groceries');

insert into tags (id, owner_id, name)
values
  ('e5400000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Trip'),
  ('e5400000-0000-0000-0000-000000000011', '22222222-2222-2222-2222-222222222222', 'B Stuff');

insert into transactions (
  id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
  notes, title, original_amount_e4, original_currency
)
values (
  'd5400000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
  '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000001',
  'c5400000-0000-0000-0000-000000000001', -10000, 'EUR', now() - interval '5 days',
  'weekly shop', 'Market', -11000, 'USD'
);

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, source, status, deleted_at)
values
  ('d5400000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000001',
   'c5400000-0000-0000-0000-000000000002', -2000, 'EUR', now() - interval '4 days', 'manual', 'confirmed', null),
  -- The owner's pending capture and a deleted row: neither is handed over.
  ('d5400000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000001',
   'c5400000-0000-0000-0000-000000000001', -3000, 'EUR', now() - interval '1 day', 'capture', 'pending', null),
  ('d5400000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000001',
   'c5400000-0000-0000-0000-000000000001', -3500, 'EUR', now() - interval '1 day', 'manual', 'confirmed', now()),
  -- Y: one row before its start date, one after.
  ('d5400000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000002',
   'c5400000-0000-0000-0000-000000000001', -4000, 'EUR', now() - interval '60 days', 'manual', 'confirmed', null),
  ('d5400000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000002',
   'c5400000-0000-0000-0000-000000000001', -5000, 'EUR', now() - interval '10 days', 'manual', 'confirmed', null);

-- Tags on X's row: A's own, and one B put there.
insert into transaction_tags (transaction_id, tag_id)
values
  ('d5400000-0000-0000-0000-000000000001', 'e5400000-0000-0000-0000-000000000001'),
  ('d5400000-0000-0000-0000-000000000001', 'e5400000-0000-0000-0000-000000000011');

-- Transfers: X→Y (both A's, both shared), X→Z (into A's private account), and
-- X→W (A's shared account into B's).
insert into transactions (id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, transfer_group_id)
values
  ('d5400000-0000-0000-0000-000000000011', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000001',
   -7000, 'EUR', now() - interval '3 days', 'd5400000-0000-0000-0000-000000000011'),
  ('d5400000-0000-0000-0000-000000000012', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000002',
   7000, 'EUR', now() - interval '3 days', 'd5400000-0000-0000-0000-000000000011'),
  ('d5400000-0000-0000-0000-000000000021', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000001',
   -8000, 'EUR', now() - interval '3 days', 'd5400000-0000-0000-0000-000000000021'),
  ('d5400000-0000-0000-0000-000000000022', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000003',
   8000, 'EUR', now() - interval '3 days', 'd5400000-0000-0000-0000-000000000021'),
  ('d5400000-0000-0000-0000-000000000031', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000001',
   -9000, 'EUR', now() - interval '2 days', 'd5400000-0000-0000-0000-000000000031'),
  ('d5400000-0000-0000-0000-000000000032', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'a5400000-0000-0000-0000-000000000011',
   9000, 'EUR', now() - interval '2 days', 'd5400000-0000-0000-0000-000000000031');

-- Rules: an expense on X wearing A's tag, a transfer X→Y, and a transfer
-- into X from A's private account (#8).
insert into recurring_rules (id, created_by, account_id, category_id, to_account_id, amount_e4, currency, frequency, next_due_at)
values
  ('b5400000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'a5400000-0000-0000-0000-000000000001', 'c5400000-0000-0000-0000-000000000001', null,
   -1500, 'EUR', 'monthly', current_date + 10),
  ('b5400000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'a5400000-0000-0000-0000-000000000001', null, 'a5400000-0000-0000-0000-000000000002',
   -2000, 'EUR', 'monthly', current_date + 10),
  ('b5400000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'a5400000-0000-0000-0000-000000000003', null, 'a5400000-0000-0000-0000-000000000001',
   -3000, 'EUR', 'monthly', current_date + 10);

insert into recurring_rule_tags (recurring_rule_id, tag_id)
values ('b5400000-0000-0000-0000-000000000001', 'e5400000-0000-0000-0000-000000000001');

insert into card_mappings (owner_id, card_identifier, account_id)
values ('11111111-1111-1111-1111-111111111111', 'card-54', 'a5400000-0000-0000-0000-000000000001');

set constraints all immediate;
set constraints all deferred;

-- B's copy of one of A's rows, found by what it holds rather than by id.
create function pg_temp.copy_of(p_original uuid) returns uuid language sql as $$
  select c.id from transactions c join accounts ca on ca.id = c.account_id
  join transactions o on o.id = p_original
  where c.owner_id <> o.owner_id and c.amount_e4 = o.amount_e4 and c.occurred_at = o.occurred_at
    and ca.name = (select name from accounts where id = o.account_id)
$$;

savepoint before_the_share_ends;

-- ============================================================================
-- U. A unshares X; the household goes on
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select unshare_account('a5400000-0000-0000-0000-000000000001');
reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select archived_at is null and deleted_at is null from accounts where id = 'a5400000-0000-0000-0000-000000000001'),
  true,
  'U: the owner keeps the unshared account as it was'
);

select is(
  (select array_agg(owner_id::text order by owner_id) from accounts where name = 'A Everyday'),
  array['11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'],
  'U: and only the member losing access is handed a copy'
);

select is(
  (select opening_balance_e4 from accounts where name = 'A Everyday' and owner_id = '22222222-2222-2222-2222-222222222222'),
  500000::bigint,
  'U: the copy opens where the account did, since the share had full history'
);

select is(
  (select count(*) from transactions t join accounts a on a.id = t.account_id
   where a.name = 'A Everyday' and a.owner_id = '22222222-2222-2222-2222-222222222222'),
  5::bigint,
  'U: the copy holds what B could see, confirmed and live — not the pending capture or the deleted row'
);

select is(
  (select row(notes, title, original_amount_e4, original_currency)::text
   from transactions where id = pg_temp.copy_of('d5400000-0000-0000-0000-000000000001')),
  row('weekly shop', 'Market', -11000::bigint, 'USD')::text,
  'U: a copy keeps its note, title and paid-in-currency figures'
);

select is(
  (select array[
     (select category_id from transactions where id = pg_temp.copy_of('d5400000-0000-0000-0000-000000000001')),
     (select category_id from transactions where id = pg_temp.copy_of('d5400000-0000-0000-0000-000000000002'))
   ]),
  array[
    'c5400000-0000-0000-0000-000000000011'::uuid,
    (select id from categories where owner_id = '22222222-2222-2222-2222-222222222222' and kind = 'expense' and is_default)
  ],
  'U: a copy wears the member''s own category by name, or their default'
);

select is(
  (select array_agg(g.name order by g.name) from transaction_tags tt join tags g on g.id = tt.tag_id
   where tt.transaction_id = pg_temp.copy_of('d5400000-0000-0000-0000-000000000001')
     and tt.deleted_at is null and g.owner_id = '22222222-2222-2222-2222-222222222222'),
  array['B Stuff', 'Trip'],
  'U: and the member''s own tags, created by name where they had none'
);

select is(
  (select array_agg(g.name order by g.name) from transaction_tags tt join tags g on g.id = tt.tag_id
   where tt.transaction_id = 'd5400000-0000-0000-0000-000000000001'
     and tt.deleted_at is null and g.owner_id = '11111111-1111-1111-1111-111111111111'),
  array['B Stuff', 'Trip'],
  'U: the owner''s row swaps the partner''s tag for her own of the same name'
);

select is(
  (select count(*) from transaction_tags
   where transaction_id = 'd5400000-0000-0000-0000-000000000001'
     and tag_id = 'e5400000-0000-0000-0000-000000000011' and deleted_at is not null),
  1::bigint,
  'U: and the partner''s link is a tombstone her phone will hear about'
);

select is(
  (select array_agg(transfer_group_id::text order by id) from transactions
   where id in ('d5400000-0000-0000-0000-000000000011', 'd5400000-0000-0000-0000-000000000012')),
  array['d5400000-0000-0000-0000-000000000011', 'd5400000-0000-0000-0000-000000000011'],
  'U: the owner''s transfer between her accounts is untouched'
);

select is(
  (select row(transfer_group_id is null, source, category_id)::text
   from transactions where id = pg_temp.copy_of('d5400000-0000-0000-0000-000000000011')),
  row(true, 'adjustment',
      (select id from categories where owner_id = '22222222-2222-2222-2222-222222222222' and kind = 'expense' and is_default))::text,
  'U: the member''s copy of a half whose other half stays shared is detached'
);

select is(
  (select row(transfer_group_id is null, source, category_id)::text
   from transactions where id = 'd5400000-0000-0000-0000-000000000031'),
  row(true, 'adjustment',
      (select id from categories where owner_id = '11111111-1111-1111-1111-111111111111' and kind = 'expense' and is_default))::text,
  'U: the owner''s half of a transfer into the partner''s shared account is detached'
);

select is(
  (select transfer_group_id from transactions where id = 'd5400000-0000-0000-0000-000000000032'),
  pg_temp.copy_of('d5400000-0000-0000-0000-000000000031'),
  'U: and the partner''s half pairs with their copy, under the copy''s id'
);

select is(
  (select row(r.active, g.name, g.owner_id)::text
   from recurring_rules r
   join recurring_rule_tags rt on rt.recurring_rule_id = r.id and rt.deleted_at is null
   join tags g on g.id = rt.tag_id
   where r.owner_id = '22222222-2222-2222-2222-222222222222' and r.amount_e4 = -1500),
  row(false, 'Trip', '22222222-2222-2222-2222-222222222222'::uuid)::text,
  'U: a rule on the copy starts paused, wearing the member''s own tag'
);

select is(
  (select count(*) from recurring_rules
   where owner_id = '22222222-2222-2222-2222-222222222222' and to_account_id is not null),
  0::bigint,
  'U: a transfer rule is not copied when only one of its accounts is handed over'
);

select is(
  (select row(active, to_account_id)::text from recurring_rules where id = 'b5400000-0000-0000-0000-000000000003'),
  row(true, 'a5400000-0000-0000-0000-000000000001'::uuid)::text,
  'U: a recurring transfer into the unshared account keeps running (#8)'
);

select is(
  (select account_id from card_mappings where card_identifier = 'card-54'),
  'a5400000-0000-0000-0000-000000000001'::uuid,
  'U: the owner''s card mapping stays on her account'
);

select is(
  (select array_agg(sync_epoch order by id) from profiles
   where id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')),
  array[1::bigint, 2::bigint],
  'U: only the member losing access re-pulls'
);

set constraints all immediate;
select pass('U: every transfer pair is whole');
set constraints all deferred;

rollback to savepoint before_the_share_ends;

-- ============================================================================
-- L. B leaves; the household ends
-- ============================================================================

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select leave_household();
reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select count(*) from accounts
   where id in ('a5400000-0000-0000-0000-000000000001', 'a5400000-0000-0000-0000-000000000002',
                'a5400000-0000-0000-0000-000000000011')
     and archived_at is null and deleted_at is null),
  3::bigint,
  'L: each owner keeps their shared accounts as they were'
);

select is(
  (select array_agg(owner_id::text || ':' || name order by owner_id, name) from accounts
   where name in ('A Everyday', 'A From A Date', 'B Joint')),
  array['11111111-1111-1111-1111-111111111111:A Everyday',
        '11111111-1111-1111-1111-111111111111:A From A Date',
        '11111111-1111-1111-1111-111111111111:B Joint',
        '22222222-2222-2222-2222-222222222222:A Everyday',
        '22222222-2222-2222-2222-222222222222:A From A Date',
        '22222222-2222-2222-2222-222222222222:B Joint'],
  'L: and is handed a copy of each of the other''s'
);

select is(
  (select row(opening_balance_e4, opening_balance_at)::text from accounts
   where name = 'A From A Date' and owner_id = '22222222-2222-2222-2222-222222222222'),
  row(996000::bigint, ((now() - interval '30 days') at time zone 'UTC')::date)::text,
  'L: a copy of an account shared from a date opens on the balance carried into it'
);

select is(
  (select count(*) from transactions t join accounts a on a.id = t.account_id
   where a.name = 'A From A Date' and a.owner_id = '22222222-2222-2222-2222-222222222222'),
  2::bigint,
  'L: and holds only what came after'
);

select is(
  account_balance_on((select id from accounts where name = 'A From A Date' and owner_id = '22222222-2222-2222-2222-222222222222'), current_date),
  account_balance_on('a5400000-0000-0000-0000-000000000002', current_date),
  'L: so the copy''s balance is the true balance'
);

select is(
  (select array_agg(transfer_group_id::text order by id) from transactions
   where id in ('d5400000-0000-0000-0000-000000000011', 'd5400000-0000-0000-0000-000000000012')),
  array['d5400000-0000-0000-0000-000000000011', 'd5400000-0000-0000-0000-000000000011'],
  'L: the owner''s transfer between her accounts is untouched'
);

select is(
  (select array_agg(distinct transfer_group_id) from transactions
   where id in (pg_temp.copy_of('d5400000-0000-0000-0000-000000000011'),
                pg_temp.copy_of('d5400000-0000-0000-0000-000000000012'))),
  array[pg_temp.copy_of('d5400000-0000-0000-0000-000000000011')],
  'L: the member''s copies of both halves are re-paired, under the sending copy''s id'
);

select is(
  (select array_agg(distinct transfer_group_id) from transactions
   where id in ('d5400000-0000-0000-0000-000000000031', pg_temp.copy_of('d5400000-0000-0000-0000-000000000032'))),
  array['d5400000-0000-0000-0000-000000000031'::uuid],
  'L: a transfer between the two members splits — A''s half keeps its group, with her copy of B''s'
);

select is(
  (select array_agg(distinct transfer_group_id) from transactions
   where id in ('d5400000-0000-0000-0000-000000000032', pg_temp.copy_of('d5400000-0000-0000-0000-000000000031'))),
  array[pg_temp.copy_of('d5400000-0000-0000-0000-000000000031')],
  'L: and B''s half pairs with his copy of A''s'
);

select is(
  (select row(transfer_group_id is null, source)::text
   from transactions where id = pg_temp.copy_of('d5400000-0000-0000-0000-000000000021')),
  row(true, 'adjustment')::text,
  'L: the member''s copy of a half into the owner''s private account is detached'
);

select is(
  (select row(r.active, ta.name)::text from recurring_rules r
   join accounts fa on fa.id = r.account_id and fa.name = 'A Everyday'
   join accounts ta on ta.id = r.to_account_id
   where r.owner_id = '22222222-2222-2222-2222-222222222222'),
  row(false, 'A From A Date')::text,
  'L: a transfer rule is copied, paused, when both its accounts are handed over'
);

set constraints all immediate;
select pass('L: every transfer pair is whole');
set constraints all deferred;

rollback to savepoint before_the_share_ends;

-- ============================================================================
-- D. B deletes their Keepo account, over older data
-- ============================================================================

-- What forks before 20261012100000 left behind: a transfer between A's and
-- B's accounts whose share has already ended, and B's tag on A's private row.
insert into accounts (id, owner_id, created_by, kind, name, currency)
values ('a5400000-0000-0000-0000-000000000012', '22222222-2222-2222-2222-222222222222',
        '22222222-2222-2222-2222-222222222222', 'regular', 'B Old Joint', 'EUR');
insert into household_accounts (household_id, account_id, deleted_at)
values
  ('54000000-0000-0000-0000-000000000001', 'a5400000-0000-0000-0000-000000000012', now()),
  ('54000000-0000-0000-0000-000000000001', 'a5400000-0000-0000-0000-000000000003', now());
insert into transactions (id, owner_id, created_by, account_id, amount_e4, currency, occurred_at, transfer_group_id)
values
  ('d5400000-0000-0000-0000-000000000041', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000003',
   -6000, 'EUR', now() - interval '90 days', 'd5400000-0000-0000-0000-000000000041'),
  ('d5400000-0000-0000-0000-000000000042', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'a5400000-0000-0000-0000-000000000012',
   6000, 'EUR', now() - interval '90 days', 'd5400000-0000-0000-0000-000000000041');
insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values ('d5400000-0000-0000-0000-000000000051', '11111111-1111-1111-1111-111111111111',
        '11111111-1111-1111-1111-111111111111', 'a5400000-0000-0000-0000-000000000003',
        'c5400000-0000-0000-0000-000000000001', -500, 'EUR', now() - interval '90 days');
insert into transaction_tags (transaction_id, tag_id)
values ('d5400000-0000-0000-0000-000000000051', 'e5400000-0000-0000-0000-000000000011');

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select delete_own_account();
reset role;
select set_config('request.jwt.claim.sub', '', true);

set constraints all immediate;
select pass('D: a partner with transfers and tags on the owner''s rows can delete their account (#1)');
set constraints all deferred;

select is(
  (select row(transfer_group_id is null, source)::text from transactions where id = 'd5400000-0000-0000-0000-000000000041'),
  row(true, 'adjustment')::text,
  'D: an older transfer half whose other half was theirs is detached'
);

select is(
  (select array_agg(g.name || ':' || g.owner_id::text) from transaction_tags tt join tags g on g.id = tt.tag_id
   where tt.transaction_id = 'd5400000-0000-0000-0000-000000000051'),
  array['B Stuff:11111111-1111-1111-1111-111111111111'],
  'D: an older tag of theirs on the owner''s row becomes the owner''s own'
);

select is(
  (select count(*) from transactions
   where transfer_group_id = 'd5400000-0000-0000-0000-000000000031' and deleted_at is null
     and owner_id = '11111111-1111-1111-1111-111111111111'),
  2::bigint,
  'D: the owner keeps a whole pair from the transfer into the partner''s account'
);

select is(
  (select count(*) from transactions where owner_id = '22222222-2222-2222-2222-222222222222'),
  0::bigint,
  'D: and nothing of the partner''s is left'
);

select is(
  (select archived_at is null from accounts where id = 'a5400000-0000-0000-0000-000000000001'),
  true,
  'D: the owner''s account is as it was'
);

select is(
  (select sync_epoch from profiles where id = '11111111-1111-1111-1111-111111111111'),
  2::bigint,
  'D: the member who stays re-pulls, having lost access to the partner''s accounts'
);

select finish();
rollback;
