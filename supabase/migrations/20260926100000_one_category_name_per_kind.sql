-- One category name per kind, per owner — and a merge of the duplicates
-- that already exist, because nothing has ever stopped them.
--
-- The development database held **nine** "Groceries", nine "Salary" and
-- eight "Dining Out" for a single user, all of them live. They came from
-- running onboarding more than once: the setup step inserts the default
-- catalogue and no constraint, client-side or otherwise, ever asked
-- whether those names were already taken. The visible cost was a category
-- picker listing the same name eight times; the invisible one is worse —
-- spending split across rows that are the same category to the person who
-- made them, which quietly understates every total that groups by it.
--
-- Two halves, in this order: merge what exists, then make it impossible.

-- ----------------------------------------------------------------------------
-- 1. Merge
-- ----------------------------------------------------------------------------

-- The keeper is **the oldest row**, with one exception the schema forces:
-- `prevent_default_category_deletion` refuses to tombstone an `is_default`
-- row, so where a group contains one it keeps its place regardless of age.
-- Those rows are excluded from the losers below too, which cannot actually
-- bite — `categories_one_default_per_kind` already allows only one default
-- per (owner, kind) — but says the rule out loud rather than relying on a
-- second index to hold it up.
--
-- (`system_key`, the other protected flag those functions once tested, was
-- dropped in 20260814100100 along with the system categories themselves.)
create temporary table category_merges as
with ranked as (
  select
    id,
    owner_id,
    is_default as is_protected,
    first_value(id) over (
      partition by owner_id, kind, lower(btrim(name))
      order by is_default desc, created_at, id
    ) as keeper_id
  from public.categories
  where deleted_at is null
)
select id as loser_id, keeper_id, owner_id
from ranked
where id <> keeper_id and not is_protected;

-- Everything that points at a loser is re-pointed at its keeper before the
-- loser is tombstoned, so nothing is left referencing a deleted category.
-- `delete_category_and_reassign` only ever re-pointed `transactions`,
-- which is fine for *its* job (the rows move to the default category) but
-- not for this one: a merge has to carry the whole identity across, and a
-- recurring rule or a learned merchant mapping left behind would resolve
-- to a category the user can no longer see.
--
-- `set_transaction_derived_columns` re-derives `category_kind` on every row
-- this touches, and the keeper is by construction the same kind, so
-- `sign_matches_category_kind` stays satisfied.
update public.transactions t
set category_id = m.keeper_id
from category_merges m
where t.category_id = m.loser_id;

update public.recurring_rules r
set category_id = m.keeper_id
from category_merges m
where r.category_id = m.loser_id;

-- The primary key here is (owner_id, merchant_pattern), so re-pointing
-- category_id can never collide: two merchants that had each learned a
-- different copy of "Groceries" simply both learn the keeper.
update public.merchant_category_map mm
set category_id = m.keeper_id
from category_merges m
where mm.category_id = m.loser_id;

-- Soft, like every other delete in this schema: the `sync_seq` trigger
-- stamps each tombstone, so the phones pull the merge rather than being
-- left with rows the server no longer has.
update public.categories c
set deleted_at = now()
from category_merges m
where c.id = m.loser_id;

drop table category_merges;

-- **Without this the index below cannot be built on any database that
-- actually had duplicates**, which is to say: on exactly the databases
-- this migration exists for. Every foreign key in this schema is
-- `deferrable initially deferred`, so the updates above leave trigger
-- events queued until commit, and Postgres refuses `CREATE INDEX` on a
-- table with pending events — "cannot CREATE INDEX "categories" because
-- it has pending trigger events". A fresh database has nothing to merge,
-- no rows are updated, nothing is queued, and the migration passes
-- happily; it fails only where it has work to do. Found by running the
-- merge against seeded duplicates rather than against a clean reset.
set constraints all immediate;

-- ----------------------------------------------------------------------------
-- 2. Make it impossible
-- ----------------------------------------------------------------------------

-- Shaped exactly like `tags_owner_name_idx`, for the same reasons written
-- there: trimmed and case-insensitive, over live rows only, so a deleted
-- name is free to reuse. It carries `kind` because the two kinds are
-- separate namespaces — "Gift" is a plausible expense *and* a plausible
-- income, and a user who has both has made no mistake.
create unique index categories_one_name_per_kind
  on public.categories (owner_id, kind, lower(btrim(name)))
  where deleted_at is null;
