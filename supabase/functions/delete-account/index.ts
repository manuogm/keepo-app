// delete-account — the one thing account deletion cannot do in SQL.
//
// `delete_own_account()` (migration 20260911100000) destroys every row the
// user owns, in one transaction, forking a household first so the other
// member keeps their history. What it deliberately does *not* do is delete
// the `auth.users` row: that belongs to GoTrue, and reaching into the `auth`
// schema from a migration means betting that every future release keeps each
// child table's cascade intact. `auth.admin.deleteUser` is the API the
// platform maintains for exactly this, and it needs the service-role key —
// which is why this function exists at all.
//
// **Identity comes from the caller's JWT and nowhere else.** There is no user
// id in the body, no id in a query parameter, nothing a client could put
// there. `getUser()` on the caller's own token is the only source, and the
// RPC underneath re-derives it independently from `auth.uid()` — so even a
// bug here cannot aim the deletion at somebody else.
//
// Unlike its three siblings this one runs with `verify_jwt = true` (config.toml):
// the caller is a signed-in user, not a SQL function holding a shared secret.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const authorization = req.headers.get("Authorization");
  if (!authorization) {
    return json({ error: "missing authorization" }, 401);
  }

  // The caller's own client: every statement it runs is that user, so the
  // RPC's `auth.uid()` resolves to them and to nobody else.
  const asUser = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });

  const { data: userData, error: userError } = await asUser.auth.getUser();
  const user = userData?.user;
  if (userError || !user) {
    return json({ error: "invalid session" }, 401);
  }

  // Read before the RPC destroys the row that names it. The object itself
  // lives in storage, which has no foreign key to `auth.users` and so would
  // otherwise have kept a photo of the user's face after everything else
  // about them was gone.
  const { data: profile } = await asUser
    .from("profiles")
    .select("avatar_path")
    .eq("id", user.id)
    .maybeSingle();
  const avatarPath: string | null = profile?.avatar_path ?? null;

  // Step 1 — every row, in one transaction. If this fails nothing has been
  // destroyed and the user still has an account they can try again with.
  const { error: rpcError } = await asUser.rpc("delete_own_account");
  if (rpcError) {
    console.error("delete-account: delete_own_account failed", rpcError.message);
    return json({ error: "deletion failed", detail: rpcError.message }, 400);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // Step 2 — the avatar. Best effort and deliberately not fatal: the rows are
  // already gone, and failing the whole request over one orphaned object
  // would leave the user staring at an error for a deletion that in every
  // way that matters succeeded. Logged so it can be swept.
  if (avatarPath) {
    const { error: storageError } = await admin.storage.from("avatars").remove([avatarPath]);
    if (storageError) {
      console.error("delete-account: orphaned avatar object", avatarPath, storageError.message);
    }
  }

  // Step 3 — the identity. Last, because until it is gone the two steps above
  // can still be retried by the same signed-in user; after it, they cannot.
  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) {
    console.error("delete-account: auth delete failed", deleteError.message);
    return json({ error: "identity deletion failed", detail: deleteError.message }, 500);
  }

  return json({ deleted: true }, 200);
});
