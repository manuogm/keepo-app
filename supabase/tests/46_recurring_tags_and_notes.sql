-- A recurring rule carries tags and a note onto what it materializes
-- (migration 20260930100000_recurring_rules_carry_tags_and_notes.sql).
--
-- The assertion that matters most is the transfer one: a tag goes on the
-- **outflow leg only**, because both legs are real rows and tagging both
-- would make any future sum over that tag count one transfer twice. The note
-- goes on both, because a note is prose and nothing sums it.
--
-- Fixture A = 11111111-..., fixture B = 22222222-....

\ir _helpers.psql

begin;
select plan(14);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a4600000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Checking', 'EUR', 10000000),
  ('a4600000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Savings', 'EUR', 0);

insert into categories (id, owner_id, kind, name)
values ('c4600000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Rent A');

insert into tags (id, owner_id, name)
values
  ('40600000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Fixed costs'),
  ('40600000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Household');

insert into recurring_rules (
  id, account_id, category_id, amount_e4, currency, frequency, next_due_at, notes, created_by
) values (
  'e4600000-0000-0000-0000-000000000001', 'a4600000-0000-0000-0000-000000000001',
  'c4600000-0000-0000-0000-000000000001', -129900, 'EUR', 'monthly', date '2026-09-20',
  'Rent, paid by standing order', '11111111-1111-1111-1111-111111111111'
);

insert into recurring_rule_tags (recurring_rule_id, tag_id, owner_id)
values
  ('e4600000-0000-0000-0000-000000000001', '40600000-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111'),
  ('e4600000-0000-0000-0000-000000000001', '40600000-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111');

-- 1. owner_id comes from the rule, never the client — it has to match for
--    stamp_sync_seq_owner() to file the link in the right sync domain.
select is(
  (select count(*) from recurring_rule_tags
   where recurring_rule_id = 'e4600000-0000-0000-0000-000000000001'
     and owner_id = '11111111-1111-1111-1111-111111111111'),
  2::bigint,
  'a rule''s tag links derive owner_id from the rule'
);

select throws_like(
  $$
    insert into recurring_rule_tags (recurring_rule_id, tag_id, owner_id)
    values ('e4600000-0000-0000-0000-000000000001', '40600000-0000-0000-0000-00000000dead',
            '11111111-1111-1111-1111-111111111111')
  $$,
  '%not found%',
  'a link to a tag that does not exist is refused — by the trigger, which '
  'fires before the deferred foreign key would, so the error arrives at the '
  'statement rather than at commit'
);

-- ----------------------------------------------------------------------------
-- 3-6. An expense occurrence carries the note and both tags.
-- ----------------------------------------------------------------------------

select materialize_recurring(date '2026-09-20');

select is(
  (select notes from transactions where recurring_rule_id = 'e4600000-0000-0000-0000-000000000001'),
  'Rent, paid by standing order',
  'the note lands on the materialized transaction, exactly as typed'
);

select is(
  (select count(*) from transaction_tags tt
   join transactions t on t.id = tt.transaction_id
   where t.recurring_rule_id = 'e4600000-0000-0000-0000-000000000001' and tt.deleted_at is null),
  2::bigint,
  'both of the rule''s tags land on the transaction it minted'
);

-- Re-running must not duplicate the links any more than it duplicates the row.
select materialize_recurring(date '2026-09-20');

select is(
  (select count(*) from transaction_tags tt
   join transactions t on t.id = tt.transaction_id
   where t.recurring_rule_id = 'e4600000-0000-0000-0000-000000000001'),
  2::bigint,
  're-running adds no duplicate links — the occurrence is a no-op, links included'
);

-- A tag added to the rule later reaches the NEXT occurrence, not the last one:
-- the rule's live links are read each time, which is what "edit all future
-- occurrences" means everywhere else in this feature.
insert into tags (id, owner_id, name)
values ('40600000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Reviewed');
insert into recurring_rule_tags (recurring_rule_id, tag_id, owner_id)
values ('e4600000-0000-0000-0000-000000000001', '40600000-0000-0000-0000-000000000003',
        '11111111-1111-1111-1111-111111111111');

