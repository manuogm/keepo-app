-- A profile's name and face (migration 20260910100000_profile_identity.sql):
-- the two new columns and their constraints, and the private `avatars`
-- bucket's row-level policies.
--
-- The storage half is exercised with real `storage.objects` inserts rather
-- than by reading `pg_policy`, because the thing worth asserting is not that
-- four policies exist — it is that one user cannot write into, or read from,
-- another user's avatar folder. A policy that exists and is wrong looks
-- identical to a policy that exists and is right until someone tries it.
--
-- Fixture A = 11111111-..., fixture B = 22222222-.... Both already have a
-- `profiles` row: `handle_new_user()` fires on the `auth.users` insert in
-- `_helpers.psql`.

\ir _helpers.psql

begin;
select plan(12);

-- ----------------------------------------------------------------------------
-- The bucket
-- ----------------------------------------------------------------------------

-- 1. Private. A public bucket serves every object to anyone who can guess the
-- URL, and the guess here is a user id — which is not a secret.
--
-- Read here, before the role switch, and not down with the object policies
-- where it belongs by subject: `storage.buckets` has RLS enabled and no
-- policies at all, so `authenticated` sees no bucket rows whatsoever and this
-- would quietly compare NULL to false. Buckets are not something a client
-- enumerates; it names one and the storage API resolves it.
select is(
  (select public from storage.buckets where id = 'avatars'),
  false,
  'the avatars bucket is private'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- ----------------------------------------------------------------------------
-- The columns
-- ----------------------------------------------------------------------------

-- 2/3. Both exist, and both are nullable — every profile that predates this
-- migration has neither, and inventing a name from an email address would be
-- putting words in the user's mouth.
select has_column('public', 'profiles', 'display_name', 'profiles carries a display_name');
select has_column('public', 'profiles', 'avatar_path', 'profiles carries an avatar_path');

-- 4. A name of nothing but whitespace is a bug on the way in, not a value.
select throws_ok(
  $$ update profiles set display_name = '   ' where id = auth.uid() $$,
  '23514',
  null,
  'a whitespace-only display_name is refused'
);

-- 5. And there is a ceiling, so the name cannot be a paragraph.
select throws_ok(
  $$ update profiles set display_name = repeat('a', 61) where id = auth.uid() $$,
  '23514',
  null,
  'a display_name longer than 60 characters is refused'
);

-- 6. An ordinary name goes in untouched — the constraint trims only to
-- measure, it never rewrites what is stored.
update profiles set display_name = '  Manu  ' where id = auth.uid();
select is(
  (select display_name from profiles where id = auth.uid()),
  '  Manu  ',
  'a display_name is stored exactly as given'
);

-- 7. An avatar path under someone else's folder is refused at the column,
-- not merely unreadable at the bucket — the second lock, so recording a
-- foreign path fails as a rejected write rather than as an avatar that
-- silently never loads.
select throws_ok(
  $$
    update profiles
    set avatar_path = '22222222-2222-2222-2222-222222222222/stolen.jpg'
    where id = auth.uid()
  $$,
  '23514',
  null,
  'an avatar_path under another user''s id is refused'
);

-- 8. Under one's own, it is fine — **written in uppercase**, which is the
-- case that actually mattered. Postgres renders `uuid::text` lowercase and
-- Swift's `UUID.uuidString` is uppercase, so a literal comparison here
-- rejected every avatar the iOS client ever tried to record. Written in
-- lowercase, as this assertion first was, the constraint looks correct and
-- the app still cannot upload.
update profiles
set avatar_path = '11111111-1111-1111-1111-111111111111/A1B2.jpg'
where id = auth.uid();
select is(
  (select avatar_path from profiles where id = auth.uid()),
  '11111111-1111-1111-1111-111111111111/A1B2.jpg',
  'an avatar_path under the profile''s own id is accepted whatever its case'
);

-- ----------------------------------------------------------------------------
-- The objects
-- ----------------------------------------------------------------------------

-- 9. A writes into their own folder — uppercased for the same reason as 8.
-- This is the assertion the shipped policy failed: `(storage.foldername
-- (name))[1] = auth.uid()::text` compared 'B31BD8CD-...' against
-- 'b31bd8cd-...' and refused the row.
insert into storage.objects (bucket_id, name, owner)
values ('avatars', '11111111-1111-1111-1111-111111111111/A1B2.jpg', auth.uid());
select is(
  (select count(*) from storage.objects where bucket_id = 'avatars'),
  1::bigint,
  'a user can upload into their own avatar folder'
);

-- 10. ... and not into anyone else's. 42501 is RLS refusing the row, which is
-- the whole point of the folder being the user id.
select throws_ok(
  $$
    insert into storage.objects (bucket_id, name)
    values ('avatars', '22222222-2222-2222-2222-222222222222/impostor.jpg')
  $$,
  '42501',
  null,
  'a user cannot upload into another user''s avatar folder'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);

-- 11. B cannot see A's avatar at all — not a 403 on download, simply no row.
select is(
  (select count(*) from storage.objects where bucket_id = 'avatars'),
  0::bigint,
  'a user cannot see another user''s avatar object'
);

reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

-- 12. A still can, so 11 is a policy working rather than an empty table.
select is(
  (select count(*) from storage.objects where bucket_id = 'avatars'),
  1::bigint,
  'a user can see their own avatar object'
);

select * from finish();
rollback;
