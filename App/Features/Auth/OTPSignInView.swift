import KeepoCore
import SwiftUI
import UIKit

/// Interim sign-in (before SIWA): collects an email address, triggers
/// Supabase's magic-link flow, then waits. When the user taps the link in
/// their email app, iOS hands the `com.manuogm.keepo://auth-callback` URL to
/// `RootView.onOpenURL`, which calls `SessionStore.handleMagicLink(url:)` and
/// advances the phase automatically — this view does nothing to complete auth.
///
/// **This is the first thing anyone sees, and the highest-attrition moment
/// in the whole flow**: the user has to leave Keepo, find an email, and
/// come back, with nothing before it to have earned that. Nothing here can
/// fix the round trip — only Sign in with Apple can, and it is the single
/// highest-value unblock for this flow. What this screen can do is carry
/// the whole first impression on its own: the mark and welcome say what
/// Keepo is, the waiting state says exactly what is happening, and every
/// dead end has an escape (resend, open Mail, wrong address).
///
/// The screen is the splash's teal carried into a header — the app icon's
/// white K and a rounded welcome, on `launchBackground` — with the form on
/// the ordinary canvas below, so it still follows dark mode. Sending the
/// link does not leave the screen: the field and button give way to "Check
/// your email" in the same place, under the same header.
struct OTPSignInView: View {
    let session: SessionStore

    private enum Step { case email, waiting }

    /// Long enough that a second tap is a real decision rather than
    /// impatience with a mail server, short enough not to strand someone
    /// whose first link genuinely never arrived.
    private static let resendCooldown = 30

    @State private var email = ""
    @State private var step: Step = .email
    @State private var isLoading = false
    @State private var actionError: ActionError?
    @State private var secondsUntilResend = 0
    /// The typed address failed `EmailAddress.isPlausible` on Continue. The
    /// message under the field stays until the user types again; the red
    /// wash only lasts while the refused text is still in the field, which
    /// empties itself after the shake.
    @State private var isEmailRejected = false
    /// Bumped once per refusal — drives the shake and the haptic, so a
    /// second refusal of the same text still shakes.
    @State private var emailRejections = 0

