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
                Text(code.formatted)
                    .numberFont(AppTheme.Typography.Number.balance)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    // Read aloud, so it should be read out as digits rather
                    // than as one six-figure number.
                    .accessibilityLabel(code.digits.map(String.init).joined(separator: " "))
                Text("Read it to your partner. Keepo will not pair without it.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Somebody is connected and the code has not been answered. Who they
    /// are is deliberately not on this screen — no name, no face — because
    /// nothing has been exchanged yet, and that is the point.
    @ViewBuilder
    var verifyingView: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Spacer()
            if role == .owner {
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

            TextField("000 000", text: $enteredCode)
                .textFieldStyle(.plain)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .numberFont(AppTheme.Typography.Number.balance)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .padding(.vertical, AppTheme.Spacing.m)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AppTheme.Palette.textTertiary.opacity(AppTheme.Opacity.fillStrong))
                        .frame(height: 1)
                }
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
                .foregroundStyle(
                    enteredCode.count == HouseholdPairingCode.digitCount
                        ? AppTheme.Palette.textOnAccent
                        : AppTheme.Palette.textSecondary
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.m)
                .background(
                    enteredCode.count == HouseholdPairingCode.digitCount
                        ? PublicSchema.AccountScope.household.tint
                        : AppTheme.Palette.fillSubtle,
                    in: Capsule()
                )
                .disabled(enteredCode.count != HouseholdPairingCode.digitCount)

            if let rejection = pairing?.codeRejection {
                FormErrorText(message: rejection)
            }
        }
    }

    /// Sends the six digits and empties the field for the next go.
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
        guard let pairing, digits.count == HouseholdPairingCode.digitCount else { return }
        pairing.submitCode(digits)
        enteredCode = ""
    }
}