select materialize_recurring(date '2026-10-20');

select is(
  (select count(*) from transaction_tags tt
   join transactions t on t.id = tt.transaction_id
   where t.recurring_rule_id = 'e4600000-0000-0000-0000-000000000001'
     and t.occurred_at >= timestamptz '2026-10-01' and tt.deleted_at is null),
  3::bigint,
  'a tag added later reaches the next occurrence'
);

-- ----------------------------------------------------------------------------
-- 7-9. A transfer: note on both legs, tag on the outflow leg only.
-- ----------------------------------------------------------------------------

insert into recurring_rules (
  id, account_id, to_account_id, amount_e4, currency, frequency, next_due_at, notes, created_by
) values (
  'e4600000-0000-0000-0000-000000000002', 'a4600000-0000-0000-0000-000000000001',
  'a4600000-0000-0000-0000-000000000002', -50000, 'EUR', 'monthly', date '2026-09-20',
  'Monthly sweep', '11111111-1111-1111-1111-111111111111'
);

insert into recurring_rule_tags (recurring_rule_id, tag_id, owner_id)
values ('e4600000-0000-0000-0000-000000000002', '40600000-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111');

select materialize_recurring(date '2026-09-20');

select is(
  (select count(*) from transactions
   where recurring_rule_id = 'e4600000-0000-0000-0000-000000000002' and notes = 'Monthly sweep'),
  2::bigint,
  'the note goes on BOTH legs — nothing sums prose'
);

select is(
  (select count(*) from transaction_tags tt
   join transactions t on t.id = tt.transaction_id
   where t.recurring_rule_id = 'e4600000-0000-0000-0000-000000000002' and tt.deleted_at is null),
  1::bigint,
  'the tag goes on ONE leg — tagging both would count a single transfer twice in that tag''s total'
);

select ok(
  (select t.amount_e4 < 0 from transactions t
   join transaction_tags tt on tt.transaction_id = t.id
   where t.recurring_rule_id = 'e4600000-0000-0000-0000-000000000002' and tt.deleted_at is null),
  'and it is the OUTFLOW leg that carries it, matching a hand-entered transfer'
);

-- ----------------------------------------------------------------------------
-- 10-11. Deleting a tag takes the rule links with it, or a deleted tag would
--        keep being stamped onto every future occurrence.
-- ----------------------------------------------------------------------------

update tags set deleted_at = now() where id = '40600000-0000-0000-0000-000000000003';

select is(
  (select count(*) from recurring_rule_tags
   where tag_id = '40600000-0000-0000-0000-000000000003' and deleted_at is null),
  0::bigint,
  'soft-deleting a tag cascades to the rule links that wore it'
);

select is(
  (select count(*) from recurring_rule_tags
   where recurring_rule_id = 'e4600000-0000-0000-0000-000000000001' and deleted_at is null),
  2::bigint,
  'and leaves the rule''s other tags alone'
);

-- ----------------------------------------------------------------------------
-- 12. Merging two tags moves the rule links, so the rule keeps tagging.
-- ----------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select delete_tag_retagging(
  '40600000-0000-0000-0000-000000000002', '40600000-0000-0000-0000-000000000001'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select count(*) from recurring_rule_tags
   where recurring_rule_id = 'e4600000-0000-0000-0000-000000000001' and deleted_at is null),
  1::bigint,
  'merging a tag into one the rule already wore collapses to a single live link, not a key collision'
);

-- ----------------------------------------------------------------------------
-- 13-14. RLS: fixture B sees none of A's rule tags, and cannot make one.
-- ----------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

select is(
  (select count(*) from recurring_rule_tags),
  0::bigint,
  'fixture B sees none of fixture A''s rule tags'
);

select throws_ok(
  $$
    insert into recurring_rule_tags (recurring_rule_id, tag_id, owner_id)
    values ('e4600000-0000-0000-0000-000000000001', '40600000-0000-0000-0000-000000000001',
            '22222222-2222-2222-2222-222222222222')
  $$,
  '42501', null,
  'and cannot tag a rule on an account they cannot write'
);

select * from finish();
rollback;