    @FocusState private var isEditingEmail: Bool

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }

    /// The form sits at the centre of the screen, with the header filling
    /// everything above it: the header and the space below the form are
    /// both flexible, so they split what is left equally. That keeps it
    /// centred in whatever is *visible* — with the keyboard up (it is, from
    /// the moment the screen appears), the form re-centres above it and the
    /// header gives up the height.
    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch step {
                case .email: emailStep
                case .waiting: waitingStep
                }
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.xxl)
            // Its full height first, always: the two flexible frames around
            // it share only what is left. Without this the stack squeezed
            // the waiting step's message down to a truncated two lines.
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)

            // Not a `Spacer`: a stack hands a `Spacer` only what a
            // `maxHeight: .infinity` sibling leaves, which is nothing — the
            // header took every point and the form sank to the bottom. Two
            // frames of the same flexibility split it evenly.
            Color.clear.frame(maxHeight: .infinity)
        }
        .background(AppTheme.Palette.bgCanvas.ignoresSafeArea())
        .animation(AppTheme.Motion.standard, value: step)
        // Work that was asked for and did not happen: a send that failed,
        // or a stale or already-used link arriving back through the deep
        // link. Validation of the typed address stays inline, under the
        // field the user is looking at.
        .errorAlert($actionError)
        .onChange(of: session.linkError, initial: true) { _, message in
            guard let message else { return }
            actionError = ActionError(title: "Couldn't Sign You In", message: message)
        }
    }

    /// The splash's teal, from the top edge of the screen down to the form.
    /// Only the *background* ignores the safe area, so the mark is centred
    /// in the visible part of the header, clear of the Dynamic Island,
    /// without reading an inset.
    ///
    /// The mark gives way first when the header is short — a small phone
    /// with the keyboard up — so the welcome is never clipped.
    private var header: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: AppTheme.Spacing.l) {
                Image("LaunchMark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: AppTheme.Size.illustration)
                    .accessibilityHidden(true)
                welcome
            }
            welcome
        }
        .padding(.vertical, AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            UnevenRoundedRectangle(
                bottomLeadingRadius: AppTheme.Radius.surface,
                bottomTrailingRadius: AppTheme.Radius.surface,
                style: .continuous
            )
            .fill(AppTheme.Palette.launchBackground)
            .ignoresSafeArea(edges: .top)
        }
    }

    private var welcome: some View {
        Text("Welcome to Keepo")
            .font(AppTheme.Typography.headerTitle)
            .foregroundStyle(AppTheme.Palette.textOnAccent)
            .multilineTextAlignment(.center)
    }

    // MARK: - Ask

    private var emailStep: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            VStack(spacing: AppTheme.Spacing.s) {
                TextField("Email address", text: $email)
                    .font(AppTheme.Typography.body)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($isEditingEmail)
                    .onSubmit { Task { await sendLink() } }
                    .padding(AppTheme.Spacing.m)
                    .background {
                        // The red is a wash over the surface, not a fill of
                        // its own — the pairing code's cards do the same.
                        let shape = RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                        ZStack {
                            shape.fill(AppTheme.Palette.bgSurface)
                            shape.fill(AppTheme.Palette.statusNegative.opacity(
                                isEmailRejected && !email.isEmpty ? AppTheme.Opacity.fill : 0
                            ))
                        }
                    }
                    .modifier(ShakeEffect(rejections: emailRejections))
                    // Typing again is what clears the message — not the
                    // field emptying itself after the shake, which leaves
                    // the reason on screen for the next attempt.
                    .onChange(of: email) { _, newValue in
                        if !newValue.isEmpty { isEmailRejected = false }
                    }

                if isEmailRejected {
                    FormErrorText(message: "Invalid input. Enter a valid email address")
                }
            }
            .animation(AppTheme.Motion.colorSafe, value: isEmailRejected)
            .animation(AppTheme.Motion.colorSafe, value: email.isEmpty)
            .sensoryFeedback(AppTheme.Feedback.rejection, trigger: emailRejections)
            // The refused address shakes in red, then empties so the field
            // is ready for the next one — the pairing code's rhythm. Only if
            // it is still the refused text: anything typed during the hold
            // is the user's next attempt, not something to throw away.
            .task(id: emailRejections) {
                guard isEmailRejected else { return }
                let refused = email
                try? await Task.sleep(for: ShakeEffect.rejectionHold)
                guard !Task.isCancelled, email == refused else { return }
                email = ""
            }

            // The same button every setup step uses — this is one step of
            // one flow, and a sign-in button that looked like a different
            // product's would say so. Only its fill changes, to the header's.
            PrimaryActionButton(
                title: "Continue", isEnabled: !trimmedEmail.isEmpty, isLoading: isLoading, fillsWidth: true,
                fill: AppTheme.Palette.launchBackground
            ) {
                Task { await sendLink() }
            }
        }
        // The field is the screen's whole job, so it owns the keyboard from
        // the moment the screen appears.
        .onAppear { isEditingEmail = true }
    }

    private var canSend: Bool { !trimmedEmail.isEmpty && !isLoading }

    // MARK: - Wait

    private var waitingStep: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Image(systemName: "envelope.badge")
                .font(AppTheme.Typography.screenTitle.weight(.regular))
                .imageScale(.large)
                .foregroundStyle(AppTheme.Palette.brandPrimary)

            Text("Check your email")
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            // The address is shown because the commonest failure by far is
            // having typed it wrong, and the user cannot spot that unless
            // it is in front of them.
            Text("We sent a sign-in link to **\(trimmedEmail)**. Tap it and you're in — it may take a minute.")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Size.proseWidth)

            openMailButton

            VStack(spacing: AppTheme.Spacing.s) {
                resendButton
                Button("Wrong address?") {
                    step = .email
                    secondsUntilResend = 0
                    isEditingEmail = true
                }
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
    }

    /// `message://` is Mail's own scheme. It is offered rather than assumed:
    /// a user whose mail lives in Gmail or Outlook would be sent to an app
    /// they do not use, so this is a convenience beside the instruction,
    /// never a step in it.
    @ViewBuilder
    private var openMailButton: some View {
        if let mail = URL(string: "message://"), UIApplication.shared.canOpenURL(mail) {
            Button("Open Mail") { UIApplication.shared.open(mail) }
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)
        }
    }

    /// The countdown is visible on purpose. A Resend button that silently
    /// does nothing for thirty seconds reads as broken, and the user taps
    /// it again — which is the behaviour the cooldown exists to prevent.
    private var resendButton: some View {
        Button {
            Task { await sendLink() }
        } label: {
            if isLoading {
                ProgressView()
            } else if secondsUntilResend > 0 {
                Text("Resend in \(secondsUntilResend)s")
            } else {
                Text("Resend link")
            }
        }
        .font(AppTheme.Typography.caption)
        .foregroundStyle(
            secondsUntilResend > 0 ? AppTheme.Palette.textSecondary : AppTheme.Palette.textPrimary
        )
        .disabled(isLoading || secondsUntilResend > 0)
    }

    // MARK: - Sending

    private func sendLink() async {
        guard canSend else { return }
        guard EmailAddress.isPlausible(trimmedEmail) else {
            isEmailRejected = true
            withAnimation(AppTheme.Motion.reject) { emailRejections += 1 }
            return
        }
        isLoading = true
        do {
            try await session.sendOTP(email: trimmedEmail)
            step = .waiting
            isEditingEmail = false
            isLoading = false
            await startCooldown()
        } catch {
            actionError = ActionError("Couldn't Send the Link", error)
            isLoading = false
        }
    }

    /// Driven here rather than by a `Timer`, so it cancels with the view and
    /// cannot outlive the screen that shows it.
    private func startCooldown() async {
        secondsUntilResend = Self.resendCooldown
        while secondsUntilResend > 0 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            secondsUntilResend -= 1
        }
    }
}
