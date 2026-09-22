-- Due-ness is decided in the owner's calendar, a rule on a put-away account
-- goes dormant, and a rule's currency must match its account
-- (migration 20260929100000_recurring_is_due_in_the_users_own_calendar.sql).
--
-- **On making "what day is it" deterministic in a test.** `now()` is frozen
-- for the whole file and cannot be moved, so the zones do the work instead:
-- Pacific/Kiritimati (UTC+14) and Pacific/Pago_Pago (UTC-11) are twenty-five
-- hours apart, so whenever this suite runs, Kiritimati's calendar date is
-- **strictly ahead** of Pago Pago's. Every assertion below is written against
-- that relationship rather than against any particular date, so none of it
-- depends on the wall clock.
--
-- Fixture A = 11111111-... (Kiritimati, UTC+14 — the furthest ahead on earth)
-- Fixture B = 22222222-... (Pago Pago, UTC-11 — the furthest behind)

\ir _helpers.psql

begin;
select plan(15);

update profiles set time_zone = 'Pacific/Kiritimati' where id = '11111111-1111-1111-1111-111111111111';
update profiles set time_zone = 'Pacific/Pago_Pago'  where id = '22222222-2222-2222-2222-222222222222';

-- The two "todays", and the guarantee the rest of the file leans on.
select (now() at time zone 'Pacific/Kiritimati')::date as a_today \gset
select (now() at time zone 'Pacific/Pago_Pago')::date  as b_today \gset

