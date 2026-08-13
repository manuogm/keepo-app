-- Ops platform (migration 20260808100000_ops_platform.sql): cron
-- registration, health derived from data, the rate limiter, secret-missing
-- degradation, and the FX-backfill triggers firing without error.

\ir _helpers.psql

begin;
select plan(17);

-- ----------------------------------------------------------------------------
-- 1-4. Cron jobs registered exactly once each, with the expected schedule.
-- Global state (not per-fixture), set up once by the migration itself.
-- ----------------------------------------------------------------------------

select is(
  (select schedule from cron.job where jobname = 'sync-fx-rates-daily'),
  '0 4 * * *',
  'the daily sync-fx-rates job is registered with the expected schedule'
);

select is(
  (select schedule from cron.job where jobname = 'ops-heartbeat'),
  '*/15 * * * *',
  'the heartbeat job is registered with the expected schedule'
);

select is(
  (select schedule from cron.job where jobname = 'ops-check-and-alert'),
  '*/30 * * * *',
  'the health-check-and-alert job is registered with the expected schedule'
);

select is(
  (select schedule from cron.job where jobname = 'ops-events-prune'),
  '0 3 * * *',
  'the 30-day prune job is registered with the expected schedule'
);

-- ----------------------------------------------------------------------------
-- 5-6. Locked down: neither ops_health() nor ops_check_rate_limit() is
-- reachable by an ordinary signed-in user — this is an ops-only surface,
-- never exposed to the app (spec).
-- ----------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select throws_like(
  $$ select * from ops_health() $$,
  '%permission denied%',
  'an authenticated user cannot call ops_health()'
);

select throws_like(
  $$ select ops_check_rate_limit('x', 1, 1) $$,
  '%permission denied%',
  'an authenticated user cannot call ops_check_rate_limit()'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);

-- ----------------------------------------------------------------------------
-- 7-9. Health derived from data, not job status.
-- ----------------------------------------------------------------------------

select is(
  (select count(*) from ops_health()),
  4::bigint,
  'ops_health() returns exactly the four documented checks'
);

-- Freshness is healthy on a fresh reset+seed (seed.sql's fx_rates run
-- through today). Isolated to this transaction via a SAVEPOINT so deleting
-- fx_rates below never leaks into a later test file.
select is(
  (select healthy from fx_freshness_check()),
  true,
  'fx_freshness_check is healthy immediately after a fresh seed'
);

savepoint fx_staleness_check;
delete from fx_rates;
insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
values (
  'a3000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
  '11111111-1111-1111-1111-111111111111', 'ledger', 'checking', 'Needs USD Rates', 'USD', 0
);

select is(
  (select healthy from fx_freshness_check()),
  false,
  'fx_freshness_check goes unhealthy once a non-EUR account exists with zero fx_rates rows'
);
rollback to savepoint fx_staleness_check;

-- ----------------------------------------------------------------------------
-- 10-12. The rate limiter: N calls succeed, the next is refused, and a
-- window reset (simulated by backdating window_started_at, not by sleeping
-- the test suite) allows one more.
-- ----------------------------------------------------------------------------

select is(ops_check_rate_limit('test-fn-13', 2, 3600), true, 'rate limiter allows call 1 of 2');
select is(ops_check_rate_limit('test-fn-13', 2, 3600), true, 'rate limiter allows call 2 of 2');
select is(ops_check_rate_limit('test-fn-13', 2, 3600), false, 'rate limiter refuses call 3 within the same window');

update ops_rate_limits set window_started_at = now() - interval '2 hours' where function_name = 'test-fn-13';

select is(
  ops_check_rate_limit('test-fn-13', 2, 3600),
  true,
  'a call after the window has elapsed is allowed again, with the counter reset'
);

-- ----------------------------------------------------------------------------
-- 13. ops_http_post logs a missing_vault_secret event rather than raising,
-- when pointed at a secret name that doesn't exist.
-- ----------------------------------------------------------------------------

select lives_ok(
  $$ select ops_http_post('nonexistent_url_secret_13', 'nonexistent_auth_secret_13', 'X-Test', '{}'::jsonb) $$,
  'ops_http_post degrades to a logged event, never an exception, for a missing secret'
);

select is(
  (select count(*) from ops_events
   where code = 'missing_vault_secret' and detail = jsonb_build_object('url_secret', 'nonexistent_url_secret_13')),
  1::bigint,
  'the missing-secret call is logged with the offending secret name in detail'
);

-- ----------------------------------------------------------------------------
-- 14-15. The FX-backfill triggers fire without error on both paths.
-- (`net.http_post` itself only ever queues a request — this asserts the
-- trigger plumbing, not that a real HTTP round trip completed.)
-- ----------------------------------------------------------------------------

select lives_ok(
  $$
    insert into accounts (id, owner_id, created_by, kind, subtype, name, currency, opening_balance_e4)
    values (
      'a3000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
      '11111111-1111-1111-1111-111111111111', 'ledger', 'checking', 'New Currency Account', 'GBP', 0
    )
  $$,
  'inserting an account in a never-before-seen currency fires the backfill trigger without raising'
);

select lives_ok(
  $$ update profiles set base_currency = 'JPY' where id = '22222222-2222-2222-2222-222222222222' $$,
  'changing a profile''s base currency fires the backfill trigger without raising'
);

select * from finish();
rollback;
