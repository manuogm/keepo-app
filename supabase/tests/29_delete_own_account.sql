-- Account deletion (migration 20260911100000_delete_own_account.sql).
--
-- The assertions that matter are not "rows went away" — they are the three
-- ways this can go wrong quietly:
--
--   * the **other member** loses history they never agreed to give up,
--   * the `auth.users` delete is **refused by a foreign key** nothing points
--     at, leaving an account half-deleted and a user who cannot try again,
--   * a table added later carries the user's id and **nobody notices**.
--
-- Fixture A = 11111111-..., fixture B = 22222222-.... Both are deleted here;
-- the whole file is one transaction and rolls back, so the shared fixtures
-- survive for the files that run after it.

\ir _helpers.psql

begin;
select plan(16);

-- ----------------------------------------------------------------------------
-- The guard
-- ----------------------------------------------------------------------------

-- 1. Every identity-bearing column in the schema as it stands today is
-- registered. This is the assertion that fails the day someone adds a table
-- with an `owner_id` and forgets deletion exists.
select is(
  (select unregistered_identity_columns()),
  null,
  'every identity-bearing column in the schema is registered for deletion'
);

-- 2. And it genuinely notices. A table with an owner column and no registry
-- row is named, by table and column, rather than deletion silently skipping
-- it — created and dropped inside this transaction.
create table public.guard_probe (id uuid primary key, owner_id uuid not null);
select is(
  (select unregistered_identity_columns()),
  'guard_probe.owner_id',
  'an unregistered identity column is named by the guard'
);

-- 3. ... and `delete_own_account` refuses to run at all while it is there —
-- before anything has been destroyed, which is the only useful moment.
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select throws_like(
  'select delete_own_account()',
  '%unregistered identity column%',
  'delete_own_account refuses to run while an identity column is unregistered'
);
reset role;
drop table public.guard_probe;

-- ----------------------------------------------------------------------------
-- Setup: A and B share a household and one account, with history on it.
-- ----------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select create_household();

insert into accounts (id, owner_id, created_by, kind, name, currency, opening_balance_e4)
values
  ('a9000000-0000-0000-0000-00000000a001', auth.uid(), auth.uid(), 'regular', 'A Shared', 'EUR', 5000000),
  ('a9000000-0000-0000-0000-00000000a002', auth.uid(), auth.uid(), 'regular', 'A Private', 'EUR', 1000000);

insert into categories (id, owner_id, kind, name)
values ('c9000000-0000-0000-0000-00000000a001', auth.uid(), 'expense', 'Food');

insert into transactions (id, owner_id, created_by, account_id, category_id, amount_e4, currency, occurred_at)
values
  (
    'd9000000-0000-0000-0000-00000000a001'::uuid, auth.uid(), auth.uid(),
    'a9000000-0000-0000-0000-00000000a001', 'c9000000-0000-0000-0000-00000000a001',
    -250000, 'EUR', now()
  ),
  (
    'd9000000-0000-0000-0000-00000000a002'::uuid, auth.uid(), auth.uid(),
    'a9000000-0000-0000-0000-00000000a002', 'c9000000-0000-0000-0000-00000000a001',
    -180000, 'EUR', now()
  );

insert into tags (id, owner_id, name) values ('e9000000-0000-0000-0000-00000000a001', auth.uid(), 'Coffee');
insert into transaction_tags (transaction_id, tag_id, owner_id)
values ('d9000000-0000-0000-0000-00000000a001', 'e9000000-0000-0000-0000-00000000a001', auth.uid());

-- A recurring rule and one of its tag links. **The assertion below has always
-- named `recurring_rules`, but nothing here ever created one** — so that line
-- passed vacuously from the day it was written. It is a real check now, and
-- `recurring_rule_tags` (added 20260930100000) joins it.
insert into recurring_rules (
  id, account_id, category_id, amount_e4, currency, frequency, next_due_at, notes, created_by
) values (
  'f9000000-0000-0000-0000-00000000a001', 'a9000000-0000-0000-0000-00000000a002',
  'c9000000-0000-0000-0000-00000000a001', -99000, 'EUR', 'monthly', current_date + 3,
  'Coffee subscription', auth.uid()
);

insert into recurring_rule_tags (recurring_rule_id, tag_id, owner_id)
values ('f9000000-0000-0000-0000-00000000a001', 'e9000000-0000-0000-0000-00000000a001', auth.uid());

select share_account('a9000000-0000-0000-0000-00000000a001');
select log_export(array['a9000000-0000-0000-0000-00000000a001']::uuid[], 2);

create temp table delete_token (token text);
insert into delete_token select create_invite();

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select accept_invite((select token from delete_token));

-- ----------------------------------------------------------------------------
-- A deletes their account while B is still in the household
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select delete_own_account();

reset role;
select set_config('request.jwt.claim.sub', '', true);

