import KeepoCore
import SwiftUI

/// The pairing code: the owner's digits, and the guest's field for them.
///
/// Split from HouseholdDiscoveryView.swift for file length. The state these
/// read (`pairing`, `enteredCode`, `isCodeFieldFocused`) is internal rather
/// than private for that reason alone — same convention as
/// `TransactionsListView+Filters`.
///
/// **Why there is a code at all** is security audit finding 6: before it,
/// the owner's phone accepted every invitation that arrived and both phones
/// sent their name and face the instant the link opened, so anything in
/// Bluetooth range could harvest both with no interaction on either screen.
/// The code moves one secret onto a channel the radio cannot reach — the
/// owner's screen, and their voice in the room — and nothing about who is
/// holding either phone crosses the link until it has been answered.
extension HouseholdDiscoveryView {

    /// The owner's half: the digits, big enough to read off across a table.
    ///
    /// Shown from the first frame rather than once somebody connects, so the
    /// owner can say them out loud while the radios are still looking —
    /// making the other phone wait for a code that only appears after it
    /// arrives would be two people staring at two screens.
    @ViewBuilder
    var codeDisplay: some View {
        if let code = pairing?.pairingCode {
            VStack(spacing: AppTheme.Spacing.s) {
                Text("Your pairing code")
                    .font(AppTheme.Typography.labelEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                PairingCodeCards(digits: code.digits)
                // Read aloud, so it should be read out as digits rather
                // than as one six-figure number.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(code.digits.map(String.init).joined(separator: " "))
            }
        }
    }

    /// Somebody is connected and the code has not been answered. Who they
    /// are is deliberately not on this screen — no name, no face — because
    /// nothing has been exchanged yet, and that is the point.
    ///
    /// The guest's entry is pinned to the top rather than centred. Centred,
    /// it sat in whatever height the number pad left over, so the field
    /// ended up hard against the keyboard — and an error line or the
    /// suggestion bar was enough to push it underneath.
    @ViewBuilder
    var verifyingView: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            if role == .owner {
                Spacer()
                codeDisplay
                HStack(spacing: AppTheme.Spacing.s) {
                    ProgressView()
                    Text("Waiting for them to type it")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
            } else {
                guestCodeEntry
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.top, role == .owner ? 0 : AppTheme.Spacing.xl)
        .padding(.bottom, AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var guestCodeEntry: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            VStack(spacing: AppTheme.Spacing.s) {
                Text("Enter the code")
                    .font(AppTheme.Typography.screenTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text("Ask for the six digits on the other phone.")
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The same cards the owner reads from, filling in as they are
            // typed. The real field sits over them with its text and caret
            // cleared: it is what takes the keyboard, the taps and a paste,
            // and the cards only draw what it holds.
            // The verdict sits directly under the code it is about, not
            // under the button. Centred, in the same red caption the
            // searching state uses, because everything on this screen is
            // centred and a left-pinned line under a centred row reads as
            // belonging to something else.
            VStack(spacing: AppTheme.Spacing.s) {
                PairingCodeCards(
                    digits: enteredCode,
                    activeIndex: isCodeFieldFocused ? enteredCode.count : nil,
                    isRejected: isCodeRejected
                )
                .modifier(ShakeEffect(rejections: codeRejections))
                .accessibilityHidden(true)
                .overlay {
                    TextField("", text: $enteredCode)
                        .textFieldStyle(.plain)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Pairing code")
                        // The field is the whole screen's job, so it owns the
                        // keyboard from the moment it appears.
                        .focused($isCodeFieldFocused)
                        .onAppear { isCodeFieldFocused = true }
                        .onChange(of: enteredCode) { _, value in
                            // Digits only, capped — so a paste of something long
                            // cannot produce a field the user has to clear by hand.
                            let digits = String(
                                HouseholdPairingCode.normalize(value).prefix(HouseholdPairingCode.digitCount)
                            )
                            if digits != value { enteredCode = digits }
                            // `digits`, never `enteredCode`. Writing the property
                            // and reading it back in the same pass is not guaranteed
                            // to see the new value, so when more than six digits
                            // arrive at once — fast typing, a paste — the count test
                            // read the pre-truncation value, failed, and left a full
                            // field that never submitted and has no button to press.
                            // A two-simulator run hit exactly that dead end.
                            if digits.count == HouseholdPairingCode.digitCount { submit(digits) }
                        }
                }

                if let rejection = pairing?.codeRejection {
                    Text(rejection)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.statusNegative)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Auto-submit on the sixth digit is the path everyone takes, so
            // this button is not the affordance — it is the way out when
            // that path misses. A field holding six digits with no way to
            // send them is a dead end, and two-simulator runs produced one
            // (a paste, an autofill or a fast entry landing in a single
            // binding update can skip the `onChange` that submits). Disabled
            // until there is something to send, so it never looks like the
            // primary route.
            Button("Join Household") { submit(enteredCode) }
                .buttonStyle(.pressableCard)
                .font(AppTheme.Typography.bodyEmphasis)
                .foregroundStyle(canSubmitCode ? AppTheme.Palette.textOnAccent : AppTheme.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.m)
                .background(
                    canSubmitCode ? PublicSchema.AccountScope.household.tint : AppTheme.Palette.fillSubtle,
                    in: Capsule()
                )
                .disabled(!canSubmitCode)
        }
        // Every refusal, including a second one carrying the same message:
        // `submitCode` clears the message before sending, so each verdict
        // arrives as a change from nil.
        .onChange(of: pairing?.codeRejection) { _, rejection in
            guard rejection != nil else { return }
            isCodeRejected = true
            withAnimation(AppTheme.Motion.reject) { codeRejections += 1 }
        }
        .sensoryFeedback(AppTheme.Feedback.rejection, trigger: codeRejections)
        // The wrong code shakes in red, then clears itself so the cards are
        // ready for the next one — the lock screen's rhythm. A `task(id:)`
        // rather than a detached sleep, so leaving the screen mid-hold
        // cancels it instead of writing to a view that has gone.
        .task(id: codeRejections) {
            guard isCodeRejected else { return }
            try? await Task.sleep(for: ShakeEffect.rejectionHold)
            guard !Task.isCancelled else { return }
            withAnimation(AppTheme.Motion.colorSafe) {
                enteredCode = ""
                isCodeRejected = false
            }
        }
    }

    /// Six digits that are not the code just refused. During the hold the
    /// wrong code is still on screen, and sending it again would spend
    /// another of the owner's tries on an answer already known.
    var canSubmitCode: Bool {
        enteredCode.count == HouseholdPairingCode.digitCount && !isCodeRejected
    }

    /// Sends the six digits for the owner to judge.
    ///
    /// **The digits stay on screen.** Emptying the field here, before the
    /// verdict, left nothing to show a refusal on: the owner's answer
    /// arrives a moment later, and it is the code the user typed that turns
    /// red and shakes. A refused code clears itself after the shake (see
    /// `ShakeEffect.rejectionHold`); an accepted one is replaced by the paired card.
    ///
    /// **Focus is deliberately kept.** Dismissing the keyboard here was the
    /// obvious thing to do — the answer comes from the other phone, so there
    /// is nothing left to type — and it was wrong: on a refusal the field is
    /// exactly where the user has to go next, and `onAppear` has already
    /// fired so nothing ever gave focus back. A two-simulator run caught it
    /// as a guest who could enter one wrong code and then appeared to have a
    /// dead screen, with no visible hint the field was still tappable.
    ///
    /// On success the keyboard goes away on its own, because the whole
    /// `verifyingView` is replaced by the paired card.
    func submit(_ digits: String) {
        guard let pairing, digits.count == HouseholdPairingCode.digitCount, !isCodeRejected else { return }
        pairing.submitCode(digits)
    }
}

/// The pairing code as one card per digit — the owner's to read out, and the
/// guest's to fill in. One view for both, so the code the guest types looks
/// exactly like the code they are reading off the other phone.
///
/// SF Mono so every card is the same width whatever the digit, and so an
/// empty card (a space) is that width too.
struct PairingCodeCards: View {
    /// As many digits as are known so far; the remaining cards draw empty.
    let digits: String
    /// The card the next digit lands in, outlined while the guest's field
    /// has focus. Nil on the owner's side, where nothing is being typed.
    var activeIndex: Int?
    /// The guest's code was turned away: every card washes red, the way an
    /// amount the form cannot take is marked.
    var isRejected = false

    var body: some View {
        let known = Array(digits)
        HStack(spacing: AppTheme.Spacing.s) {
            ForEach(0..<HouseholdPairingCode.digitCount, id: \.self) { index in
                Text(index < known.count ? String(known[index]) : " ")
                    .numberFont(AppTheme.Typography.Number.metric, design: .monospaced)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .padding(.horizontal, AppTheme.Spacing.m)
                    .padding(.vertical, AppTheme.Spacing.s)
                    .background {
                        // The red is a wash over the surface, not a fill of
                        // its own: a translucent red alone would let the
                        // grey canvas through and read muddy, not light.
                        let shape = RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                        ZStack {
                            shape.fill(AppTheme.Palette.bgSurface)
                            shape.fill(AppTheme.Palette.statusNegative.opacity(isRejected ? AppTheme.Opacity.fill : 0))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                            .strokeBorder(PublicSchema.AccountScope.household.tint, lineWidth: 1.5)
                            .opacity(index == activeIndex ? 1 : 0)
                    }
            }
        }
        .animation(AppTheme.Motion.quick, value: activeIndex)
        .animation(AppTheme.Motion.colorSafe, value: isRejected)
    }
}
