# Onboarding, sign-in & FTUX redesign — 2026-09-16

Plan: `keepo-onboarding-redesign-plan.md` (kept current; its §10 is the
decision record and §7 the stage-by-stage build order). **Zero migrations** —
every screen is client-only, on RPCs and payloads that already existed.

## What shipped

**Intro (before sign-in) — deleted 2026-09-18.** Manu's call: sign-in is the
first screen, `hasSeenIntro` is gone, and `.needsSignIn` renders `OTPSignInView`
directly. Recorded in §10.20 of the plan; kept below as what was built, not as
what is there. `WelcomeView` (welcome + problem merged),
`FeatureDeckView` — four slides, paged, **one** button reading "I'm in. Take
me to Keepo" that stays disabled until all four have been seen. `IntroFlowView`
routes on `AppSettingsKeys.hasSeenIntro`, set on *reaching* sign-in, so a
returning signed-out user is not marketed to twice. `OTPSignInView` revisualised
(48pt mark, visible resend countdown, "Open Mail", "Wrong address?").

**Setup — eight steps, one draft, one commit.**
`OnboardingDraft` + `OnboardingDraftStore` persist to `UserDefaults` on every
mutation; nothing reaches the server until step 7. `SetupFlowView` routes on
`draft.step`. Steps: profile → currency → account → capture (3 sub-steps) →
categories → dashboard → commit → all set.

**The commit** (`SetupCommitPlan` + `SetupCommitView`): avatar upload → profile
patch (the only hard stop) → outbox account → outbox categories → dashboard
arrangement → hand off to `SetupAllSetView`, which owns the `refreshProfile()`
that ends the flow.

**Capture setup** is the largest step: `NotificationPermission` (the app's only
`requestAuthorization` call site), `ShortcutsWalkthroughView` rendering
`ShortcutsWalkthrough` — shared with a rewritten `WalletAutomationGuideView` —
and an `x-callback-url` round trip whose local-only test capture never leaves
the device.

**FTUX.** One hand-rolled spotlight on the scope-banner swipe; everything else
is a TipKit tip on the view its lesson is about; `ShowMeAroundView` lists all
seven lessons on demand.

**Rating.** `ReviewPolicy` (pure) + `ReviewPrompter` + `ReviewPromptModifier`.
Armed at the write that resolves a capture, asked on a clean foreground beat.
Never in onboarding.

## The five decisions worth carrying forward

1. **`refreshProfile()` ends the flow and nothing follows it.** It flips
   `SessionStore.phase`, which tears the flow down — so anything sequenced
   after it races its own teardown. `SessionStore.completeOnboarding` (patch +
   immediate refresh) was **deleted** for this reason; the commit calls
   `ProfileRepository.completeOnboarding` directly.
2. **The capture test's containment is a query, not a promise.** The local-only
   test row is recognised everywhere by `CaptureIdentity.testCardIdentifier`,
   which `LocalMoneyQueries.needsReviewPendingCaptures` excludes, `TestCaptureQueries`
   finds, and `ReviewPrompter` skips. `card_identifier` being a real column is
   why the marker is a card rather than a magic merchant string.
3. **An all-empty `CaptureIntent` invocation is only the test inside a 60s
   window Keepo opened** (`CaptureTestSession`). Outside it, the same input is a
   Wallet automation with mis-spelled keys — a genuinely broken setup — and must
   be reported as one.
4. **The rating prompt is armed at the write, never by watching a count.** Two
   of the five capture-resolution call sites run backgrounded (notification quick
   actions), where no screen evaluates anything.
5. **Skip always means "accept the default", so two steps have none.**
   `.account` has no default to accept; `.currency` has nothing *but* one, which
   made its Skip identical to Next.

## Where the defects came from

**Almost every one was found by looking at the built screen, not by reading the
code** — and several were in *shared* components, surfaced only because eight
screens were finally seen in sequence:

- `OnboardingScaffold` truncated its own title, triggered by editing a
  *different* string on one step. Fixed with `fixedSize(vertical:)`.
- `.padding` applied **after** `.frame(maxWidth: .infinity)` makes a block wider
  than its container — the dashboard grid overhung the screen by exactly the inset.
- `LSApplicationQueriesSchemes` was missing entirely, so every `canOpenURL` gated
  button was invisible. Sign-in's "Open Mail" had never once appeared.
- An `@Observable` property read **only inside an `overlayPreferenceValue`
  builder** does not reliably register as a body dependency.
- Deleting `OnboardingView` silently removed the app's only notification
  permission ask, until stage 3 restored it.

## Owed

- **Real device:** the capture test's success path; a real Apple Pay purchase
  flipping `AppSettings.captureVerifiedAt`; the foreign tap-to-pay purchase owed
  from the capture-hygiene and multi-currency workstreams (`delete from
  merchant_category_map` against hosted first).
- **Manu:** four walkthrough clips (`App/Resources/Videos/RECORDING-NOTES.md` —
  the flow ships without them), and the launch screen.
- **`capture-shortcut` is deployed** (2026-09-16), so the dead-link risk is
  closed. Re-point with
  `supabase secrets set KEEPO_CAPTURE_SHORTCUT_URL=https://www.icloud.com/shortcuts/<new>`;
  anything outside that prefix is ignored in favour of the built-in default, so
  a typo cannot turn a public endpoint on Keepo's domain into an open redirect.
  **Nothing else is owed on the backend for this workstream — there were no
  migrations.**
- **`AppStoreListing.appID` is `nil`**, so the "Rate Keepo" row is hidden until
  Keepo exists in App Store Connect.
