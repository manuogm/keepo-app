# Keepo — Onboarding, Sign-In & FTUX Redesign

> **Status:** proposal, pending Manu's decisions in §3. Nothing here is built.
> **Scope:** replaces `App/Features/Onboarding/OnboardingView.swift` (267 lines, 5 steps) and reworks `App/Features/Auth/OTPSignInView.swift`; adds a first-time-user-experience layer inside the signed-in app. **Zero migrations** — every screen below is client-only, built on RPCs, payloads and views that already exist.
> **Read with:** `keepo-brand-identity.md` (§1 colour, §3 Dynamic Type, §4 geometry/motion, §7 haptics), `CLAUDE.md` (Engineering Principles — *reuse before writing*), `version-logs/lessons-learned.md`.

---

## 1. What exists today

The single most important fact about this work: **almost every screen Manu described already exists somewhere in the app in a better form than onboarding's current version.** The job is mostly composition, not construction.

| The new flow needs | Already in the repo | Where |
|---|---|---|
| Two-card Everyday/Investment chooser | `AccountKindPicker` — already deliberately shared between the Add Account sheet and onboarding | `App/Features/Accounts/AddAccountFlowView.swift:62` |
| Currency wheel with flags + symbols | `BaseCurrencySheet` (the wheel) + `CurrencyBadge` (flag + code row) | `App/Features/Profile/ProfileMetricCard.swift:99`, `.../Widgets/Kit/CurrencyBadge.swift` |
| Big avatar + camera affordance + picker | `ProfileAvatarView` + the camera overlay in `ProfileView.identity` + `avatarPicker` modifier + `AvatarStore` | `App/Features/Profile/ProfileView.swift:114`, `AvatarPicker.swift`, `App/Services/AvatarStore.swift` |
| Editable name field | `ProfileView`'s `draftName` `TextField` (commits on blur and on submit) | `App/Features/Profile/ProfileView.swift:152` |
| Icon + colour picker for an account | `IconPickerButton` + `IconCatalogView` | `App/Common/Components/FormPrimitives.swift:42`, `IconCatalogView.swift` |
| Amount entry in the base currency | `AmountField` + `AmountParser` / `AmountFormatter` | `App/Common/Components/AmountField.swift`, `KeepoCore` |
| Credit-card face + card-name editor | `CreditCardFace`, `MappedCardSheet` (card over a translucent curtain), `LinkedCardsHelpSheet` | `App/Features/Accounts/` |
| Shortcuts setup instructions | `WalletAutomationGuideView` — six numbered steps, already the single source of that copy | `App/Features/Profile/Automations/WalletAutomationGuideView.swift` |
| Notification permission ask (once, guarded) | `OnboardingView.requestNotificationAuthorizationIfNeeded()` — only asks when status is `.notDetermined` | `App/Features/Onboarding/OnboardingView.swift:252` |
| Category tile (icon + colour + name) | `CategoryTile` — **currently `private`**, must be extracted | `App/Features/Categories/CategoriesView.swift:238` |
| Widget pills with real previews + "why you can't add this" reasons | `DashboardCatalogView` renders every entry as the **real widget against `DashboardData.sample`** | `App/Features/Home/Dashboard/DashboardCatalogView.swift` |
| Ordered widget placement | `DashboardStore.append(kind:)` places at the first free slot in reading order — an ordered list of kinds committed in order *is* the hierarchy | `App/Features/Home/Dashboard/DashboardStore.swift:73` |
| Translucent black curtain | `MappedCardSheet`'s `.ultraThinMaterial` + `Color.black.opacity(AppTheme.Opacity.fill)` over `.presentationBackground(.clear)` | `App/Features/Accounts/MappedCardSheet.swift:52` |
| Simulated capture (debug) | `SimulateCaptureView` — calls the exact `Outbox.submitCaptureTransaction` path `CaptureIntent` does | `App/Debug/SimulateCaptureView.swift` |
| Swipe-with-resistance carousel vocabulary | `ScopeBannerView`'s hand-rolled `DragGesture` (resistance, point of no return, deck tilt) | `App/Common/Components/Scope/ScopeBannerView.swift` |

**What genuinely does not exist:** the intro/marketing screens, a progress indicator, a delayed Skip control, persisted onboarding state, video playback, a default-category catalogue, a review prompter, and any coach-mark / FTUX infrastructure.

### Constraints the flow has to obey

1. **`profiles` has a CHECK: `onboarded_requires_base_currency`** (`20260804184433_init_schema.sql:104`). `onboarded_at` cannot be written without a `base_currency`. `ProfileRepository.completeOnboarding` therefore writes base currency + display name + `onboarded_at` in **one patch**, on purpose. **Base currency is the one step that cannot silently be skipped.**
2. **`ProfileRepository.completeOnboarding` / `updateDisplayName` / `updateAvatarPath` are online-only, deliberately** (`Repositories.swift:35`) — the app reads `session.profile` from the server, not the local mirror. Accounts, categories and card mappings go through the **outbox** and are local-first. Two different write paths in one flow; the commit step has to know that.
3. **Sign in with Apple does not exist yet.** The app is magic-link OTP only (`OTPSignInView` → `SessionStore.sendOTP` → `handleMagicLink`). SIWA is Phase 20 of `keepo-v1-master-plan.md`, gated on the paid Apple Developer membership. **There is no Apple or Google name to derive from today.**
4. **On the local dev stack `StubAuthProvider` auto-signs-in** (`SessionStore.start()`), so the sign-in screen is unreachable locally. Exercising it needs the hosted config or a DEBUG override.
5. **Fresh-signup testing needs `xcrun simctl erase`**, not uninstall — the Keychain survives uninstall and a stale session against a wiped `auth.users` surfaces as `PGRST116` (master plan, Verification §4).
6. There are **six** dashboard widget kinds, not seven (see §3.9).
7. **`capture_transaction` unconditionally upserts a `card_mappings` placeholder** for every identifier it sees ([`20260822100000:138`](supabase/migrations/20260822100000_unmapped_capture_lands_locally.sql)), and `needs_review`'s `ambiguous_card` branch reads exactly those placeholders — suppressed only *while* a matching `pending_capture` exists. The client's `CaptureLocalWrite` deliberately does **not** create the placeholder ([`CaptureLocalWrite.swift:30`](App/Data/LocalStore/CaptureLocalWrite.swift)). Any capture that reaches the server therefore eventually demands a card mapping. This is what forces §3.8's test capture to stay device-local.

---

## 2. What is good about the vision, and should not be watered down

Worth stating so it does not get optimised away during the build:

- **Value before the sign-in wall** is the right call, and rarer than it should be in finance apps. Keep it.
- **"We show you what it does first and then you decide"** is a promise the rest of the flow has to keep. It is the reason §3.3 (accuracy of the capture claim) matters more than it looks.
- **Personalising *before* the first launch** — name, currency, account, categories, dashboard — means the app is never empty on day one. That is genuinely differentiating and it is the whole argument for a long setup.
- **Ending inside a dashboard the user configured themselves** is the correct payoff screen. Do not replace it with a generic "done".

---

## 3. Challenges to the vision — decisions needed

Each item: the concern, the recommendation, and what changes if Manu disagrees. **Nothing gets built until these are answered.**

### 3.1 Fifteen screens before the app — trim the intro, not the setup

As briefed: welcome + problem + 4 features + sign-in + 9 setup = **15 screens**. (Now 13 — §3.7 cut one setup screen and this section merges two intro screens.) The setup half earns its length (every step produces something the user sees on day one). The intro half does not: it is six screens of reading before anything happens.

**Recommendation:**
- Fold the **Welcome** line and the **Problem statement** into **one** screen. "Welcome to Keepo / Where ALL your money is kept under control" is a headline; "tired of apps that don't meet your needs?" is its subhead. As two screens the first one says nothing.
- Make the **4 feature screens a swipeable paged deck** with page dots, not four separate pushes. The button still advances (so the escalating copy survives), but a user who has understood it can flick through in two seconds and a user who wants to re-read can swipe back. `ScopeBannerView`'s carousel already establishes this gesture vocabulary in the app.
- Net: **6 intro screens → 5, one of them skimmable in a flick.**

*If Manu disagrees:* keep 6 discrete screens; cost is roughly zero extra code, the deck is the cheaper option either way.

### 3.2 The escalating button copy contradicts "minimize unnecessary texts"

"Great start, What is next?" / "Wow, show me more!" / "Very cool, is there more?" put words in the user's mouth. For an app whose voice everywhere else is factual and dry (read any doc comment in this codebase), three consecutive enthusiastic self-congratulations read as a different product than the one they are introducing — and they are the longest strings on their screens.

**Recommendation:** keep **one** personality moment, the last: **"I'm in. Take me to Keepo."** That one lands because the user has actually decided something. Make the other three plain — `Next`, or better, nothing at all if the deck is swipeable and a single "Continue" sits under the dots.

*If Manu disagrees:* they are string constants; keeping them costs nothing but the tone risk above.

### 3.3 Feature 2 overstates what Keepo does — and it's the one claim the problem statement forbids

> "Keepo detects each tap-payment done with your phone using Apple Pay and automatically logs it"

