-- A profile gains a name and a face: `display_name`, `avatar_path`, and the
-- private `avatars` bucket the second one points into.
--
-- Until now a profile was base currency and an onboarding timestamp — the
-- app addressed the user by their email address, which is an identifier, not
-- a name. Both columns are nullable because every existing profile has
-- neither, and a migration that invented a name from the local part of an
-- email would be putting words in the user's mouth. The client renders the
-- absence as an invitation ("Add your name"), never as a guess.

alter table profiles
  add column display_name text,
  add column avatar_path text;

-- Same shape as `tags.name`'s constraint, and for the same reason: the app
-- trims before writing, so a name of nothing but spaces is a bug on the way
-- in, not a value to store and render as blank.
alter table profiles
  add constraint profiles_display_name_length
  check (display_name is null or length(btrim(display_name)) between 1 and 60);

-- The avatar's object key must live under the profile's **own** id.
--
-- The storage policies below already stop one user reading another's object,
-- so this is the second lock: without it a client could still record someone
-- else's path here, and the failure would surface as an avatar that silently
-- never loads rather than as a write that was refused. Path shape is
-- `{user_id}/{uuid}.jpg`, which is exactly what `storage.foldername(name)[1]`
-- reads.
alter table profiles
  add constraint profiles_avatar_path_is_own
  check (avatar_path is null or avatar_path like id::text || '/%');

-- `profiles`' UPDATE grant is **column-scoped** (S-06,
-- 20260827100000_close_direct_write_gaps.sql): a client may set
-- `base_currency` and `onboarded_at` and nothing else, because a raw PATCH
-- on `sync_epoch` would let a removed household member suppress the local
-- wipe that revokes their offline copy of a shared account.
--
-- These two join that whitelist. Neither gates access to anything: they are
-- the user's own presentation of themselves, both are CHECK-constrained
-- above, and `profiles_update`'s `id = auth.uid()` still decides whose row is
-- being written. The columns S-06 exists to protect stay exactly as closed as
-- they were.
grant update (display_name, avatar_path) on profiles to authenticated;

comment on column profiles.display_name is
  'What the app calls the user. Nullable — profiles created before this column exists have none.';
comment on column profiles.avatar_path is
  'Object key in the private `avatars` bucket, always `{id}/{uuid}.jpg`. Null until one is uploaded.';

-- ============================================================================
-- The avatars bucket
--
-- **Private.** A public bucket serves every object to anyone who can guess
-- the URL, and the guess here is a user id — which is not a secret. This is a
-- personal-finance app: a photo of the account holder's face, addressable by
-- their account id, is exactly the kind of thing that must not be world
-- readable. Reads go through a signed URL instead; the client caches the
-- decoded image on disk, so the signing round trip happens rarely.
--
-- `image/jpeg` alone, because the client downscales and re-encodes before
-- upload — accepting formats it never produces would only widen what an
-- attacker may store. 2 MiB is a ceiling, not a target: a 512px JPEG avatar
-- is well under 200 KB.
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 2097152, array['image/jpeg'])
on conflict (id) do nothing;

-- One rule, four verbs: the object's first path segment is the caller's own
-- id. `select auth.uid()` rather than a bare call so the planner hoists it
-- out of the row loop, the same form every policy in `public` uses.
create policy avatars_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy avatars_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- Replacing an avatar is an upsert to a new key plus a delete of the old one,
-- so update is only reached by a same-key overwrite. It is here so that path
-- behaves like the others rather than failing for a reason nobody would guess.
create policy avatars_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy avatars_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
