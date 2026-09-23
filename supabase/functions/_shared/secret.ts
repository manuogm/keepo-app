// Comparing a shared secret without leaking it one byte at a time.
//
// Finding 8 of the security audit of 2026-09-21. The three secret-gated
// functions — `alert-operator`, `notify-household`, `sync-fx-rates` — each
// compared with `!==`, which returns as soon as two bytes differ. That makes
// the comparison take measurably longer the more of the secret a caller has
// already guessed, which is a byte-at-a-time oracle rather than a 2^n search.
//
// Remotely, over HTTP, against a function with cold starts and network
// jitter, this is not a practical attack and the audit rated it Low. It is
// fixed because a constant-time compare costs nothing and because "not
// practical over today's transport" is not a property worth depending on.
//
// Three call sites is the point at which this stops being duplication worth
// tolerating (CLAUDE.md, Engineering Principles) — hence one function here
// rather than the same four lines pasted three times.

/// Whether `provided` matches `expected`, in time that does not depend on how
/// many leading bytes are equal.
///
/// **Fails closed.** A missing, empty or absent secret on either side is
/// never a match: an unconfigured function must reject every caller, not
/// accept the one who also sends nothing. That is the behaviour the three
/// call sites already had and it is preserved here rather than left to each
/// of them to remember.
///
/// Length is compared first and non-constant-time, which is what every
/// constant-time comparison does (Deno's and Node's `timingSafeEqual` both
/// require equal lengths). It reveals the length of the expected secret and
/// nothing about its content; for a 32-byte random secret that is not a
/// meaningful reduction in search space.
export function secretMatches(
  expected: string | undefined | null,
  provided: string | undefined | null,
): boolean {
  if (!expected || !provided) return false;

  const encoder = new TextEncoder();
  const a = encoder.encode(expected);
  const b = encoder.encode(provided);
  if (a.byteLength !== b.byteLength) return false;

  // No early exit: every byte is always examined.
  let difference = 0;
  for (let i = 0; i < a.byteLength; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}
