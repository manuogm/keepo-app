// capture-shortcut — a 302 to wherever the "Keepo Capture" shortcut is
// published, so the destination can be re-pointed without an App Store
// release.
//
// **Why this exists at all.** The iCloud share link is the one part of
// onboarding that can break with no code changing: an iCloud shortcut link
// dies if it is ever revoked or re-shared, and a hardcoded one would leave
// every new user's capture setup dead until App Review cleared a fix —
// days, for a one-line string. Fronting it with a redirect turns that into
// a `supabase secrets set`.
//
// **Deliberately public.** `verify_jwt = false` in config.toml: the user
// taps this from the capture step, and while they are signed in by then,
// the link also has to survive being opened from Safari, from a support
// email, or from a device where the session has lapsed. There is nothing
// here to protect — the destination is a public share link, and the app
// ships it as a fallback anyway.
//
// **Redirect, not a JSON body.** iOS has to follow this into the Shortcuts
// app, which means the browser/`UIApplication.open` chain must see a real
// 302 to an `icloud.com/shortcuts/...` URL. Returning the URL for the app
// to open itself would work, but only for the app — and the whole point is
// that the link is also shareable.

// The link as published on 2026-09-16, and the value the app already ships
// as its offline fallback. Kept here as the default so this function is
// correct the moment it is deployed, with no secret set — the env var is
// how it gets *changed*, not how it gets started.
const FALLBACK_SHORTCUT_URL =
  "https://www.icloud.com/shortcuts/67d23227435a43a4926d9b22d1bb5065";

// Only iCloud shortcut links are ever served. A mistyped secret should fail
// closed onto the known-good link rather than redirect users somewhere
// arbitrary — this endpoint is public and reachable by anyone, so an
// open redirect here would be a phishing primitive with Keepo's domain on it.
const ALLOWED_PREFIX = "https://www.icloud.com/shortcuts/";

function resolveDestination(): string {
  const configured = Deno.env.get("KEEPO_CAPTURE_SHORTCUT_URL")?.trim();
  if (!configured || !configured.startsWith(ALLOWED_PREFIX)) {
    return FALLBACK_SHORTCUT_URL;
  }
  return configured;
}

// The signed `.shortcut` file behind an iCloud share link, resolved through
// the same record API the icloud.com page itself calls.
//
// **This is the undocumented half of this function and it is allowed to
// fail.** Apple publishes no supported way to install a shared shortcut
// without the user landing on the icloud.com page and pressing "Get
// Shortcut" — so the app's one-tap path asks here first, and drops to the
// 302 above the instant anything about this is not exactly as expected.
// Nothing downstream treats a null as an error: it is the normal answer on
// the day Apple changes the shape of this response.
async function resolveDownloadURL(shareURL: string): Promise<string | null> {
  const id = shareURL.slice(ALLOWED_PREFIX.length).split(/[/?#]/)[0];
  if (!/^[0-9a-f]{16,64}$/i.test(id)) return null;

  try {
    const response = await fetch(`${ALLOWED_PREFIX}api/records/${id}`, {
      signal: AbortSignal.timeout(4000),
    });
    if (!response.ok) return null;
    const record = await response.json();
    const download = record?.fields?.shortcut?.value?.downloadURL;
    // Must be an Apple-hosted https URL. This value is handed to the client
    // to open with the `shortcuts://import-shortcut` scheme, so anything
    // that is not plainly Apple's own CDN is refused rather than passed on.
    if (typeof download !== "string") return null;
    const parsed = new URL(download);
    if (parsed.protocol !== "https:" || !parsed.hostname.endsWith(".apple.com")) return null;
    return download;
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response(null, { status: 405, headers: { allow: "GET, HEAD" } });
  }

  // `?format=json` is the app's one-tap path: it wants the file, not the
  // page. Everything else — a browser, a QR code, a pasted link — keeps
  // getting the redirect it always got.
  if (new URL(req.url).searchParams.get("format") === "json") {
    const destination = resolveDestination();
    const download = await resolveDownloadURL(destination);
    return new Response(
      JSON.stringify({ downloadURL: download, shareURL: destination }),
      {
        status: 200,
        headers: {
          "content-type": "application/json",
          // Shorter than the redirect's: this one carries a signed URL,
          // and a signature outliving its cache entry is the failure that
          // would be hardest to reproduce.
          "cache-control": "public, max-age=60",
        },
      },
    );
  }

  return new Response(null, {
    // 302, not 301: a permanent redirect is cached by clients and
    // intermediaries indefinitely, which would re-create the exact problem
    // this function exists to solve — a stale destination nobody can change.
    status: 302,
    headers: {
      location: resolveDestination(),
      // Short enough that a re-point takes effect within minutes, long
      // enough that the endpoint is not hit on every render of the
      // walkthrough.
      "cache-control": "public, max-age=300",
    },
  });
});