Keepo detects nothing. **iOS Shortcuts** detects it, and only after the user has hand-built a Wallet automation (`WalletAutomationGuideView`'s six steps), only for the cards they explicitly picked, only on that device, and never for closed-loop apps like Walmart Pay. Screen 5 of setup is a multi-video walkthrough precisely because this is manual.

Promising "automatic" on screen 4 and then handing over a Shortcuts tutorial ten screens later is exactly the "tried so many apps, they don't meet my needs" experience the problem statement opens by condemning. It is also the single most likely source of one-star reviews.

**DECIDED (Manu, 2026-09-15).** Keep the feature as the headline, move the verb:

> **Automatic capturing**
> Logging every transaction by hand is a pain.
> **Set up Keepo to detect each tap-payment** made with your phone and log it for you.
> Pick the account or fix the category straight from the notification.

"Set up Keepo to…" makes the setup read as part of the product rather than a tax, and it pre-sells the work on the capture step instead of ambushing the user with it. With §3.8's prebuilt shortcut the setup really is short, so the claim stays cheap to keep.

*Also:* "finantial" → "financial" in Feature 1.

**This is the one item I'd push back on twice.** Everything else here is taste.

### 3.4 "Your money and your data is ALL YOURS" — make it precise, keep it strong

The claim is *substantially* true and the underlying architecture backs it (no bank linking, private Supabase with RLS on every table, private avatar bucket, no third-party analytics). But data does sit on a hosted Supabase project, so an unqualified "all yours" invites a fair "then why is it on a server?"

**Recommendation** — say the specific true things, which are more convincing than the general claim:

> **Privacy first**
> No bank logins. Keepo never connects to your bank.
> Your data is never sold, and never used to train AI.
> Encrypted in transit and at rest, readable only by you.

Three checkable facts beat one unfalsifiable one, and it stays defensible if anyone ever asks.

### 3.5 Sign-in: the name cannot be derived today, and the flow requires leaving the app

Two separate problems with "derive his name from the shared apple/google data or email provided":

**(a) There is no Apple or Google identity yet.** Magic-link OTP is all there is; SIWA is Phase 20 and needs the paid membership. The only thing available today is the email local part — and the current code has an explicit, correct comment refusing to use it:

> *"the app knows the user's email address and could split a name out of the local part, but `fam.samper.ona` is not what anyone calls themselves, and a wrong name is worse than no name."*

**Recommendation:** build the seam now, fill it conservatively.
- `KeepoCore/DisplayNameSuggestion.swift` — pure, unit-tested: takes an optional `PersonNameComponents` (SIWA, when it exists) and an email; returns a suggestion or `nil`. It returns `nil` when the local part contains digits, is under 3 characters, or has 3+ dot/underscore segments (i.e. `fam.samper.ona` → `nil`, `manu` → `Manu`, `manu.ogm` → `Manu`).
- The field is **prefilled and editable**, never silently accepted. If the suggestion is `nil`, the placeholder is "Add your name" — the same invitation `ProfileView` already uses.
- When Phase 20 lands, SIWA's `fullName` (given only on the *first* authorization — it must be captured then or never) flows into the same function. One line changes.

**(b) Magic link forces the user out of the app mid-flow.** They tap "Send link", switch to Mail, tap the link, iOS re-opens Keepo through `RootView.onOpenURL`. It works, but it is the highest-attrition moment in the entire flow and it sits immediately after the four screens that just built enthusiasm.

**Recommendation:** ship the flow as designed, but treat **SIWA as the single highest-value unblock for this work**. One tap, no app switch, and it is the only thing that makes the "derive their name" idea real. If the membership is close, consider landing Phase 20's `AppleAuthProvider` *before* this redesign ships. In the meantime, polish the waiting state: show the email, a "wrong address?" escape, a resend with a visible cooldown, and open-mail-app assistance.

**(c) Visual** — `AppTheme.Typography.Number.hero` (48pt) is documented as *"the sign-in screen's mark"* and the sign-in screen does not use it. Fixing that is the whole visual brief: hero mark, the tagline, the field, one button, on `bgCanvas`.

### 3.6 The delayed "Skip" — and the one step that cannot have one

A Skip that fades in after a delay is fine (Apple will not reject it; 2.5–3s is the right number — long enough to discourage reflex-skipping, short enough not to feel like a hostage situation).

**But base currency cannot be skipped into nothing** — the DB CHECK forbids `onboarded_at` without it.

**Recommendation:** every step's Skip is honest about what it does, and **Skip never means "no value"**, it means "accept the sensible default":
| Step | Skip means |
|---|---|
| 1 Profile | No name, no photo. Both editable forever in Profile. |
| 2 Currency | ~~Accept the pre-selected default~~ — **no Skip (Manu, 2026-09-16)**. The default is still derived from `Locale.current.currency` when it is in the ECB set, else `USD`, and the wheel sits on it — but Next already *is* that answer, so a Skip beside it was the same act offered twice. See decision 6. |
| 3 First account | No account. Dashboard shows its existing blank state; Accounts tab has its own Add flow. |
| 4 Card mapping | No mapping. The first real purchase lands in Needs Review carrying the exact card identifier — one tap to map, and *more reliable* than typing it (see §3.7). |
| 5 Capture setup | Not set up. Lives in Profile → My Automations, unchanged. |
| 6 Categories | Just the two `Other` rows the backend already seeds at signup. |
| 7 Dashboard | `DashboardStore.seed` — Net Worth alone. |

Also: **derive the currency default from the device locale** rather than the current hardcoded `"USD"`. Small change, disproportionate first impression for a multi-currency app.

### 3.7 Screen 4 (card mapping) — **CUT (Manu, 2026-09-15)**

`map_card` keys on a `card_identifier` **string** that must match, exactly, whatever the Wallet automation passes as its Card variable. A typo, a different capitalisation, "Visa" vs "Visa •••• 1234" — the mapping silently never matches and every purchase lands in Needs Review forever with no error saying why.

§3.8's prebuilt shortcut made this worse, not better: the identifier now arrives automatically from the Transaction's `Card` field, so **the user cannot know in advance what string it will be** — they would be typing a guess.

Meanwhile the reliable path already exists: an unmapped capture arrives in Needs Review **carrying the exact identifier**, and `MapCardSheet` maps it in one tap with zero typing.

**Decision: the screen is cut entirely.** One screen shorter, one class of silent failure gone, and strictly more reliable. Setup drops from nine screens to eight, renumbered throughout this document. `CreditCardFace` / `MappedCardSheet` / `LinkedCardsHelpSheet` are untouched and keep doing this job from the Accounts screen and Needs Review, where the identifier is known.

### 3.8 The test button — there IS a real test, but only if the setup is restructured

**RESEARCHED 2026-09-15**, after Manu reported seeing a working version of this in a shipped App Store app.

**What is genuinely impossible, confirmed:** there is no public iOS API to enumerate, inspect, or run a *personal automation*. `shortcuts://create-automation` opens the creation UI and reads nothing back. So no button can ever verify the automation object itself.

**What is possible, and was the missing piece:** Apple documents [x-callback-url support in Shortcuts](https://support.apple.com/guide/shortcuts/use-x-callback-url-apdcd7f20a6f/ios). An app can run a **named shortcut in My Shortcuts** and receive a callback:

```
shortcuts://x-callback-url/run-shortcut?name=Keepo%20Capture
  &x-success=com.manuogm.keepo://capture-test-ok
  &x-error=com.manuogm.keepo://capture-test-failed
```

`x-success` carries a `result` parameter with the shortcut's output; `x-error` carries `errorMessage`. That is a **real cross-process round trip**, not an in-app simulation — a hard yes/no Keepo can act on.

**Why the comparable apps cannot do this properly.** [TravelSpend](https://help.travel-spend.com/shortcuts--automation/ignQHsp85RQDsig2QwVcdX/set-up-apple-pay-automation/7tL8XfjBceg4D7mQeiSK2V) and [WalletPal](https://walletpalapp.github.io/apple-pay-expense-tracker-shortcuts.html) both wire the Wallet automation to the **app action directly** — there is no named shortcut to call. WalletPal advertises an "in-app setup test"; with that architecture it can only be the in-process fake this section originally warned about.

#### The restructure: ship the shortcut, don't make them build it

**Publish a prebuilt "Keepo Capture" shortcut as an iCloud link** (`https://www.icloud.com/shortcuts/<id>`). One tap to add — since iOS 15 there is no "Allow Untrusted Shortcuts" gate, just a preview screen listing the actions. It arrives with `Log Apple Pay Purchase` already wired to Shortcut Input.

Three things improve at once:

1. **The automation collapses to four taps** — New Automation → Wallet → pick cards → Run Immediately → Run Shortcut "Keepo Capture". **Zero variable mapping.** Every fiddly Card/Merchant/Amount binding now lives inside the shortcut Keepo shipped, where a user cannot mis-wire it. The §4.3 video walkthrough drops from six steps to roughly three.
2. **The test button becomes truthful.** It runs the shortcut with **no input**; the shortcut's own `If Shortcut Input has any value` / `Otherwise` branch supplies fixed test values. Genuinely verified: the shortcut exists under the expected name, it contains Keepo's action, the intent is registered, **the Shortcuts host process can read the Keychain session** (`CaptureIntent`'s own header records that a wrong client "was the root cause of every capture failing outright"), the outbox write lands, and the notification fires with its quick actions.
3. **The unverifiable surface shrinks** from "the entire setup" to "did you tick the right cards". That half is covered asynchronously by the first-real-capture flip below.

#### What the test may and may not claim

| Verified by the test button | Not verified — needs a real purchase |
|---|---|
| Shortcut exists, named correctly | The Wallet automation exists at all |
| It contains `Log Apple Pay Purchase`, parameter-mapped | Which cards it is bound to |
| Intent registered and invocable cross-process | "Run Immediately" actually set |
| Keychain session readable from the Shortcuts host | |
| Capture write lands in the outbox | |
| Notification delivered, quick actions attached | |

So the copy is: **"Keepo received a test purchase ✓ — we'll confirm your automation the moment your first Apple Pay tap lands."** Both halves true.

#### Remaining design detail, to settle during the build

The test creates a **real** pending capture in a brand-new ledger. Two options:
- **(recommended)** Let it land, and end the step on *"Here it is — keep it or delete it."* It demonstrates Needs Review and the quick actions instead of merely asserting success.
- Reserve a `KEEPO-TEST` card identifier the intent recognises and routes to a preview notification without writing. Cleaner ledger, weaker test.

#### Still worth shipping alongside

- **`AppShortcutsProvider`** so Keepo's action is discoverable in Shortcuts/Spotlight/Siri without hunting the Apps tab.
- **`captureVerifiedAt`**, set on the first arriving capture, surfaced in Profile → My Automations as "Waiting for your first purchase" → "Working ✓ — last capture 2h ago", with a one-off congratulation notification when it flips. This is also §3.10's trigger.
- **"Preview the notification"** — an honest demo of what a capture looks like, and the payoff for the permission granted two steps earlier.

**Dependency this adds:** Manu must build and publish the "Keepo Capture" shortcut once, and keep its iCloud link alive. **Put the link behind a redirect Manu controls** — a Supabase Edge Function returning a 302 — so the shortcut can be re-published without shipping an app update; a dead hardcoded link would break onboarding for every new user until App Review cleared a fix. A text fallback ("add the action by hand") sits behind a failed import either way.

#### DECIDED (Manu, 2026-09-15): ship it, and the test capture never leaves the device

**Option 1 chosen.** `CaptureIntent` recognises a reserved card identifier and writes to the **local mirror only**, skipping the outbox push. Rationale, and the pipeline finding that forced the choice:

> **`capture_transaction` unconditionally upserts a `card_mappings` placeholder** for any identifier it sees ([`20260822100000_unmapped_capture_lands_locally.sql:138`](supabase/migrations/20260822100000_unmapped_capture_lands_locally.sql)). That placeholder is exactly what `needs_review`'s `ambiguous_card` branch reads, and the view suppresses it only *while* a matching `pending_capture` exists. So a server-bound test capture would show as a pending capture, and then — **the moment the user deleted it, as instructed** — resurface as "Unmapped card — Keepo Test Card" asking them to map fake data to a real account. The delete would appear to cause it.
>
> The client's own fast path already gets this right: `CaptureLocalWrite` **deliberately never creates the placeholder** ([`CaptureLocalWrite.swift:30`](App/Data/LocalStore/CaptureLocalWrite.swift)). Only the server function does.

Staying local closes that, and three more things, without a single migration:

- Fake merchant and card data **never reach Supabase at all** — the strongest reading of "treat it as an exception".
- No `card_mappings` placeholder, so no `ambiguous_card` item, ever.
- It never enters Needs Review, so it cannot pollute §3.10's "first inbox clear" rating trigger — which deleting it otherwise would have fired, *during onboarding*, which is precisely where §3.10 moved the ask away from.
- No merchant learning: `resolve_category_for_merchant` never sees the fake merchant.

**What this gives up:** the server round-trip is not exercised. Acceptable — that mechanism is proven by every other write in the app, and it is not what this test is for. Everything the test *is* for is still covered: cross-process invocation from the Shortcuts host, Keychain session readable there, the local write landing, the notification with its quick actions.

*(Option 2 — full round trip — was costed and rejected: one migration guarding `capture_transaction`'s placeholder upsert, both `needs_review` branches, and the merchant-learning path. More surface area, and it would break this plan's zero-migration property.)*

**The user always deletes it, and is always able to.** Per Manu: never auto-deleted. The onboarding success step shows the captured test purchase with **Delete** as its primary action, and a persistent "Delete test purchase" affordance lives in **Profile → My Automations** for as long as one exists — so backgrounding the app mid-flow cannot strand it invisibly.

#### PROBE RESULT (real device, 2026-09-15) — the design is confirmed, and it found two defects

A Wallet automation passing `Shortcut Input` into a child shortcut **does** deliver an addressable dictionary. Real captured values:

```
Card or Pass : Revolut Mastercad
Merchant     : SQ * Equity Park,Llc
Amount       : $1.06
```

So the keys are `Merchant`, `Amount`, `Card or Pass`; all three arrive populated; and Amount is a **formatted currency string**, which is the shape `AmountParser.parseFormattedCurrency` was written for.

**The shortcut is therefore one action, not four.** `Log Apple Pay Purchase` with its three fields mapped inline to those dictionary keys. No `Get Dictionary Value` actions, no `If / Otherwise`, no JSON. The earlier four-action sketch in this section was over-engineering; one action is also the most legible thing to show on the import preview screen.

**The test button is handled entirely in Swift.** The shortcut's own header carries *"If there's no input: Continue"*, so Keepo's `x-callback-url` launch reaches `CaptureIntent` with all three fields empty. `CaptureIntent` treats an all-empty invocation as the onboarding test **only while a short "expecting a test" window is open** (set by the test button seconds earlier) and writes the local-only test capture with canned values; outside that window an all-empty invocation is a broken setup and must be reported as one. Without the window guard, mis-spelled keys would make a genuinely broken automation report itself as working.

**Incidental confirmation that §3.7 was right:** `Card or Pass` is the user's own Wallet label — here, `Revolut Mastercad`, complete with its typo. A user asked to type that in onboarding would have typed `Revolut Mastercard` and the mapping would have silently never matched, forever.

#### Two pre-existing defects this probe exposed — both now their own workstreams

Neither is introduced by this work; both are **live in the shipped capture path** and were found by running the real strings through the real code.

**Both were fixed on 2026-09-15** as workstream 1, capture hygiene — see `version-logs/capture-hygiene-2026-09-15-log.md`. The descriptions below are kept as the record of what was wrong and why; the separator half of the Stage-3 blocker is closed, the symbol half belongs to the multi-currency workstream.

**1. `AmountParser.parseFormattedCurrency` is locale-coupled — a 100x money error. Blocked Stage 3; ✅ fixed 2026-09-15.** It strips every character except digits, minus, and **the device locale's** decimal separator, then parses. But the Wallet string's convention is not the device's. Measured:

| Amount string | `en_US` device | `es_ES` / `de_DE` device |
|---|---|---|
| `$1.06` | 1.06 OK | **106** WRONG |
| `1,06 EUR` | **106** WRONG | 1.06 OK |
| `1.234,56 EUR` | **1.23456** WRONG | 1234.56 OK |

A Spaniard with a USD card, or an American with a EUR card, captures every purchase at 100x or 1/1000x. For an app whose pitch is multi-currency this is not an edge case, and it is exactly the class CLAUDE.md's money rules exist to prevent. **Root-cause fix:** infer the separator from the string itself, never from `Locale.current` — both separators present means the rightmost is decimal; one separator appearing more than once is grouping; one separator followed by exactly three digits is grouping (correct for JPY too); one followed by one or two digits is decimal. Deterministic, `KeepoCore`, unit-tested against a matrix. The existing rule that the **symbol is never used to infer currency** (app-architecture.md §4) stands — only the separator is inferred.

**2. `MerchantNormalizer` misses comma-separated corporate suffixes. ✅ fixed 2026-09-15.** `corporateSuffixes` matches only space-separated forms, so Square's real output splits one merchant into three learning keys:

```
SQ * Equity Park,Llc   ->  EQUITY PARK,LLC
SQ *EQUITY PARK LLC    ->  EQUITY PARK
SQ * Equity Park, LLC  ->  EQUITY PARK,
```

Merchant-to-category learning keys on this string, so a category learned under one spelling never matches the next — the precise failure the normalizer exists to prevent.

**DECIDED (Manu, 2026-09-15) for both defects — they leave this plan.** Each is now a workstream in `keepo-v1-master-plan.md`:

- **Multi-currency transaction entry & capture currency mismatch.** Defect 1 turned out to be the smaller half of a real feature gap: a user travelling with a USD account cannot enter a EUR purchase at all, and a captured `€50.00` on a USD-mapped card is silently recorded as `$50`. The user's specified behaviour (2026-09-15): a mismatch on a **mapped** card converts and presents **two amount fields** — original currency, and account currency **editable** so a bank's FX fee can be added; a mismatch on an **unmapped** card holds amount + detected currency until the card is assigned an account, then falls back to the first case. Money rule 6 is amended to distinguish the *display* conversion it was written to ban from the *currency-paid → account-currency* conversion, which is a fact and is storable.
- **Merchant matching.** The normalizer is **fixed**, not bypassed: punctuation stays in the name, but the suffix and aggregator matchers become boundary-aware (`[\s,]+` as the separator), trailing separators are trimmed, and the suffix list is sorted longest-first — verified by prototype, all three `Equity Park` spellings collapse to one key. An earlier fuzzy-first decision was reversed once its consequence was explicit: several learning rows per shop is the thing normalization exists to prevent. No backfill.

**What blocked Stage 3 was the shared seam, not either workstream — and half of it has now landed:** the separator is inferred from the string and `parseFormattedCurrency` takes no locale at all, so the 100x bug is closed. It still returns a bare `Int64`; returning the **detected currency** is left to the multi-currency workstream, where the columns to store one exist. Original reasoning, unchanged: `parseFormattedCurrency` must stop discarding information from the Wallet string — infer the separator from the string itself instead of `Locale.current`, and **return the detected currency** rather than dropping it. One small change; it fixes the 100x bug and is the foundation the currency workstream builds on. Do it once, in whichever order the two are scheduled — never twice. **`AmountParser.parse(_:locale:)` is not touched** — a user typing on a locale keypad is exactly the case the device locale is the right authority for. Full rules in the master plan's currency workstream.

**Implementation notes:**
- `CaptureIdentity.testCardIdentifier` — one constant in `KeepoCore`, distinctive enough that no real Wallet card could collide.
- A local-only variant alongside `Outbox.submitCaptureTransaction` (`Outbox+Capture.swift`) that does the `applyLocally` write and skips `attempt`.
- **Do not trust `x-success` alone.** It only says the shortcut finished. The pass condition is the test capture *arriving* — Keepo already learns this from the `CaptureNotify` Darwin notification. Fail on `x-error` (surface `errorMessage` verbatim) or a 10s timeout. This also covers the case where an import collided and landed as "Keepo Capture 1", leaving the test to run some older shortcut.
- **`CaptureIntent`'s three parameters become a public API.** Renaming one breaks every shipped copy of the shortcut on every user's phone. Freeze them.



### 3.9 The dashboard step — the metric list does not match the widgets that exist

`DashboardWidgetKind` has **six** cases (`Packages/KeepoCore/Sources/KeepoCore/DashboardLayout.swift:76`):

| Manu's list | Reality |
|---|---|
| Total Networth | ✅ `.netWorth` — "Networth Analysis" |
| Currency Exposure | ✅ `.currencyExposure` |
| Currency Exchange Ratios | ✅ `.fxRate` — **but `unavailable` until a second currency exists** |
| Investing Ratio | ✅ `.investingRatio` |
| Cashflow Analysis (Income vs Expenses) | ✅ `.cashflow` — "Cashflow Breakdown" |
| **Category Breakdown analysis** | ❌ **not a widget.** It is the lower half of the *expanded* Cashflow widget (`CashflowBreakdownView`), and `DashboardWidgetKind.expandedSizes` notes its intermediate size was removed because "its 6×2 now carries the category breakdown at all times" |
| Upcoming Transactions | ✅ `.upcomingBills` — "Transactions Next 2 Weeks" |

**Recommendation:** offer the **six real widgets, under their real titles**, so the pill the user taps is literally the tile they get. Cashflow's pill mentions the category breakdown in its subtitle ("income vs expenses, broken down by category"), which is accurate and sells it better than a separate pill for a thing that is not separate.

**Second, larger problem: a brand-new user's dashboard is empty whichever widgets they pick.** Day one there is one account, no transaction history, one currency. Net Worth has a single point, Cashflow has no buckets, Upcoming has nothing, FX Rate is explicitly unavailable, Investing Ratio is `—` unless the first account was an investment. A dashboard the user just "personalised" that renders five empty tiles is *worse* than today's `DashboardStore.seed`.

**Recommendation:**
- Render each pill as the **real widget against `DashboardData.sample`** — `DashboardCatalogView` already does exactly this, so the user is choosing from pictures of working widgets rather than from names.
- Carry over the catalogue's `unavailable` reason strings ("add a second currency") verbatim rather than offering a pill that produces a dead tile.
- **Always place Net Worth first**, whether or not it was selected, unless the user explicitly deselects it.
- Add one line under the title: *"They'll fill in as you use Keepo."* Sets the expectation instead of letting an empty grid set it.

**Ordering is free.** `DashboardStore.append(kind:)` places at the first free slot in reading order, so committing the selection in selection order *is* the hierarchy. The number badge on a selected pill is just its index. Full drag-reorder is the expensive version — recommend shipping tap-to-order first (tap to select and append, tap again to remove and renumber), with a compact reorderable strip of the chosen widgets underneath **only if** Manu wants it in v1.

### 3.10 The rating prompt is in the wrong place, and it is the expensive mistake

Four independent problems:

1. **Apple's HIG explicitly says not to.** "Avoid asking for a rating when people first launch your app or during onboarding" — because a rating given before any value has been delivered is a rating of the onboarding, not the app.
2. **It cannot be relied on to appear — verified 2026-09-15.** You may *call* `requestReview` as often as you like; **the system decides whether to display it**, capped at **3 displays per user, per app, per 365-day period**. There is **no callback and no return value** — you can never tell whether it appeared or whether they rated. And the build type changes the behaviour: **always shown in debug builds, never shown in TestFlight builds, only sometimes in App Store builds.** So it will look perfect in the simulator, be untestable in TestFlight, and be unpredictable in production. A screen whose design assumes a dialog appears over it will sometimes be a black curtain over a title and nothing else.
3. **First ratings are disproportionately weighted** for a new App Store listing. Harvesting them from users who have not seen a single captured transaction is spending the most valuable asset the launch has on the least informed possible reviewers.
4. It fires while a batch of network writes is in flight (that screen is the commit point) — if anything fails, the user is rating the app over an error.

**DECIDED (Manu, 2026-09-15) — the screen stays, the ask moves.**

- **The commit screen stays** and does its real job: it is where the whole draft commits. "Setting up your keepo" over a progress state is honest, because work genuinely is happening. **No rating prompt on it.**
- **Primary trigger — clearing the pending inbox, with ≥2 captures reviewed in the user's lifetime.** The inbox also carries `sync_conflict` and `ambiguous_card` items, and asking for a rating the moment someone finishes resolving a *sync conflict* is asking them to rate the app right after it caused them a problem — so the clearing batch must contain at least one `pending_capture`. The lifetime bar is separate and deliberate: someone who has reviewed exactly one captured purchase has thin grounds to rate on, and two means they have watched the trick work twice.

#### Arm and defer — the condition and the ask are separate events

**This is not a refinement, it is the correctness fix**, and it closes two bugs a naive "watch the count go 1 → 0" rule has:

> **False positive.** `CaptureQuickActionHandler` resolves a capture from `AppDelegate.didReceive` **while the app is backgrounded** — Confirm, a category pick and Delete all run without foregrounding. So the inbox genuinely clears while the user is on their lock screen, and a rating prompt fired there is fired at nobody.
>
> **False negative, the worse one.** `needsReviewCount` lives in `MainTabView`, which evaluates nothing while backgrounded. A background clear is therefore **never observed as a transition at all** — the app just foregrounds later to an inbox that is already 0. Under a transition-watching rule, every user who habitually clears from notifications would be asked *never*.
>
> Raising the batch threshold fixes neither. Two captures cleared from notifications is an ordinary Tuesday.

So:

1. **Arm at the write, not by watching a count.** The quick-action path and the in-app path both funnel through `submitConfirmCaptureTransaction` / `submitReviewCaptureTransaction`. Immediately after that write, increment a persisted lifetime `capturesReviewed` counter and check whether any `pending_capture` rows remain; if none and the counter is ≥2, set `reviewPromptArmed`. One place, identical behaviour foregrounded or backgrounded — and it is the same choke point both call sites already share, per the Engineering Principles.
2. **Ask on a clean foreground beat.** Scene `foregroundActive`, nothing modal presented, ~2s settled. Not merely politeness: `requestReview` [requires a foreground-active scene](https://developer.apple.com/forums/thread/652157) and silently does nothing otherwise, and Apple does not document whether that no-op still consumes one of the three annual displays — so a backgrounded call is pure downside. Clearing the armed flag is what makes it one-shot.

A user who cleared from the lock screen and opens Keepo hours later sees the prompt over a calm, empty inbox rather than immediately after the gesture. Less causal, still coherent.
- **Fallback — ≥7 days since signup AND not asked in 120 days.** Deliberately **not** gated on transaction count (Manu's call), so a user who never sets up capture is still eventually asked. The 7-day clock reads **`profiles.created_at`**, which already exists, rather than inventing a local first-launch key.
- **A permanent "Rate Keepo" row** in Profile → Help & Support, opening `https://apps.apple.com/app/id<APPID>?action=write-review`. This is the **only guaranteed-visible path** — it always opens the App Store's write-review sheet, with no cap and no silent no-show — at the cost of leaving the app. It is for the person who decided to go rate you, not for an interruption. **The App Store ID does not exist yet**, so the row ships behind a constant and stays hidden until the app is created in App Store Connect.

**Mechanics.** `ReviewPolicy` in `KeepoCore` — pure, unit-tested, one struct — decides; `ReviewPrompter` in the app target holds `@Environment(\.requestReview)` and the persisted state: `capturesReviewed` (lifetime count), `reviewPromptArmed`, `lastReviewRequestAt`, `hasAskedEver`. Changing the policy later is changing one struct.

**The local-only test capture (§3.8) must not count.** It is never a server-side `pending_capture`, so it cannot arm the inbox condition — but it *is* deleted by the user through a capture path, so the lifetime `capturesReviewed` increment has to skip the reserved test identifier explicitly. Otherwise onboarding itself contributes to the bar it is supposed to sit behind.

**Testing it:** debug build only. It always shows there, never shows in TestFlight, and is unpredictable in production — read nothing into any of the three.

**Not shipping:** a sentiment pre-prompt ("Enjoying Keepo?" → Yes goes to the native prompt, No goes to feedback). Widespread and effective, but it sits in tension with Guideline 1.1.7's *"we will disallow custom review prompts"*, and it is not worth any friction with App Review on a first submission. Revisit if ratings volume disappoints.

### 3.11 FTUX — six guided steps straight after the onboarding flow is too much

Items 1–6 are all worth teaching. Teaching them all in a row, immediately, is a seventh through twelfth screen for someone who has just sat through eleven.

**Recommendation — one spotlight now, everything else just-in-time:**

- **Immediately, once:** a single spotlight coach mark on the **scope banner swipe**. This is the only genuinely invisible, genuinely important gesture in the app — a horizontal swipe on a header with no affordance, that changes what every number on screen means. It earns an interruption; nothing else does.
- **Just-in-time, one per screen, once each:** first visit to Accounts → "drag between Everyday and Investments to convert an account"; first visit to Categories → "tap a tile to edit it"; first long dwell on Home → "long-press a widget to rearrange"; first time Needs Review has an item → what it is; the privacy toggle and the "+" button get a tip on the screen where each matters.
- **Replayable:** a "Show me around" row in Profile → Help & Support, so the tour is available and never mandatory.

**Use TipKit for the just-in-time tips.** Deployment target is iOS 18.0; TipKit is iOS 17+. It gives eligibility rules, display frequency, persistence and dismissal for free — all of which is otherwise hand-rolled state. That is the "reuse before writing" call. Hand-roll **only** the scope-banner spotlight, because TipKit popovers cannot dim-and-cut-out the background, and the whole point there is to show *the banner* while dimming everything else.

---

## 4. The flow as planned

Notation: **[R]** = reuse existing code, **[N]** = new.

### 4.0 Shared chrome — built once, used by every setup screen

- **[N] `OnboardingChrome`** — the top bar: centred progress dots (current step a pill, per the brief), a delayed `Skip`, and a `Back` when there is somewhere to go. Dots from `AppTheme.Size.dot` (8), pill = a capsule of the same height. `AppTheme.Motion.quick` for the pill's travel.
- **[N] `DelayedSkipButton`** — fades in after `2.75s` on the step's appearance, resets per step. `AppTheme.Motion.colorSafe` (it is an opacity change — see the token's own doc comment on why a spring here is a rendering bug).
- **[N] `OnboardingScaffold`** — title / body / content / bottom bar, so eight screens cannot drift on spacing. Screen edge `Spacing.l`, block separation `Spacing.xxl`, per the brand doc.
- **[N] `OnboardingPrimaryButton` / `OnboardingSecondaryButton`** — Next / Back. Bottom-right / bottom-left as specified. `AppTheme.Feedback.buttonPress`.

### 4.1 Intro — `App/Features/Onboarding/Intro/`

> **Removed 2026-09-18 — see §10.20.** The welcome screen and the four-slide deck are gone; `.needsSignIn` renders `OTPSignInView` directly. The table below is kept as the record of what was built, not as something to build.

| # | Screen | Build |
|---|---|---|
| 1 | **Welcome + problem** (merged, §3.1) | **[N]** `WelcomeView`. Hero mark at `Typography.Number.hero`, tagline, the problem framing, "Let's go". |
| 2–5 | **Features 1–4** as a swipeable deck | **[N]** `FeatureDeckView` + `FeatureSlide` (icon, title, three-or-fewer lines, page dots). Copy per §3.3 / §3.4. Icons from `Assets.xcassets/Icons` — `icon-lock`/`icon-faceID` (privacy), `icon-tap` (capture), `icon-slider` (customise), `icon-shared` (household). |
| — | **Sign in** | **[R]** `OTPSignInView`, revisualised (§3.5c): hero mark, tagline, one field, one button, the waiting state given a resend cooldown and a "wrong address?" escape. |

~~Intro screens show **before** sign-in, so they render on `SessionStore.phase == .needsSignIn`. `RootView` gains one `@AppStorage` flag (`hasSeenIntro`) so a returning signed-out user is not re-marketed.~~ **Superseded 2026-09-18:** there are no intro screens, and `hasSeenIntro` no longer exists.

### 4.2 Setup — `App/Features/Onboarding/Setup/`

All eight steps write to an in-memory + persisted **draft** (§5), and **nothing reaches the server until step 7**. (Nine in the original brief; the card-mapping screen was cut — §3.7.)

| # | Screen | Build |
|---|---|---|
| 1 | **Your profile** | **[R]** `ProfileAvatarView` at `Size.illustration` + the camera overlay lifted out of `ProfileView.identity` into a shared `AvatarButton` **[N]**; **[R]** `avatarPicker` modifier; name `TextField` prefilled from **[N]** `DisplayNameSuggestion` (§3.5a). Image held in the draft as JPEG data, **downscaled the moment it is picked** rather than at commit (the draft is persisted on every change, and a full camera capture does not belong in `UserDefaults`); uploaded at commit. **Skip clears the name and the photo** — keeping a prefilled suggestion through a Skip would be accepting a guess on the user's behalf, which is the one thing `DisplayNameSuggestion` exists to prevent. |
| 2 | **Base currency** | **[R]** the `BaseCurrencySheet` wheel body, extracted into **[N]** `CurrencyWheel` so both the sheet and this inline step render one implementation. Default from device locale (§3.6). Currencies come from the local mirror — **keep the `.task(id: session.refresh.token)` keying**; the existing comment on `OnboardingView` records a real bug where a fresh install dead-ended here on an empty picker. |
| 3 | **First account** | Kind as a segmented control reading its copy from `AccountKindPicker` (**not** its two cards — see §10.12), then **[R]** `IconPickerButton` + `IconCatalogView`, name field, **[R]** `AmountField` in the base currency. **[N]** starter chips prefilling name + icon — Checking / Cash / Credit Card for Everyday, Brokerage / Retirement for Investment, because offering "Checking" to someone who just said "Investment" is offering the wrong list. **[N]** a quiet "different currency?" link revealing **[R]** `CurrencyPickerSheet` — Feature 3 sells multi-currency; an expat whose first account is not in their base currency should not be stuck. Opening balance is **required**, matching `AccountFormView.isSaveDisabled`: an empty figure would silently mean zero, and zero is a claim. |
| 4 | **Automatic capturing** | Three sub-steps (§4.3). The largest step in the flow. |
| 5 | **Categories** | **[N]** `DefaultCategoryCatalog` in `KeepoCore` (pure data, unit-tested): ~14 expense, ~6 income, each with SF Symbol + hex colour, **excluding "Other"** (the backend already seeds one per kind at signup, and `categories_one_default_per_kind` means none of these may be `is_default`). Tiles = **[R]** `CategoryTile`, **extracted from `private`** into `App/Common/Components/`. Selection state as a border/fill, `Feedback.selection`. |
| 6 | **Dashboard** | **[N]** `MetricPillGrid` rendering the six real kinds (§3.9), each pill previewing the **[R]** real widget against **[R]** `DashboardData.sample`; **[R]** `unavailable` reasons; order badge = selection index. |
| 7 | **Setting up your keepo** | **[N]** `CommitView` — the real commit (§5.3), an indeterminate progress state, failure handling. **No rating prompt** (§3.10); the curtain reuses `MappedCardSheet`'s material + `Opacity.fill` black. |
| 8 | **You're all set, {name}** | **[N]** `AllSetView` → "Go to my Keepo" → `session.refreshProfile()` flips `phase` to `.ready`, landing on Home. |

### 4.3 Step 4 in detail — the hard one

**4a — Why notifications.** Explain that captures arrive as a notification you can act on without opening the app (this is true and it is the feature's real shape). Then an **explicit button** — "Turn on notifications" — not a timer-triggered system dialog. Priming before the ask is both HIG guidance and measurably better for grant rate, and a permission sheet that appears because a timer expired feels like an ambush. Calls the existing `requestNotificationAuthorizationIfNeeded()` guard **[R]**, moved to a shared service so there stays exactly one place that asks.

**4b — Building the automation, on video.** Reshaped by §3.8: the user no longer builds the action-and-variable-mapping part at all.

- **Step one is a one-tap import** of the prebuilt "Keepo Capture" shortcut from its iCloud link. Text fallback behind a failed import.
- **Step two is the automation**, now four taps with nothing to mistype: New Automation → Wallet → pick cards → Run Immediately → Run Shortcut "Keepo Capture".
- **[N]** `ShortcutsWalkthroughView`: an ordered list of steps, each = one looping muted clip + the same text step. Model in **[N]** `KeepoCore/ShortcutsWalkthrough.swift` so the copy is data, and **`WalletAutomationGuideView` is rewritten to render from that same model** — one copy of the instructions in the app, per the Engineering Principles. Its current six steps are replaced by the shorter sequence.
- **Video:** `AVPlayer` + `VideoPlayer`, `.isMuted`, looped via `AVPlayerLooper`, no controls, poster frame while loading. **Bundled, not remote** — this has to work offline and on first launch. Budget: **3–4 clips** (down from 6), ≤10 s each, portrait, HEVC, **no audio track**, ≤2 MB each, **≤8 MB total**. A `videos/` folder reference in `project.yml` (same pattern as `ThirdPartyLicenses`).
- **Accessibility is not optional here:** video-only instructions exclude VoiceOver users and anyone with Reduce Motion on. Every clip ships with its text step visible beside it, and the whole walkthrough must be completable from the text alone.
- **"Open Shortcuts"** button → `shortcuts://`. The user leaves for minutes; §5.2 is why that is safe.

**4c — Verification.** Per §3.8:
- **"Test it now"** → `shortcuts://x-callback-url/run-shortcut?name=Keepo%20Capture&x-success=…&x-error=…`. Handled in `RootView.onOpenURL` alongside the existing magic-link and capture deep links. `x-error`'s `errorMessage` is surfaced verbatim — it names the real failure (shortcut missing, renamed, action failed).
- The pass condition is **the test capture arriving** (via `CaptureNotify`), not `x-success` — see §3.8. The capture is written **locally only** and never pushed.
- Success shows the captured test purchase with **Delete** as the primary action. Never auto-deleted; a persistent "Delete test purchase" affordance lives in Profile → My Automations until it is gone.
- **"Preview the notification"** — honest demo.
- **`captureVerifiedAt`** persisted; "Waiting for your first purchase" → "Working ✓" in Profile → My Automations.

---

## 5. Architecture

### 5.1 `OnboardingDraft` — one `Codable` value

```
struct OnboardingDraft: Codable, Equatable {
    var step: SetupStep
    var displayName: String?
    var avatarJPEG: Data?          // small; committed at 8
    var baseCurrency: String?
    var account: DraftAccount?     // id minted here — client-generated UUIDs are the existing convention
    var cardIdentifier: String?
    var selectedCategories: [DefaultCategoryKey]
    var selectedMetrics: [DashboardWidgetKind]   // order IS the hierarchy
    var notificationAsked: Bool
    var walkthroughStep: Int
}
```

Lives in `KeepoCore` (pure, `Codable`, unit-tested). Persisted as JSON in `UserDefaults` under a new `AppSettingsKeys.onboardingDraft`, alongside the existing device-local keys and for the same documented reason: it is presentation/progress state, not data about the user's money.

### 5.2 Resume — survives backgrounding *and* termination

The brief asks for resume after the user leaves for Shortcuts. iOS may **terminate** the app during those minutes, not merely background it, so in-memory `@State` is not enough — which is what today's `OnboardingView` has. Persisting the draft on every step change makes resume free and correct in both cases. On relaunch, `OnboardingFlowView` restores `draft.step` and shows a quiet "Picking up where you left off" the first time.

### 5.3 The commit — one point, step 8

Today's flow writes the account, then completes onboarding, from inside step 4 — so abandoning afterwards leaves an orphan account. Moving **every** write into step 8 gives: trivially correct Back on all seven steps, zero garbage from an abandoned flow, and one place that handles failure.

Order matters, because two different write paths are involved (§1 constraint 2):

1. **[R]** `AvatarStore.replace(with:session:)` — uploads the image and patches `avatar_path` (online).
2. **[R]** `ProfileRepository.completeOnboarding(baseCurrency:displayName:)` — one patch, satisfies the CHECK (online). **Must succeed** — everything else is recoverable, this is what makes the user onboarded. `displayName` is **optional**: skipping step 1 is a real answer, and `profiles_display_name_length` allows null while refusing `""`, so "no name" has to be absence. `nil` omits the key (synthesised `Encodable` uses `encodeIfPresent`), which also means a replayed onboarding cannot wipe a name the user already has.
3. **[R]** `outbox.submitCreateAccount` (local-first; lands on device immediately even offline).
4. **[R]** `outbox.submitCreateCategory` × N.
5. **[R]** `DashboardStore` — `append(kind:)` in selection order (local `UserDefaults`, cannot fail meaningfully).
6. `session.refreshProfile()` → `phase` becomes `.ready`. **It has to be last, and the commit must not go through `SessionStore.completeOnboarding`** — that wrapper refreshed immediately, which flips the phase and tears `SetupFlowView` down, cancelling the task running steps 3–5. The wrapper is deleted; the commit calls the repository directly. The draft is cleared **after** this succeeds, so a finished user whose profile re-read failed is not dropped back onto step 1 of an empty flow.

The card-mapping write that used to sit between 3 and 4 is gone with screen 4 (§3.7) — which also removes the ordering hazard it carried (it referenced the account id, so it depended on the outbox draining FIFO).

Failure handling: 2 failing is the only hard stop — show the error, offer retry, keep the draft. 3–4 are outbox writes that are **already durable on device** the moment they are submitted; nothing to surface.

### 5.4 Routing

`RootView` currently switches on `SessionStore.Phase` and hands `.needsOnboarding` to `OnboardingView`. It gains:
- `.needsSignIn` → `OTPSignInView`. (Was `hasSeenIntro ? OTPSignInView : IntroFlowView` — the intro was removed 2026-09-18, §10.20.)
- `.needsOnboarding` → `SetupFlowView` (new), restoring from the draft.
- `.ready` → `MainTabView`, which gains the FTUX layer.

### 5.5 FTUX

- **[N]** `FTUXCoordinator` — `@Observable`, owns the one-shot spotlight and the replay entry point.
- **[N]** `SpotlightOverlay` — dimmed scrim with a cut-out, positioned via `anchorPreference` from an `.ftuxAnchor(_:)` marker on the real view. Bubble width `AppTheme.Size.proseWidth` (the token exists for exactly this). One consumer: the scope banner.
- **TipKit** for the just-in-time tips (§3.11). `Tips.configure()` in `KeepoApp`.
- "Show me around" row in Profile → Help & Support resets and replays.

### 5.6 File layout

```
App/Features/Onboarding/
  (Intro/      removed 2026-09-18 — sign-in is the first screen)
  Setup/        SetupFlowView, Step1Profile … Step9AllSet, CommitView
  Shared/       OnboardingChrome, OnboardingScaffold, DelayedSkipButton, buttons
App/Features/FTUX/        FTUXCoordinator, SpotlightOverlay, Tips
App/Common/Components/    CategoryTile (extracted), CurrencyWheel (extracted), AvatarButton (extracted)
App/Services/             ReviewPrompter, CaptureVerification, NotificationPermission
Packages/KeepoCore/Sources/KeepoCore/
  OnboardingDraft.swift, DefaultCategoryCatalog.swift,
  DisplayNameSuggestion.swift, ShortcutsWalkthrough.swift, ReviewPolicy.swift
```

`.swiftlint.yml` warns at 120 chars; the repo's convention for a long view is a `+Extension` file (`AccountFormView+Cards.swift`). Budget for it.

---

## 6. Dependencies on Manu (not code)

| Asset | Notes |
|---|---|
| **4 screen recordings** of building the Wallet automation | **Pending (Manu, 2026-09-16): he will record them later; the flow is built to run without them.** `App/Resources/Videos/` exists as a folder reference with the file names, specs and reasoning in `RECORDING-NOTES.md` — drop the clips in and they are picked up. Every clip is optional in `ShortcutsWalkthrough` and the walkthrough falls back to its written step, which is the durable half regardless (VoiceOver, Reduce Motion). |
| **The "Keepo Capture" shortcut** | ✅ **Delivered (Manu, 2026-09-16)** — `https://www.icloud.com/shortcuts/67d23227435a43a4926d9b22d1bb5065`, recorded in `ShortcutsWalkthrough.installURLString`. **Two things still ride on it:** the shortcut must keep the name `Keepo Capture` exactly (the automation and the test round-trip both ask for it by name), and the link is the one part of onboarding that can break with no code change — see the Edge-Function-302 risk row, and the text fallback behind a failed import. |
| **Final intro copy** | §3.2/3.4 propose revisions; §3.3 is settled. |
| **Default category list** | I'll propose ~20 with icons + colours; needs a pass. |
| ~~**Launch screen**~~ | **Done 2026-09-16 (Manu's call: match `RootLoadingView`).** `UILaunchScreen` in `App/Info.plist` — `BGCanvas` plus the `LaunchMark` image set built from `keepo-logo.png`, which §6 noted no view had ever claimed. `RootLoadingView` draws the same mark at the same size, centred on its own so it does not hop when the app takes over; the spinner is the only thing that arrives. **It is a dictionary, so it cannot be an `INFOPLIST_KEY_*` build setting** — those built an empty `UILaunchScreen` and a blank white screen. |

---

## 7. Build order

Each stage ends with the repo's standard gate: `xcodebuild -scheme Keepo build` clean · `swift test` green · `swiftlint` 0 violations · simulator walkthrough · commit.

**This plan is third in the shipping order** — capture hygiene, then multi-currency, then this. See `keepo-v1-master-plan.md`, "Shipping order for the three open workstreams", for why. **Stages 0–2 touch none of the capture pipeline and can be pulled forward into any gap.**

| Stage | Contents | Review stop |
|---|---|---|
| **0 — Foundations** ✅ **delivered 2026-09-16** | `OnboardingDraft` + `SetupStep` + `DraftAccount`, `OnboardingDraftStore`, `DisplayNameSuggestion`, `DefaultCategoryCatalog`, `ShortcutsWalkthrough` (brought forward — the user supplied the iCloud link), chrome (`OnboardingChrome`/`ProgressDots`/`DelayedSkipButton`/`OnboardingScaffold`/the two buttons), `CategoryTile`/`CurrencyWheel`/`AvatarButton` extractions, DEBUG "Replay Onboarding" + `ProfileRepository.resetOnboarding`, `App/Resources/Videos/` folder reference. 26 new tests. Nothing user-visible. | no |
| **1 — Intro + Sign-in** ✅ **delivered 2026-09-16**, intro half **removed 2026-09-18 (§10.20)** | ~~`WelcomeView` (merged), `FeatureDeckView`/`FeatureSlide`, `IntroFlowView`~~, the `OTPSignInView` revisual, ~~`hasSeenIntro` routing in `RootView`~~. Reviewed on the simulator with the user watching; two changes came out of it (see §10.1/§10.2). | **yes** — done 2026-09-16 |
| **2 — Setup 1–3** ✅ **delivered 2026-09-16** | `SetupFlowView`, `SetupProfileStep`, `SetupCurrencyStep`, `SetupAccountStep`, `SetupCommitPlan` + `SetupCommitView` — the commit end-to-end, short-circuited after step 3. `BaseCurrencyDefault` (new, in `KeepoCore`), `DashboardStore.replace(kinds:)`, `AccountKindPicker` becomes the single source of the two kinds' copy, `completeOnboarding`'s `displayName` becomes optional, `OnboardingView` and `SessionStore.completeOnboarding` deleted. 20 new tests. Walked on the simulator through to a live dashboard; three changes came out of that (see §10.12). | no |
| **3 — Setup 4** ✅ **delivered 2026-09-16** | `SetupCaptureStep` + its three sub-steps, `NotificationPermission` (the one place that asks), `ShortcutsWalkthroughView` + `WalkthroughClipView` (shared with a rewritten `WalletAutomationGuideView`), `CaptureTestSession` + `CaptureTestCoordinator`, `CaptureIntent`'s empty-invocation test branch, `Outbox.submitTestCaptureTransaction` (local-only), `TestCaptureQueries`, the Needs Review exclusion, `AppSettings.captureVerifiedAt` + `CaptureStatusCard`, `KeepoShortcuts` (`AppShortcutsProvider`), `LSApplicationQueriesSchemes`. 9 new tests. **The `x-callback-url` round trip is verified**, including on the Simulator — see §10.14. **Restored the notification ask, which stage 2 removed** — deleting `OnboardingView` took `requestNotificationAuthorizationIfNeeded()` with it, so until this lands the only place that asks is Profile → Notifications, and a fresh user has `.full` selected with no iOS permission behind it (C-06). §4.3a's primed, explicit-button ask is the replacement; calling it from the commit instead would be precisely the ambush §4.3a rejects. **Prerequisites: (a) the capture-hygiene and multi-currency workstreams, which precede this entire plan — see the master plan's shipping-order section; (b) Manu publishes the "Keepo Capture" iCloud link, which also determines the video script.** The device probe is done — see §3.8. Largest stage; split if it runs long. | **yes** — needs a real device |
| **4 — Setup 5–6** ✅ **delivered 2026-09-16** | `SetupCategoriesStep`, `SetupDashboardStep` + `SetupDashboardLayout` + `DashboardCapabilities.init(onboarding:)`. Every widget is the **real** `DashboardWidgetView` against `DashboardData.sample`, packed by `DashboardArrangement` itself, with the catalogue's own unavailability reasons derived from the draft. 10 new tests. Walked to a committed dashboard on the simulator; two layout defects came out of that (see §10.16). | no |
| **5 — Setup 7–8** ✅ **built 2026-09-16** | `SetupCommitView` gains `MappedCardSheet`'s curtain and hands off to **[N]** `SetupAllSetView`, which owns the `refreshProfile()` that ends the flow. `ReviewPolicy` (KeepoCore) + `ReviewPrompter` + `ReviewPromptModifier` on `MainTabView`, armed at the outbox's own capture-resolution choke point; `AppStoreListing` + the Profile "Rate Keepo" row, hidden until the app exists in App Store Connect. 16 new tests. Walked end to end on the simulator; **three shared-component defects came out of it** (§10.17) plus two changes Manu asked for mid-review. | **yes** — done 2026-09-16, see §10.18 |
| **6 — FTUX** ✅ **delivered 2026-09-16** | `FTUXLessons` (KeepoCore, one copy of every lesson), `FTUXCoordinator`, `SpotlightOverlay` + `.ftuxAnchor()` on `ScopeBannerView`, `LessonTip` over TipKit with the six just-in-time tips, `ShowMeAroundView` + its Profile row, `Opacity.scrim`. 10 new tests. Walked on a fresh install; **three defects came out of it** (§10.19). | **yes** — done 2026-09-16 |

Per `CLAUDE.md`: add an **"Onboarding redesign workstream"** section to `keepo-v1-master-plan.md` (same treatment as the UI-redesign and widget workstreams), and a `version-logs/onboarding-redesign-<date>-log.md` + `lessons-learned.md` update when it lands.

### Dev-loop notes (from `lessons-learned.md` and the master plan)

- **`xcrun simctl erase <device>`**, never uninstall/reinstall, to test a fresh signup — the Keychain survives uninstall.
- The **local stack auto-signs-in** via `StubAuthProvider`, so the intro + sign-in screens need the hosted config or a DEBUG bypass. Build the bypass in Stage 0.
- **`xcodegen generate` after every new `.swift` file.**
- Simulator coordinates are **device points**, not screenshot pixels (~2.284× on iPhone 17 Pro).

---

## 8. Tests

**`KeepoCore` (Swift Testing, `@Suite`/`@Test`/`#expect`):**
- `OnboardingDraft` round-trips; an unknown persisted step decodes to a safe default rather than crashing.
- `DisplayNameSuggestion`: `fam.samper.ona` → `nil`; `manu` → `Manu`; `manu.ogm` → `Manu`; `user123` → `nil`; SIWA components win over email.
- `DefaultCategoryCatalog`: no name collides with `Other`, case-insensitively; every entry has a valid hex colour and a resolvable symbol; no duplicates within a kind.
- Ordered metrics → `DashboardArrangement`: selection order maps to reading order; Net Worth is first; a `wide` kind does not strand a `small` one.
- `ReviewPolicy`: every gate, the 120-day re-ask window, the ≥2 lifetime bar, and that the reserved test identifier never increments `capturesReviewed`.
- Arming is write-driven, not observation-driven: a simulated background quick-action clear arms the flag with no view ever mounted.

**App target (`KeepoTests`):** commit ordering (account before card mapping); a failed profile patch leaves the draft intact and the phase unchanged.

**`KeepoUITests`:** full fresh-install walkthrough; skip-everything path lands in a working app; kill-and-relaunch mid-setup resumes on the same step.

**Manual, real device only:** Shortcuts automation build-out, the `Keepo Capture` shortcut run from the Shortcuts app and from Keepo's test button, a real Apple Pay purchase flipping the verification state, notification permission and quick actions.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| **Users abandon during the 15-screen flow** | Instrument nothing (no analytics SDK in this app, deliberately) — so trim by design instead: §3.1, honest Skip on every step (§3.6). |
| **Magic link is the attrition cliff** | §3.5b. Prioritise SIWA if the membership is near. |
| **Shortcuts UI changes in a future iOS** | Video instructions rot. The text steps are the durable copy; keep one source (§4.3) so re-recording is the only cost. |
| ~~Card identifier typo silently breaks capture~~ | **Closed** — screen 4 cut (§3.7); the identifier now arrives from the Transaction's `Card` field and is mapped in one tap from Needs Review. |
| **Fake test data reaching the real ledger** | Closed by §3.8's Option 1 — the test capture is written locally and never pushed, so no `card_mappings` placeholder, no `ambiguous_card`, no merchant learning, no rating-trigger pollution. |
| ~~The iCloud shortcut link dies~~ | **Closed 2026-09-16.** `supabase/functions/capture-shortcut` is a public 302 to wherever the shortcut is published, so re-pointing it is a `supabase secrets set` rather than an App Store release. The app prefers it (`ShortcutsWalkthrough.installURL(functionsBaseURL:)`, derived from `SupabaseConfig` so the project ref stays out of git) and falls back to the literal iCloud link when there is no project configured — the redirect is one more thing that can be down. Text fallback still sits behind both. **Deployed 2026-09-16** to `fmogwbadhimwfhhibrau`; verified unauthenticated from the public internet — `GET` 302s to the published link and follows through to iCloud, `POST` 405s. Re-point with `supabase secrets set KEEPO_CAPTURE_SHORTCUT_URL=…`. |
| **Rating prompt burns the launch's first reviews** | §3.10 — move to the earned moment. |
| **Empty dashboard after "personalising" it** | §3.9 — sample previews, unavailable reasons, Net Worth always present, one line of expectation-setting. |
| **The capture step is a phase-sized piece of work inside one screen** | It is stage 3 on its own, with its own review stop, and is the split seam if the schedule slips. |

---

## 10. Open decisions for Manu

**Settled 2026-09-15:** 3, 7, 8, 10. **Settled 2026-09-16 while building stage 1:** 1, 2, 4, 5 — the user reviewed the built screens on the simulator rather than the proposals on paper, which is why two of them ended up somewhere the recommendation had not. **Settled 2026-09-16 after seeing stage 2 running:** 6. **Settled 2026-09-16 while building stage 4:** 9. **Settled 2026-09-16 while building stage 6:** 11. **Nothing is open.** The §3.8 device probe is **done**; the remaining engineering unknown is the on-device capture test.

1. ~~**§3.1** — merge Welcome + Problem, swipeable deck~~ — **DECIDED 2026-09-16: both, and built.** One welcome screen, four features as a paged deck. **The user then changed the deck's interaction on review:** the content is **centred**, not left-aligned, and the button no longer advances the deck — see 2.
2. ~~**§3.2** — the three middle button labels~~ — **DECIDED 2026-09-16, and it went further than the recommendation.** There are no middle labels left: the deck has **one** button, reading "I'm in. Take me to Keepo" throughout, and it is **disabled until all four slides have actually been seen** (the user's call — the deck must not be dismissable off the first screen). Swiping is therefore the only way through, which the page dots already signalled. Seen-ness is a `Set`, not a high-water mark, so swiping back never un-sees a slide. **The one risk, recorded rather than hidden:** a user who does not swipe meets a dead button, with only the dots to tell them why. If that shows up in real use, the cheapest fix is to let the button advance while slides remain unseen and only become the exit at the end.
3. ~~**§3.3** — automatic-capturing claim~~ — **DECIDED**: "Set up Keepo to detect each tap-payment…".
4. ~~**§3.4** — "ALL YOURS" vs the three specific facts~~ — **DECIDED 2026-09-16: the three facts, and built.** No bank logins / never sold, never used to train AI / encrypted in transit and at rest. Three checkable claims instead of one unfalsifiable one.
5. ~~**§3.5** — the name heuristic, and whether to pull SIWA forward~~ — **DECIDED 2026-09-16: ship as designed, do not block on SIWA.** `DisplayNameSuggestion` landed in stage 0 with the seam SIWA plugs into, and the sign-in screen got the polish instead: the 48pt mark it was always specified to have, a resend with a **visible** countdown, "Open Mail", and "Wrong address?". **SIWA remains the single highest-value unblock for this flow** — it removes the app-switch entirely and is the only thing that makes a real name available — but it is Phase 20 and needs the paid membership, so it is a separate decision from this redesign.
6. ~~**§3.6** — Skip on the currency step accepts the locale-derived default rather than being hidden?~~ — **DECIDED 2026-09-16: hidden.** Building it made the objection concrete that the written question had not: on that step Skip and Next ran the *identical code path*. The wheel always holds a value — `onboarded_requires_base_currency` is a CHECK, so the step cannot produce "nothing" even in principle — so Skip was a second button doing exactly what the first one does, three seconds later and in a different corner. `SetupStep.isSkippable` now excludes `.currency` as well as `.account`, and the two exclusions are the two ends of the same rule: one step has no default to accept, the other has nothing *but* a default. The rule the remaining four keep is unchanged — Skip never means "no value", it means "accept the default".
7. ~~**§3.7** — card-name typing~~ — **DECIDED**: screen 4 cut entirely. Setup is now eight screens.
8. ~~**§3.8** — the test button~~ — **DECIDED and probed.** Ship the prebuilt "Keepo Capture" shortcut — **one action**, three fields mapped inline to the `Merchant` / `Amount` / `Card or Pass` dictionary keys. Automation drops to four taps with zero mapping. The test is an `x-callback-url` round trip; the empty-input invocation is recognised in Swift behind a short test window. Test capture is **local-only, never pushed**, and the user is always asked to delete it. **The probe exposed a live 100x money bug in `parseFormattedCurrency`; it was fixed on 2026-09-15 as workstream 1.**
9. ~~**§3.9** — offer the six real widgets (Category Breakdown folded into Cashflow), with sample previews? Tap-to-order only in v1, or full drag-reorder?~~ — **DECIDED 2026-09-16: six real widgets under their real titles, sample previews, tap-to-order. No drag-reorder in v1.** Category Breakdown is not a separate pill because it is not a separate widget — it is the lower half of the expanded Cashflow tile, and Cashflow's own preview shows exactly that. Ordering is free and already correct: `DashboardStore.replace(kinds:)` appends in selection order and `DashboardArrangement.append` fills the first free slot in reading order, so the sequence of taps *is* the layout, and the badge on a chosen widget is simply its index. **Drag-reorder is deferred rather than rejected** — the dashboard itself already has it (`DashboardCanvasDrag`), so a user who wants a different order has it one screen later, which is the argument for not building a second, weaker copy of it inside a flow they walk once.
10. ~~**§3.10** — rating timing~~ — **DECIDED**: **arm-and-defer**. Armed at the write when the pending inbox clears with ≥1 `pending_capture` in the batch **and ≥2 captures reviewed lifetime**; asked only on a clean foreground beat. Fallback ≥7 days since `profiles.created_at` AND not asked in 120 days, not gated on transaction count. Plus a permanent "Rate Keepo" row in My Profile.
11. ~~**§3.11** — one spotlight now + TipKit just-in-time tips, instead of a six-step guided tour?~~ — **DECIDED 2026-09-16: yes, and built.** One hand-rolled spotlight on the scope-banner swipe — the only genuinely invisible, genuinely important gesture in the app, and the only thing here that earns an interruption. Everything else is a TipKit tip attached to the one view its lesson is about, so "is this relevant?" is answered by *where the tip is* rather than by a predicate that has to be kept in step with the UI. **`displayFrequency(.hourly)` is the whole answer to the "six screens in a row" objection**, in one line, because TipKit already owns eligibility, frequency and persistence — which is also why only the spotlight is hand-rolled: a TipKit popover cannot dim the screen and cut a hole in it, and that is the single thing it could not do better. The tour is **replayable but not re-armed**: "Show me around" in Profile → Help & Support lists all seven lessons as a page, and only the spotlight replays as a coach mark — re-firing six popovers across four screens is a worse answer to "remind me" than a page that simply says all six, and a gesture is the one lesson that has to be pointed at where it happens.

12. **Stage 2's simulator review — three changes, none of them in this plan.** Recorded because all three came from looking at the built screens rather than from the spec, which is now twice in a row that has been where the real decisions came from.
    - **`OnboardingScaffold` floats its content.** Heading and content both stacked against the top edge, so step 1 — an avatar and one field — read as a screen that had failed to finish loading. The heading stays put and the content now sits in whatever is left; when a step's content is tall the spacers collapse and it is an ordinary scroll view again. Every step gets this, not just the short ones.
    - **The first-account step does not use `AccountKindPicker`'s two cards.** They took sixty percent of the screen and pushed the name, icon and balance below the fold, under a Next button that was disabled for reasons the user could not see. It is a segmented control there instead. The cards' own doc comment is the argument: the two kinds behave identically, the choice is reversible by dragging a row on the Accounts list, and it drives a badge rather than a capability — it does not deserve the screen. **The wording is still read from `AccountKindPicker`**, which now owns `title(for:)` / `subtitle(for:)`, so the two places that ask this question cannot describe it differently.
    - **The resume note moved below the chrome.** Centred at the top it covered the progress dots — hiding "where am I" at the exact moment the user is being told they are somewhere they did not leave off.

13. **Two correctness fixes the commit needed, both invisible on screen.**
    - **`refreshProfile()` is last, and `SessionStore.completeOnboarding` is gone.** That wrapper patched the profile and immediately re-read it, which flips `phase` to `.ready` — tearing `SetupFlowView` down, and with it the task running the commit, before the account and categories were written. The commit calls `ProfileRepository.completeOnboarding` directly and refreshes at the very end. The wrapper existed for the flow that has been deleted, so it went with it.
    - **The plan is built once and kept.** `SetupCommitPlan` mints a fresh id per category, so a Try Again that rebuilt it would have written a second full set of them. The account was never at risk — its id comes from the draft, which is exactly why ids are minted there.

14. **Stage 3 verified further than expected — the round trip works on the Simulator.** The plan assumed the whole of stage 3 needed a device. It does not: iOS 26's Simulator ships Shortcuts, so Keepo launching `shortcuts://x-callback-url/run-shortcut`, Shortcuts failing to find the named shortcut, and the `x-error` callback arriving back on `com.manuogm.keepo://capture-test-failed` with its message — *"Could not find the shortcut "Keepo Capture.""* — was all exercised live, verbatim message included. So the **mechanism** is proven; what still needs a real device is only the *success* half (the published shortcut installed, the intent invoked cross-process, the local write landing) and a real Wallet automation.

    Three things the build changed from the written spec:
    - **`LSApplicationQueriesSchemes` was missing entirely**, which is a **live stage-1 bug** as well as a stage-3 blocker: `canOpenURL` returns false for any undeclared scheme, silently, so sign-in's "Open Mail" button has never once appeared on a device. `shortcuts` and `message` are both declared now.
    - **The test screen has one primary, and it is the test.** It first shipped with "Skip the test" in the bottom-right accent fill beside a "Test it now" in the content — giving the way *out* the weight of the action the screen exists for. The escape is the chrome's Skip, where every other step's is.
    - **The capture test's containment is enforced by a query, not by hope.** §3.8 asserts the local-only test capture "never enters Needs Review"; nothing made that true, since a local pending capture is exactly what that inbox lists. `LocalMoneyQueries.needsReviewPendingCaptures` now excludes `CaptureIdentity.testCardIdentifier`, which is also how `TestCaptureQueries` finds the row to delete — `card_identifier` being the one field with a column of its own is why the marker is a card rather than a magic merchant string. Both directions are tested, including that a *real* pending capture still lists.

15. **What the capture test can still only be checked for on a device**, carried into the stage-3 review stop: the success path end to end; that `UserDefaults` is genuinely readable by `CaptureIntent` when it runs in the Shortcuts host (it already reads `AppSettings.notificationLevel` that way, which is why that channel was chosen for `CaptureTestSession`'s window, but the timing is tighter here); and a real Apple Pay purchase flipping `AppSettings.captureVerifiedAt`. The **owed foreign tap-to-pay purchase** from the capture-hygiene and multi-currency workstreams belongs in the same device session — as does `delete from merchant_category_map` against hosted beforehand.

16. **Stage 4's simulator review — two layout defects, both about the same mistake.** Neither was visible in the code; both were obvious in one screenshot.
    - **The widget grid was clipped.** It was built as a `GeometryReader` wrapped around the previews, which meant it needed an explicit height — and the height had to be guessed from a width nobody knew, so the last widget was cut off by the bottom bar. A `GeometryReader` fills whatever it is given and reports that; it cannot size itself from its children. Measuring the width in the `.background` instead leaves the stack to size itself from previews that already have exact frames, so there is no height to guess at all.
    - **The order badge landed on the widget's own controls.** Top-trailing and inset, it sat directly over Cashflow's "Last month" chip — a picture of a control wearing a badge. Every position *inside* these cards overlaps something, because they are real widgets rather than mock-ups; outside overlaps nothing by construction. It straddles the corner now, with a canvas-coloured ring where it crosses the card edge (the same trick `AvatarButton`'s camera badge uses), and the grid reserves the inset so the scroll view cannot clip it.

    Also confirmed live: the day-one emptiness §3.9 warned about is real and now honest rather than hidden — the committed dashboard shows Cashflow at `$0.00` and "Nothing due in the next two weeks", which is exactly what the step's own subtitle ("They'll fill in as you use Keepo — this is sample data") sets up.

17. **Stage 5's walkthrough found three defects, and none of them were in stage 5's own code.** Walking all eight screens in sequence for the first time is what exposed them — which is exactly what that review stop is for.
    - **`OnboardingScaffold` was truncating its own title.** The content sits between two flexible spacers, so SwiftUI is free to negotiate the heading's height, and given the chance it compressed a two-line title to one and ellipsised it: "Purchases, without o…". It appeared the moment *a different string* — that step's subtitle — got shorter, which is the worst shape of layout bug. Both heading lines are `fixedSize(horizontal: false, vertical: true)` now. **This affected every step**, not only the one it was noticed on.
    - **The dashboard grid overhung the screen edge.** `.padding(.trailing,)` was applied *after* `.frame(maxWidth: .infinity)`, so the inset was added to a block that had already expanded to fill its container — every card overhung by exactly the inset, clipping the order badge again. Padding goes inside the frame.
    - **The resume toast had nowhere to be at the top.** Centred it covered the progress dots (fixed in stage 2 by nudging it down), and nudged down it landed on the title — because a two-line title starts exactly there. Every position at the top of a setup step is occupied by something the user needs at that moment, so it is a bottom toast now, above the bar, in the one strip with nothing in it.

    **Manu's two changes, mid-review:** the bottom bar lost its `.bar` background (canvas straight through), and **Back gained an outline** — same capsule and height as the primary beside it, so the pair reads as deliberate with the weight still carried entirely by the primary's fill. Bare text on a bare canvas read as a label that happened to be tappable.

18. **Stage 5's review stop — discharged 2026-09-16, and the erase taught us something about itself.**

    `xcrun simctl erase` alone **did not produce a fresh signup**, which is what both the master plan and `lessons-learned.md` implied it would. It wipes the Keychain, `UserDefaults` and the GRDB mirror — but the *server* still held the profile with its `onboarded_at`, and the local stack's `StubAuthProvider` signed straight back in as the same dev user, so the app landed in the signed-in shell with every account intact and onboarding never ran. The lesson is corrected in `lessons-learned.md`: the erase covers the Keychain half (which matters after a `supabase db reset`); reaching *setup* with an empty mirror also needs `onboarded_at` cleared and the app container dropped.

    With that combination — **not onboarded, empty local mirror, fresh container** — all eight screens were walked through a real commit onto a real dashboard, and the arithmetic checks out ($4,150.75 + $3,200.50 = $7,351.25 on the landing dashboard).

    **What this proved:** step 2 does **not** dead-end on a fresh install. The wheel was populated and sitting on the locale-derived default with Next live, which is the failure `SetupCurrencyStep`'s `task(id: currencies.count)` and `SetupFlowView`'s refresh-token keying exist to prevent.

    **What it did not prove, honestly:** the *spinner* branch was never seen. The local stack's first sync pull always landed before step 2 could be reached, so the empty-currencies window was never observed on screen — only its absence of consequences. Exercising the spinner itself needs a stack that is slow or down, which is worth doing on the hosted config during the stage-3 device session rather than by stopping a working local stack.

19. **Stage 6's walkthrough — three defects, two of them about things firing at once.**
    - **The spotlight and a TipKit tip collided on first launch**, and it was worse than it sounds: the Home widgets popover opened *inside* the spotlight's cut-out, so the coach mark dimming the entire screen appeared to be pointing at a second coach mark. Two interruptions at once is exactly what teaching things just-in-time was meant to avoid. Fixed with the one `Rule` the tips have — `LessonTip.isSpotlightDone`, set when the spotlight is dismissed and synced from the persisted flag at launch. Nothing is taught until the one mandatory thing is out of the way.
    - **"Show me the header swipe again" replayed to a screen that never changed.** `overlayPreferenceValue`'s builder runs in its own update pass, so an `@Observable` property read *only inside that closure* did not reliably register as a dependency of the view's body — the flag flipped and nothing redrew. The overlay is a `ViewModifier` taking `isVisible` as a plain argument now, read at the call site in `body`, where the dependency is ordinary. **Worth remembering beyond this screen**: any `@Observable` read that happens only inside a preference or overlay builder is a tracking hazard.
    - **The replay button only popped back to Profile.** `@Environment(\.dismiss)` dismisses the pushed screen, not the sheet — so the spotlight was replayed behind a modal covering the banner it points at, and the button appeared to do nothing. It closes the whole sheet now.

    Also added: **`AppTheme.Opacity.scrim` (0.6)**, the first value on that scale whose job is to make the app behind it *unreadable* rather than quieter. Keepo's modal curtain is `.ultraThinMaterial` over `fill` and deliberately keeps its background legible as context; a spotlight wants the opposite, so it gets its own token rather than a literal.

20. **The intro is gone — sign-in is the first screen (Manu, 2026-09-18).**

    `WelcomeView`, `FeatureDeckView`/`FeatureSlide` and `IntroFlowView` are deleted, along with `AppSettingsKeys.hasSeenIntro` and its reset in DEBUG "Replay Onboarding". `RootView`'s `.needsSignIn` renders `OTPSignInView` with nothing in front of it, so a first launch lands on the email field.

    Nothing about the pitch was found wrong — this is a decision that five screens of it before anyone has an account is five screens too many. The load that removal puts back on sign-in is why `OTPSignInView` already carries the mark and the tagline: it is the whole first impression now, and its doc comment says so. The copy itself is recoverable from git (`b72f9c4~`) if a marketing surface ever wants it.

    **Do not rebuild it from §4.1 or §3.3/§3.4** — those sections stand as the record of what was built and why the copy read the way it did, not as work outstanding.
