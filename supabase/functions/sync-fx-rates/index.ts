// sync-fx-rates — pulls EUR-pivoted rates from api.frankfurter.dev (NOT
// frankfurter.app, which 301-redirects) for every currency actually in use
// (accounts.currency ∪ profiles.base_currency), and upserts them via
// upsert_fx_rate(), which owns the "later fetched_at wins" rule. A 5-day
// trailing window means one missed run self-heals on the next.
//
// Gated by an X-Fx-Sync-Secret header, not a user JWT — the caller is a
// cron job (once wired), not a signed-in user (app-architecture.md §4).
// Deliberately NOT scheduled by pg_cron yet — see version-logs/phase-4-log.md
// for what's deferred and why.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

const FRANKFURTER_BASE = "https://api.frankfurter.dev/v1";
const WINDOW_DAYS = 5;

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

  const currencies = await currenciesInUse(supabase);
  if (currencies.length === 0) {
    return new Response(JSON.stringify({ ratesWritten: 0, currencies: [] }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  const { startDate, endDate } = window();
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

function window(): { startDate: string; endDate: string } {
  const end = new Date();
  const start = new Date(end);
  start.setDate(start.getDate() - (WINDOW_DAYS - 1));
  return { startDate: iso(start), endDate: iso(end) };
}

function iso(d: Date): string {
  return d.toISOString().slice(0, 10);
}
