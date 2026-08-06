// sync-fx-rates — pulls EUR-pivoted rates from api.frankfurter.dev (NOT
// frankfurter.app, which 301-redirects) for every currency actually in use
// (accounts.currency ∪ profiles.base_currency), and upserts them via
// upsert_fx_rate(), which owns the "later fetched_at wins" rule. A 5-day
// trailing window means one missed run self-heals on the next.
//
// Gated by an X-Fx-Sync-Secret header, not a user JWT — the caller is a
// cron job or the Phase 13 FX-backfill triggers, not a signed-in user
// (app-architecture.md §4). Scheduled daily by pg_cron as of Phase 13
// (`ops_http_post('fx_sync_url', 'fx_sync_secret', ...)`).
//
// Optional JSON body `{"days": N}` widens the window past the default 5 —
// the 400-day backfill triggers (accounts_backfill_fx_on_new_currency /
// profiles_backfill_fx_on_base_currency_change) call with `{"days": 400}`.
// This function still recomputes currencies-in-use itself rather than
// trusting a currency list in the body — by the time the trigger's caller
// fires, the new currency is already live in `accounts`/`profiles`, so the
// live query already includes it, and re-fetching a wider window for every
// other already-covered currency too is wasted work, never a correctness
// problem (`upsert_fx_rate`'s later-fetched_at-wins rule absorbs the
// overlap for free — this is what makes a repeated trigger idempotent).

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

const FRANKFURTER_BASE = "https://api.frankfurter.dev/v1";
const DEFAULT_WINDOW_DAYS = 5;

interface FrankfurterResponse {
  amount: number;
  base: string;
  start_date: string;
  end_date: string;
  rates: Record<string, Record<string, number>>;
}

Deno.serve(async (req) => {
  const expectedSecret = Deno.env.get("FX_SYNC_SECRET");
  const providedSecret = req.headers.get("x-fx-sync-secret");
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

  // Rate-limited via the same Phase 13 mechanism every Edge Function uses —
  // a forged or looping caller against this secret is still bounded.
  const { data: allowed, error: rateLimitError } = await supabase.rpc("ops_check_rate_limit", {
    p_function_name: "sync-fx-rates",
    p_max_calls: 20,
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

  const currencies = await currenciesInUse(supabase);
  if (currencies.length === 0) {
    return new Response(JSON.stringify({ ratesWritten: 0, currencies: [] }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const days = await windowDays(req);
  const { startDate, endDate } = window(days);
  const url = `${FRANKFURTER_BASE}/${startDate}..${endDate}?base=EUR&symbols=${currencies.join(",")}`;
  const res = await fetch(url);
  if (!res.ok) {
    return new Response(JSON.stringify({ error: `frankfurter.dev returned ${res.status}` }), {
      status: 502,
      headers: { "content-type": "application/json" },
    });
  }
  const body: FrankfurterResponse = await res.json();

  const fetchedAt = new Date().toISOString();
  const upserts: Promise<void>[] = [];
  let ratesWritten = 0;

  for (const [rateDate, ratesForDate] of Object.entries(body.rates)) {
    for (const currency of currencies) {
      const rate = ratesForDate[currency];
      if (rate === undefined) continue; // Frankfurter doesn't publish every currency every date.
      ratesWritten++;
      upserts.push(
        supabase.rpc("upsert_fx_rate", {
          p_currency: currency,
          p_rate_date: rateDate,
          p_rate_to_eur: rate,
          p_source: "ecb",
          p_fetched_at: fetchedAt,
        }).then(({ error }) => {
          if (error) throw error;
        }),
      );
    }
  }

  await Promise.all(upserts);

  return new Response(
    JSON.stringify({ ratesWritten, currencies, startDate, endDate }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
});

// Currencies actually in use: every non-deleted account's currency, plus
// every onboarded profile's base currency. Queried with the service-role
// key deliberately — this needs every user's currencies, not just one.
async function currenciesInUse(supabase: SupabaseClient): Promise<string[]> {
  const [{ data: accountCurrencies }, { data: baseCurrencies }] = await Promise.all([
    supabase.from("accounts").select("currency").is("deleted_at", null),
    supabase.from("profiles").select("base_currency").not("base_currency", "is", null),
  ]);

  const set = new Set<string>();
  for (const row of accountCurrencies ?? []) set.add(row.currency as string);
  for (const row of baseCurrencies ?? []) set.add(row.base_currency as string);
  set.delete("EUR"); // implicit rate of 1 — never fetched or stored.
  return [...set];
}

// A malformed or absent body is the ordinary case (the plain cron trigger
// sends no body at all) — falls back to the default window rather than
// failing the request.
async function windowDays(req: Request): Promise<number> {
  try {
    const body = await req.clone().json();
    const days = Number(body?.days);
    return Number.isFinite(days) && days > 0 ? days : DEFAULT_WINDOW_DAYS;
  } catch {
    return DEFAULT_WINDOW_DAYS;
  }
}

function window(days: number): { startDate: string; endDate: string } {
  const end = new Date();
  const start = new Date(end);
  start.setDate(start.getDate() - (days - 1));
  return { startDate: iso(start), endDate: iso(end) };
}

function iso(d: Date): string {
  return d.toISOString().slice(0, 10);
}
