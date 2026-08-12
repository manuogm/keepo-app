-- Categories move from plain list rows to icon+color tiles (client work).
-- `icon` is an SF Symbol name, `color` a "#RRGGBB" hex string — both plain
-- text, no new enum: the curated icon set and color picker are UI concerns
-- (KeepoCore/CategoryAppearance.swift), not something the DB should
-- constrain the values of.

alter table categories add column icon text not null default 'tag.fill';
alter table categories add column color text not null default '#8E8E93';

-- Backfill existing rows with a slightly better default than the bare
-- column default — the two categories every user already has (Other,
-- Adjustment) get names matching what they actually are; everything else
-- (any category created before this migration) gets a distinct random
-- color so a pre-existing list of custom categories doesn't render as one
-- undifferentiated gray block. `md5(id::text || clock_timestamp()::text)`
-- rather than plain `random()` — deterministic per statement execution
-- but still varies row to row, and needs no pgcrypto call.
update categories set icon = 'ellipsis.circle.fill' where is_default;
update categories set icon = 'wrench.and.screwdriver.fill' where system_key is not null;
update categories
set color = '#' || substr(md5(id::text || clock_timestamp()::text), 1, 6)
where not is_default and system_key is null;

-- Extends the existing default/system protection (prevent_default_category_
-- deletion, migrations 20260804192805 and 20260806200000) to renaming: a
-- default or system category's name is exactly as fixed as its existence.
-- Icon/color stay editable for every category, "Other" included — nothing
-- external looks a category up by icon or color, only by id/kind/
-- is_default/system_key, so there is nothing for those two columns to break.
create or replace function prevent_default_category_deletion()
returns trigger
language plpgsql
as $$
begin
  if (new.is_default or new.system_key is not null) and new.deleted_at is not null then
    raise exception 'this category cannot be deleted';
  end if;
  if (new.is_default or new.system_key is not null) and new.name <> old.name then
    raise exception 'this category cannot be renamed';
  end if;
  return new;
end;
$$;