-- 4. Nothing of A's survives, anywhere. One assertion over every table the
-- registry claims to handle by destruction, so a table added to the registry
-- but forgotten in the function body fails here rather than in production.
select is(
  (
    select coalesce(sum(leftovers), 0)::bigint from (
      select count(*) as leftovers from profiles where id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from accounts where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from categories where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from transactions where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from tags where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from transaction_tags where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from recurring_rules where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from recurring_rule_tags where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from card_mappings where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from merchant_category_map where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from net_worth_daily where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from sync_conflicts where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from export_audit_log where owner_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from household_members where user_id = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from household_invites where invited_by = '11111111-1111-1111-1111-111111111111'
      union all select count(*) from ops_rate_limits where subject = '11111111-1111-1111-1111-111111111111'
    ) t
  ),
  0::bigint,
  'no row anywhere still belongs to the deleted user'
);

-- 5. B keeps the shared history, under their own ownership. This is the whole
-- reason deletion forks instead of deleting: B consented to nothing.
select is(
  (
    select count(*) from transactions
    where owner_id = '22222222-2222-2222-2222-222222222222' and amount_e4 = -250000
  ),
  1::bigint,
  'the remaining member keeps their forked copy of the shared history'
);

-- 6. And it no longer records a person who does not exist. Without this
-- rewrite the FK on `created_by` refuses the auth delete outright.
select is(
  (
    select count(*) from transactions
    where owner_id = '22222222-2222-2222-2222-222222222222'
      and created_by = '11111111-1111-1111-1111-111111111111'
  ),
  0::bigint,
  'no surviving row still records the deleted user as its creator'
);

-- 7. The household keeps its record that this happened...
select is(
  (select count(*) from household_events where kind = 'member_erased'),
  1::bigint,
  'the member_erased event survives for the remaining member'
);

-- 8. ... without the identity that caused it.
select is(
  (select count(*) from household_events where actor_id = '11111111-1111-1111-1111-111111111111'),
  0::bigint,
  'the surviving event carries no trace of who the actor was'
);

-- 9. B is still a member, so the household stays.
select is(
  (
    select count(*) from households h
    join household_members hm on hm.household_id = h.id and hm.deleted_at is null
    where h.deleted_at is null and hm.user_id = '22222222-2222-2222-2222-222222222222'
  ),
  1::bigint,
  'the household survives while a member remains'
);

-- 10. **The assertion this whole design exists for.** Nothing in `public`
-- still points at the auth row, so the platform's own delete goes through.
-- Before the `created_by` rewrite this raised a foreign-key violation naming
-- a constraint no one would think to look at.
select lives_ok(
  $$ delete from auth.users where id = '11111111-1111-1111-1111-111111111111' $$,
  'the auth user can be deleted with no foreign key left refusing it'
);

-- 11. A deleted profile reads as epoch 0 rather than null — a device that was
-- offline through the deletion comes back with a session that still looks
-- valid, and the client decodes `sync_epoch` as a non-optional integer.
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select is(
  (select p.sync_epoch from pull_changes(0, 0) p),
  0::bigint,
  'pull_changes answers a deleted profile with epoch 0, never null'
);

-- ----------------------------------------------------------------------------
-- B now deletes too — the last member out
-- ----------------------------------------------------------------------------

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- 12. The forked account is really B's: they can still see it right up to the
-- moment they delete it themselves.
select is(
  (select count(*) from accounts where owner_id = auth.uid()),
  1::bigint,
  'the remaining member owns the forked account outright'
);

select delete_own_account();

reset role;
select set_config('request.jwt.claim.sub', '', true);

-- 13. Nothing of B's survives either — the last-member-out path, where there
-- is no other member to fork to.
select is(
  (
    select coalesce(sum(leftovers), 0)::bigint from (
      select count(*) as leftovers from profiles where id = '22222222-2222-2222-2222-222222222222'
      union all select count(*) from accounts where owner_id = '22222222-2222-2222-2222-222222222222'
      union all select count(*) from transactions where owner_id = '22222222-2222-2222-2222-222222222222'
      union all select count(*) from categories where owner_id = '22222222-2222-2222-2222-222222222222'
      union all select count(*) from household_members where user_id = '22222222-2222-2222-2222-222222222222'
    ) t
  ),
  0::bigint,
  'the last member out leaves nothing behind either'
);

-- 14. And the empty household is closed rather than left as a shell nobody
-- can reach — soft-deleted, so a still-syncing device sees a tombstone.
select is(
  (select count(*) from households where deleted_at is null),
  0::bigint,
  'a household with no members left is soft-deleted'
);

-- 15. The second auth delete goes through as cleanly as the first.
select lives_ok(
  $$ delete from auth.users where id = '22222222-2222-2222-2222-222222222222' $$,
  'the last member''s auth user deletes cleanly too'
);

-- 16. Deletion needs a caller. An unauthenticated invocation raises rather
-- than quietly deleting the rows of whoever `auth.uid()` resolved to.
set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);
select throws_like(
  'select delete_own_account()',
  '%no authenticated user%',
  'delete_own_account refuses to run without an authenticated caller'
);

select * from finish();
rollback;
