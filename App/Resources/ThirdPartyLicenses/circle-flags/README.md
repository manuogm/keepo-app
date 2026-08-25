# circle-flags

The circular country flags used by `CurrencyBadge`, vendored into
`App/Resources/Flags.xcassets`.

| | |
|---|---|
| Source | https://github.com/HatScripts/circle-flags |
| Commit | `379588b5da95482d6bbf10bd45644a35b0609ea6` |
| Vendored | 2026-08-25 |
| Licence | MIT — see `LICENSE.md` beside this file |

## What was taken, and what wasn't

Only the **265 two-letter files** from the repo's `flags/` directory — the
ones named for an ISO 3166-1 alpha-2 region (`us.svg`, `gb.svg`, `eu.svg`, …).

That is not an arbitrary subset. A flag is reached here by
`CurrencyRegion.region(for:)`, which turns an ISO 4217 currency code into a
two-letter region; nothing else in the app can name a flag. The repo's other
~167 files are subdivisions (`gb-eng`), historical states (`soviet_union`) and
long-form aliases (`european_union`) that no currency code can resolve to, so
bundling them would ship artwork that is unreachable by construction.

The euro is the one case worth naming: `eu.svg` is a symlink to
`european_union.svg` in the repo, so the copy was made with `cp -L` and every
imageset holds a real file rather than a dangling link.

## Why all 265 rather than only the currencies we support

The supported currency set lives in Postgres (`currencies`, seeded by
`20260804184433_init_schema.sql`) and reaches the client by sync — the app has
no compile-time list of it. Bundling only today's 31 would mean a currency
added by a future migration silently degrading to the grey globe on a shipped
build. 265 flags is 159 KB of SVG; covering the whole alpha-2 space costs
almost nothing and removes that failure mode entirely.

## The one modification made to the artwork

Each vendored SVG has its root `width`/`height` changed from `512` to `48`.
The `viewBox` is untouched, so **the drawing itself is byte-for-byte the
upstream artwork** — only its intrinsic size changed.

This is not cosmetic. An asset catalogue rasterises 1x/2x/3x fallbacks from
the intrinsic size even when vector data is preserved, so at 512pt Xcode was
emitting a 1536px bitmap per flag and `Assets.car` came to **28 MB**. At 48pt
it is **1.6 MB**, and the preserved vector data still renders the badge
crisply at any diameter. MIT permits modification; it is recorded here so the
next person doesn't mistake the diff against upstream for corruption.

## Refreshing

Re-run the vendoring against a newer commit, then update the SHA above:

```bash
git clone --depth 1 https://github.com/HatScripts/circle-flags.git /tmp/circle-flags
```

Copy each `^[a-z]{2}\.svg$` file into `App/Resources/Flags.xcassets/flag-<region>.imageset/`
with `cp -L`, alongside a `Contents.json` that sets
`"preserves-vector-representation": true` — the flags are drawn at several
diameters (18–24pt today) and must stay vector rather than being rasterised at
the SVG's 512pt intrinsic size.

## Compliance

MIT requires the copyright and permission notice to travel with "all copies or
substantial portions of the Software". `LICENSE.md` sits in the app's
`Resources` group, so it is copied into `Keepo.app` and ships with every build
rather than only living in the repository. `ThirdPartyLicensesTests` fails the
build if it ever stops being bundled.
