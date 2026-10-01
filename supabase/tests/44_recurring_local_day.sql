-- A recurring occurrence lands on the day the user actually chose
-- (migration 20260928100000_recurring_lands_on_the_users_own_day.sql).
--
-- The whole point is that this cannot be checked in one zone. A fix that only
-- tests America/Chicago would pass for the obvious "shift everything twelve
-- hours" non-fix, which corrects the Americas and breaks New Zealand — so
-- every assertion below is made **twice**, once for a user west of UTC and
-- once for a user east of it, and the east-of-UTC half is there to fail if
-- anybody ever reaches for a fixed offset.
--
-- Fixture A = 11111111-... (put in America/Chicago, UTC-5)
-- Fixture B = 22222222-... (put in Pacific/Auckland, UTC+12)

\ir _helpers.psql

begin;
select plan(14);

-- ----------------------------------------------------------------------------
-- 1-3. The column and its validation.
-- ----------------------------------------------------------------------------

select is(
  (select time_zone from profiles where id = '11111111-1111-1111-1111-111111111111'),
  'UTC',
  'a profile defaults to UTC, which reproduces the old behaviour exactly'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select lives_ok(
  $$ update profiles set time_zone = 'America/Chicago' where id = '11111111-1111-1111-1111-111111111111' $$,
  'a signed-in user may set their own time zone — it is on the column-scoped UPDATE whitelist'
);

-- A bad zone must not land: `at time zone` raises on use, and inside
-- materialize_recurring's loop that would abort the nightly job for everyone.
select throws_like(
  $$ update profiles set time_zone = 'Mars/Olympus_Mons' where id = '11111111-1111-1111-1111-111111111111' $$,
  '%not a known IANA time zone%',
  'an unknown zone name is refused at write time, not left for the cron to choke on'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);

update profiles set time_zone = 'Pacific/Auckland' where id = '22222222-2222-2222-2222-222222222222';

-- ----------------------------------------------------------------------------
-- 4. safe_time_zone tolerates what validation would have refused — belt and
--    braces, because a zone valid today can leave a future tzdb.
-- ----------------------------------------------------------------------------

select is(
  safe_time_zone('Mars/Olympus_Mons'),
  'UTC',
  'safe_time_zone falls back to UTC rather than raising, so one bad value cannot stop the job'
);

-- ----------------------------------------------------------------------------
-- Fixtures: one rule each, both due on the same calendar date.
-- ----------------------------------------------------------------------------

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a4400000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'regular', 'A Checking', 'EUR', 10000000),
  ('a4400000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'regular', 'B Checking', 'USD', 10000000);

insert into categories (id, owner_id, kind, name)
values
  ('c4400000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'expense', 'Rent A'),
  ('c4400000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'expense', 'Rent B');

insert into recurring_rules (id, account_id, category_id, amount_e4, currency, frequency, next_due_at, created_by)
values
  ('e4400000-0000-0000-0000-000000000001', 'a4400000-0000-0000-0000-000000000001',
   'c4400000-0000-0000-0000-000000000001', -129900, 'EUR', 'monthly', date '2026-09-20',
   '11111111-1111-1111-1111-111111111111'),
  ('e4400000-0000-0000-0000-000000000002', 'a4400000-0000-0000-0000-000000000002',
   'c4400000-0000-0000-0000-000000000002', -129900, 'USD', 'monthly', date '2026-09-20',
   '22222222-2222-2222-2222-222222222222');

select materialize_recurring(date '2026-09-20');

-- ----------------------------------------------------------------------------
-- 5-8. The instant stored is local midnight, and it renders as the intended
--      calendar date **in the user's own zone** — which is the whole bug.
-- ----------------------------------------------------------------------------

select is(
  (select occurred_at from transactions where recurring_rule_id = 'e4400000-0000-0000-0000-000000000001'),
  timestamptz '2026-09-20 05:00:00+00',
  'a UTC-5 user''s occurrence is stored at their local midnight, not UTC midnight'
);

select is(
  (select (occurred_at at time zone 'America/Chicago')::date
   from transactions where recurring_rule_id = 'e4400000-0000-0000-0000-000000000001'),
  date '2026-09-20',
  'and it renders on the 20th in Chicago — it used to render on the 19th'
);

select is(
  (select occurred_at from transactions where recurring_rule_id = 'e4400000-0000-0000-0000-000000000002'),
  timestamptz '2026-09-19 12:00:00+00',
  'a UTC+12 user''s occurrence is stored at THEIR local midnight, which is the previous UTC day'
);

select is(
  (select (occurred_at at time zone 'Pacific/Auckland')::date
   from transactions where recurring_rule_id = 'e4400000-0000-0000-0000-000000000002'),
  date '2026-09-20',
  'and it still renders on the 20th in Auckland — the east must not regress'
);

-- 9. The two instants are genuinely different, which is the assertion a fixed
--    offset cannot satisfy: no single stored value is right for both users.
select isnt(
  (select occurred_at from transactions where recurring_rule_id = 'e4400000-0000-0000-0000-000000000001'),
  (select occurred_at from transactions where recurring_rule_id = 'e4400000-0000-0000-0000-000000000002'),
  'the same due date stores two different instants for two zones — a fixed offset cannot do this'
);

-- ----------------------------------------------------------------------------
-- 10-14. realign_recurring_occurrences: fixing what is already stored.
-- ----------------------------------------------------------------------------

-- Two rows written the old way, one per user, both at exact UTC midnight.
insert into transactions (
  id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at,
  source, external_id, recurring_rule_id
) values
  ('11440000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111', 'a4400000-0000-0000-0000-000000000001',
   'c4400000-0000-0000-0000-000000000001', -129900, 'EUR', timestamptz '2026-08-20 00:00:00+00',
   'recurring', 'legacy-a', 'e4400000-0000-0000-0000-000000000001'),
  ('22440000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   '22222222-2222-2222-2222-222222222222', 'a4400000-0000-0000-0000-000000000002',
   'c4400000-0000-0000-0000-000000000002', -129900, 'USD', timestamptz '2026-08-20 00:00:00+00',
   'recurring', 'legacy-b', 'e4400000-0000-0000-0000-000000000002');

-- A hand-entered row at the same instant, which must be left alone: only the
-- materializer ever wrote a zone-less date, so only its rows may be moved.
insert into transactions (
  id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at, source
) values (
  '11440000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
  '11111111-1111-1111-1111-111111111111', 'a4400000-0000-0000-0000-000000000001',
  'c4400000-0000-0000-0000-000000000001', -5000, 'EUR', timestamptz '2026-08-20 00:00:00+00', 'manual'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select is(
  realign_recurring_occurrences(),
  1,
  'the western user has exactly one legacy row to move'
);

select is(
  (select occurred_at from transactions where id = '11440000-0000-0000-0000-000000000001'),
  timestamptz '2026-08-20 05:00:00+00',
  'and it is moved to their local midnight on the same calendar date'
);

select is(
  (select occurred_at from transactions where id = '11440000-0000-0000-0000-000000000002'),
  timestamptz '2026-08-20 00:00:00+00',
  'a hand-entered row at the same instant is untouched — its timestamp is real'
);

select is(
  realign_recurring_occurrences(),
  0,
  'calling it again moves nothing — it is idempotent by construction, not by a flag'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- The eastern user's legacy row already renders on the right local day, so
-- there is nothing to move and no reason to churn the row or shift its FX date.
select is(
  realign_recurring_occurrences(),
  0,
  'an east-of-UTC user has nothing to realign — their rows were never displayed wrong'
);

select * from finish();
rollback;
