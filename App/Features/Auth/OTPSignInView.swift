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
/// the whole first impression on its own: the mark and tagline say what
/// Keepo is, the waiting state says exactly what is happening, and every
/// dead end has an escape (resend, open Mail, wrong address).
///
/// The mark is `Typography.Number.hero` — the 48pt size whose own doc
/// comment calls it "the sign-in screen's mark".
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
    @State private var errorMessage: String?
    @State private var secondsUntilResend = 0

    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1
    @FocusState private var isEditingEmail: Bool

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()

            VStack(spacing: AppTheme.Spacing.xxl) {
                Spacer(minLength: 0)
                mark

                switch step {
                case .email: emailStep
                case .waiting: waitingStep
                }

                // A stale or already-used link arrives back here through the
                // deep link, so this covers both that and a send failure.
                if let message = session.linkError ?? errorMessage {
                    Text(message)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.statusNegative)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.xxl)
            .animation(AppTheme.Motion.standard, value: step)
        }
    }

    private var mark: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Text("Keepo")
                .font(AppTheme.Typography.Number.display(
                    AppTheme.Typography.Number.hero, weight: .bold, scale: typeScale
                ))
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Text("Where all your money is kept under control.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Ask

    private var emailStep: some View {
        VStack(spacing: AppTheme.Spacing.l) {
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
                .background(AppTheme.Palette.bgSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.control))

            // The same button every setup step uses — this is one step of
            // one flow, and a sign-in button that looked like a different
            // product's would say so.
            PrimaryActionButton(
                title: "Continue", isEnabled: !trimmedEmail.isEmpty, isLoading: isLoading, fillsWidth: true
            ) {
                Task { await sendLink() }
            }

            // No password to forget, and saying so up front is the reason
            // the next screen is not a surprise.
            Text("We'll email you a link to sign in. No password to remember.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
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
                    errorMessage = nil
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
        isLoading = true
        errorMessage = nil
        do {
            try await session.sendOTP(email: trimmedEmail)
            step = .waiting
            isEditingEmail = false
            await startCooldown()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
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
