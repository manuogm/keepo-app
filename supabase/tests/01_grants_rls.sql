-- Schema-wide invariants. These pay compound interest deliberately: every
-- one of them queries information_schema/pg_catalog rather than naming a
-- fixed table list, so a table added in any later phase (Phases 6-20) is
-- covered automatically without anyone remembering to add an assertion for
-- it. See keepo-v1-master-plan.md, Phase 5.

\ir _helpers.psql

begin;
select plan(9);

-- 1. RLS is enabled on every table in public. A table created without
-- `enable row level security` is a silent full-table leak to any role that
-- holds a GRANT on it.
select is(
  (select count(*) from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0::bigint,
  'every table in public has row level security enabled'
);

-- 2. Nothing is ever granted to anon (CLAUDE.md: "Nothing is granted to
-- anon"). This is the assertion that would have caught Phase 1's
-- TRUNCATE-via-pg_default_acl finding immediately, instead of by noticing
-- TRUNCATE actually worked.
select is(
  (select count(*) from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'),
  0::bigint,
  'anon has zero grants on any table in public'
);

-- 3. Zero DELETE policies anywhere — deletion is exclusively soft
-- (deleted_at), never a hard DELETE grant/policy on any table.
select is(
  (select count(*) from pg_policies where schemaname = 'public' and cmd = 'DELETE'),
  0::bigint,
  'no table in public has a DELETE policy'
);

-- 4. Every SECURITY DEFINER function in public pins search_path. An
-- unpinned search_path on a DEFINER function is a privilege-escalation
-- vector (a caller-controlled search_path could shadow a table/function the
-- DEFINER body calls unqualified).
select is(
  (select count(*) from pg_proc
    where pronamespace = 'public'::regnamespace
      and prosecdef
      and not exists (
        select 1 from unnest(coalesce(proconfig, '{}'::text[])) as cfg
        where cfg like 'search_path=%'
      )),
  0::bigint,
  'every SECURITY DEFINER function in public pins search_path'
);

-- 5. Every table in public has RLS enabled AND at least one policy for
-- every privilege it grants to authenticated. A GRANT with zero matching
-- policies for that command means the command is a hard no-op (denied by
-- RLS with no way through) rather than a bug — but a GRANT for a command
-- with a policy that has an always-true USING and no WITH CHECK on UPDATE
-- is a real hole. This assertion catches the narrower, concrete case
-- CLAUDE.md calls out: every UPDATE policy carries both USING and WITH
-- CHECK.
select is(
  (select count(*) from pg_policies
    where schemaname = 'public' and cmd = 'UPDATE'
      and (qual is null or with_check is null)),
  0::bigint,
  'every UPDATE policy in public carries both USING and WITH CHECK'
);

-- 6. Baseline default-privilege hygiene from Phase 1 still holds: anon and
-- authenticated get no TRUNCATE/REFERENCES/TRIGGER/MAINTAIN on any current
-- public table (the pg_default_acl fix only affects tables created AFTER
-- it ran — this re-confirms no later migration re-opened it for a specific
-- table via an explicit GRANT).
select is(
  (select count(*) from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee in ('anon', 'authenticated')
      and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN')),
  0::bigint,
  'no TRUNCATE/REFERENCES/TRIGGER/MAINTAIN grants to anon or authenticated'
);

-- 7. card_mappings/merchant_category_map have no client-facing INSERT or
-- UPDATE grant at all (S-02) — every real write goes through map_card /
-- rename_card_mapping / unmap_card / review_capture_transaction /
-- confirm_capture_transaction, all SECURITY DEFINER, none of which need
-- these grants to run.
select is(
  (select count(*) from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'authenticated'
      and table_name in ('card_mappings', 'merchant_category_map')
      and privilege_type in ('INSERT', 'UPDATE')),
  0::bigint,
  'card_mappings and merchant_category_map have no direct INSERT/UPDATE grant to authenticated'
);

-- 8. Every view in public runs as the invoker, not the definer (Supabase
-- Advisor ERROR 0010). A view's default mode runs as whoever created it —
-- the database owner, who is exempt from RLS — so a view missing this
-- clause hands every row in its underlying tables to anyone with SELECT on
-- the view, regardless of who they are. Caught accounts_with_balances
-- losing this clause in a DROP+CREATE rewrite (CREATE OR REPLACE VIEW
-- cannot remove a column from the middle of the list, which forced the
-- drop); confirmed locally it was not yet exploitable only by the
-- accident of joining exclusively through other invoker views, not by any
-- property of its own grant.
select is(
  (select count(*) from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and not coalesce(c.reloptions::text like '%security_invoker=true%', false)),
  0::bigint,
  'every view in public runs as the invoker, not the definer'
);

-- 9. No function in public is executable by PUBLIC (Supabase Advisor WARN
-- 0028/0029). Postgres grants EXECUTE to PUBLIC on every new function by
-- default; the dangerous state is a function nobody ever ran `revoke`
-- against, which leaves proacl NULL (meaning "defaults apply") rather
-- than an empty, explicit ACL — so this checks both NULL and an explicit
-- PUBLIC ('=') grantee entry. Caught fork_one_account (a SECURITY DEFINER
-- household-forking helper with no auth check of its own, confirmed
-- callable and exploitable by an anonymous caller against an arbitrary
-- account id) and 24 other functions that had a `grant execute ... to
-- postgres` line without the `revoke` it silently assumed.
select is(
  (select count(*) from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (p.proacl is null
           or exists (select 1 from unnest(p.proacl) a where a::text like '=%'))),
  0::bigint,
  'no function in public is executable by PUBLIC'
);

select * from finish();
rollback;
