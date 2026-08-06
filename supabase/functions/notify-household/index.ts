// notify-household — the no-op-transport seam for household lifecycle
// events (member joined/left/erased). Called by notify_household() (Phase
// 19) via ops_http_post exactly like sync-fx-rates/alert-operator; gated by
// an X-Notify-Household-Secret header, not a user JWT — the caller is a SQL
// function, not a signed-in user.
//
// Deliberately does nothing beyond logging and returning ok: the real APNs
// call is Phase 20's job (com.apple.developer.applesignin + push
// entitlements don't exist yet). Everything upstream of this function —
// household_events, the trigger point in accept_invite/leave_household/
// erase_own_account, the client's own polling read via
// HouseholdRepository.fetchEvents — is already fully wired, so swapping
// this file's body for a real push send is the only change Phase 20 needs.

Deno.serve(async (req) => {
  const expectedSecret = Deno.env.get("NOTIFY_HOUSEHOLD_SECRET");
  const providedSecret = req.headers.get("x-notify-household-secret");
  if (!expectedSecret || providedSecret !== expectedSecret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "content-type": "application/json" },
    });
  }

  const body = await req.json().catch(() => ({}));
  console.log("notify-household (no-op transport):", body?.event_id ?? "unknown event");

  return new Response(JSON.stringify({ sent: false, reason: "no-op transport" }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
