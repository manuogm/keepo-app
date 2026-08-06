// alert-operator — the one place an unhealthy ops_health() check becomes a
// message a human actually sees. Called by ops_check_and_alert() (Phase 13,
// scheduled every 30 minutes via pg_cron), never by the app or any signed-in
// user.
//
// Gated by an X-Alert-Operator-Secret header, same pattern as sync-fx-rates
// (app-architecture.md §4) — the caller is a cron-triggered SQL function,
// not a user JWT.
//
// Deliberately dumb about the destination: forwards a plain text summary to
// whatever ALERT_WEBHOOK_URL points at (Slack/Discord/generic incoming
// webhooks all accept a bare `{"text": "..."}` POST). Swapping providers is
// an env var change, not a code change.

import { createClient } from "jsr:@supabase/supabase-js@2";

interface HealthCheck {
  check_name: string;
  healthy: boolean;
  detail: string;
}

Deno.serve(async (req) => {
  const expectedSecret = Deno.env.get("ALERT_OPERATOR_SECRET");
  const providedSecret = req.headers.get("x-alert-operator-secret");
  if (!expectedSecret || providedSecret !== expectedSecret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "content-type": "application/json" },
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Rate-limited independently of sync-fx-rates's own limit — a flapping
  // health check must not be able to spam the webhook every 30 minutes
  // forever without at least a visible ceiling.
  const { data: allowed, error: rateLimitError } = await supabase.rpc("ops_check_rate_limit", {
    p_function_name: "alert-operator",
    p_max_calls: 10,
    p_window_seconds: 3600,
  });
  if (rateLimitError) {
    return new Response(JSON.stringify({ error: rateLimitError.message }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
  if (!allowed) {
    return new Response(JSON.stringify({ error: "rate limit exceeded" }), {
      status: 429,
      headers: { "content-type": "application/json" },
    });
  }

  const webhookUrl = Deno.env.get("ALERT_WEBHOOK_URL");
  if (!webhookUrl) {
    return new Response(JSON.stringify({ error: "ALERT_WEBHOOK_URL not configured" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }

  const body = await req.json().catch(() => ({}));
  const checks: HealthCheck[] = Array.isArray(body?.checks) ? body.checks : [];
  const unhealthy = checks.filter((check) => !check.healthy);

  if (unhealthy.length === 0) {
    return new Response(JSON.stringify({ sent: false, reason: "all checks healthy" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const text = "Keepo ops alert:\n" +
    unhealthy.map((check) => `- ${check.check_name}: ${check.detail}`).join("\n");

  const res = await fetch(webhookUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text }),
  });

  return new Response(JSON.stringify({ sent: res.ok, webhookStatus: res.status }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