select ok(
  :'a_today'::date > :'b_today'::date,
  'the two fixtures are on different calendar days — UTC+14 is always ahead of UTC-11'
);

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a4500000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Checking', 'EUR', 10000000),
  ('a4500000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'regular', 'B Checking', 'USD', 10000000),
  ('a4500000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Savings', 'EUR', 0);

insert into categories (id, owner_id, kind, name)
values
  ('c4500000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Rent A'),
  ('c4500000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'expense', 'Rent B');

-- ----------------------------------------------------------------------------
-- 2-3. A rule's currency must match its account's — money rule 1, since the
--      balance is a running sum over rows that must share one currency.
-- ----------------------------------------------------------------------------

select throws_like(
  $$
    insert into recurring_rules (account_id, category_id, amount_e4, currency, frequency, next_due_at, created_by)
    values (
      'a4500000-0000-0000-0000-000000000001', 'c4500000-0000-0000-0000-000000000001',
      -129900, 'JPY', 'monthly', current_date, '11111111-1111-1111-1111-111111111111'
    )
  $$,
  '%currency must match its account%',
  'a rule whose currency disagrees with its account is refused'
);

insert into recurring_rules (id, account_id, category_id, amount_e4, currency, frequency, next_due_at, created_by)
values (
  'e4500000-0000-0000-0000-000000000001', 'a4500000-0000-0000-0000-000000000001',
  'c4500000-0000-0000-0000-000000000001', -129900, 'EUR', 'monthly', :'a_today',
  '11111111-1111-1111-1111-111111111111'
);

select is(
  (select currency from recurring_rules where id = 'e4500000-0000-0000-0000-000000000001'),
  'EUR',
  'a matching currency is accepted'
);

-- ----------------------------------------------------------------------------
-- 4-7. Due-ness in the owner's own calendar.
--
-- B's rule is dated A's today, which is always in B's FUTURE. Under the old
-- `materialize_recurring(current_date)` this was decided against the server's
-- UTC day for both users at once, so exactly one of them was always wrong.
-- ----------------------------------------------------------------------------

insert into recurring_rules (id, account_id, category_id, amount_e4, currency, frequency, next_due_at, created_by)
values (
  'e4500000-0000-0000-0000-000000000002', 'a4500000-0000-0000-0000-000000000002',
  'c4500000-0000-0000-0000-000000000002', -50000, 'USD', 'monthly', :'a_today',
  '22222222-2222-2222-2222-222222222222'
);

-- No argument: each rule is judged where its owner is.
select materialize_recurring();

select is(
  (select count(*) from transactions where recurring_rule_id = 'e4500000-0000-0000-0000-000000000001'),
  1::bigint,
  'the UTC+14 user''s rule, due on THEIR today, materialized'
);

select is(
  (select count(*) from transactions where recurring_rule_id = 'e4500000-0000-0000-0000-000000000002'),
  0::bigint,
  'the UTC-11 user''s rule, dated a day still in their future, did NOT — the old code minted it early'
);

select is(
  (select next_due_at from recurring_rules where id = 'e4500000-0000-0000-0000-000000000002'),
  :'a_today'::date,
  'and its next_due_at is untouched, so it will fire when that day actually arrives there'
);

-- An explicit p_through still forces one calendar for everybody, which is
-- what an ops backfill or the rest of this suite means by passing a date.
select materialize_recurring(:'a_today'::date);

select is(
  (select count(*) from transactions where recurring_rule_id = 'e4500000-0000-0000-0000-000000000002'),
  1::bigint,
  'passing p_through explicitly overrides the per-owner calendar, as the ops surface always has'
);

-- ----------------------------------------------------------------------------
-- 8-12. A rule on a put-away account goes dormant: no rows, but next_due_at
--       still advances, so nothing floods back on unarchive and the health
--       check does not report it overdue forever.
-- ----------------------------------------------------------------------------

insert into recurring_rules (id, account_id, category_id, amount_e4, currency, frequency, next_due_at, created_by)
values (
  'e4500000-0000-0000-0000-000000000003', 'a4500000-0000-0000-0000-000000000003',
  'c4500000-0000-0000-0000-000000000001', -7500, 'EUR', 'monthly', :'a_today',
  '11111111-1111-1111-1111-111111111111'
);

update accounts set archived_at = now() where id = 'a4500000-0000-0000-0000-000000000003';

select materialize_recurring();

select is(
  (select count(*) from transactions where recurring_rule_id = 'e4500000-0000-0000-0000-000000000003'),
  0::bigint,
  'an archived account mints nothing — it used to keep minting, invisibly, with no way to stop it'
);

select ok(
  (select next_due_at from recurring_rules where id = 'e4500000-0000-0000-0000-000000000003') > :'a_today'::date,
  'but next_due_at still advanced, so unarchiving does not replay months of backdated rows'
);

select is(
  (select active from recurring_rules where id = 'e4500000-0000-0000-0000-000000000003'),
  true,
  'and `active` is untouched — archiving is not pausing, and the round trip must not eat the user''s own choice'
);

-- Unarchived, it resumes on its own — no reactivation step, because nothing
-- was deactivated.
update accounts set archived_at = null where id = 'a4500000-0000-0000-0000-000000000003';
update recurring_rules set next_due_at = :'a_today'::date
where id = 'e4500000-0000-0000-0000-000000000003';

select materialize_recurring();

select is(
  (select count(*) from transactions where recurring_rule_id = 'e4500000-0000-0000-0000-000000000003'),
  1::bigint,
  'unarchiving resumes it with no further action'
);

-- 12. A transfer whose DESTINATION is archived is dormant too: minting the
--     outflow alone would leave a one-sided transfer.
insert into recurring_rules (
  id, account_id, to_account_id, amount_e4, currency, frequency, next_due_at, created_by
) values (
  'e4500000-0000-0000-0000-000000000004', 'a4500000-0000-0000-0000-000000000001',
  'a4500000-0000-0000-0000-000000000003', -25000, 'EUR', 'monthly', :'a_today',
  '11111111-1111-1111-1111-111111111111'
);

update accounts set archived_at = now() where id = 'a4500000-0000-0000-0000-000000000003';

select materialize_recurring();

select is(
  (select count(*) from transactions where recurring_rule_id = 'e4500000-0000-0000-0000-000000000004'),
  0::bigint,
  'a transfer whose destination is archived mints neither leg, not just the one that still has a home'
);

-- ----------------------------------------------------------------------------
-- 13. The materialized row takes its currency from the ACCOUNT, which is the
--     only thing a balance can be summed in.
-- ----------------------------------------------------------------------------

select is(
  (select distinct currency from transactions where recurring_rule_id = 'e4500000-0000-0000-0000-000000000001'),
  (select currency from accounts where id = 'a4500000-0000-0000-0000-000000000001'),
  'the materialized row is in its account''s currency, read from the account rather than the rule''s copy'
);

-- ----------------------------------------------------------------------------
-- 14-15. Deleting a category takes its recurring rules with it.
--
-- Transactions were always reassigned to the owner's default; rules were not,
-- so the rule vanished from the list (which resolves a subject through a live
-- category) while still minting a row a month under the tombstone.
-- ----------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select delete_category_and_reassign('c4500000-0000-0000-0000-000000000001');

reset role;
select set_config('request.jwt.claim.sub', '', true);

select is(
  (select category_id from recurring_rules where id = 'e4500000-0000-0000-0000-000000000001'),
  (select id from categories
   where owner_id = '11111111-1111-1111-1111-111111111111'
     and kind = 'expense' and is_default and deleted_at is null),
  'deleting a category re-points its recurring rules at the default, as it already did for transactions'
);

select is(
  (select count(*) from recurring_rules r
   join categories c on c.id = r.category_id
   where r.owner_id = '11111111-1111-1111-1111-111111111111' and c.deleted_at is not null),
  0::bigint,
  'no rule is left pointing at a tombstoned category — the state that made one invisible but still writing'
);

select * from finish();
rollback;
