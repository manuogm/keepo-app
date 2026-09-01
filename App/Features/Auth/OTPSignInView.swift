import KeepoCore
import SwiftUI

/// Interim sign-in screen (before SIWA): collects an email address, triggers
/// Supabase's magic-link flow, then waits. When the user taps the link in
/// their email app, iOS hands the `com.manuogm.keepo://auth-callback` URL to
/// `RootView.onOpenURL`, which calls `SessionStore.handleMagicLink(url:)` and
/// advances the phase automatically — this view does nothing to complete auth.
struct OTPSignInView: View {
    let session: SessionStore

    private enum Step { case email, waiting }

    @State private var email = ""
    @State private var step: Step = .email
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            VStack(spacing: AppTheme.Spacing.xxl) {
                VStack(spacing: AppTheme.Spacing.xs) {
                    Text("Keepo")
                        .font(AppTheme.Typography.screenTitle).fontWeight(.bold)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                    Text("Personal finance, captured automatically.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }

                switch step {
                case .email: emailStep
                case .waiting: waitingStep
                }

                // Errors from a stale/invalid link arriving via deep link
                let linkError = session.linkError ?? errorMessage
                if let linkError {
                    Text(linkError)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.statusNegative)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(AppTheme.Spacing.xl)
        }
    }

    private var emailStep: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Text("Sign in to continue")
                .font(AppTheme.Typography.cardTitle).fontWeight(.semibold)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            TextField("Email address", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button {
                Task { await sendLink() }
            } label: {
                Group {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Send Sign-In Link").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.m)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.Palette.textPrimary)
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
        }
    }

    private var waitingStep: some View {
        VStack(spacing: AppTheme.Spacing.l) {
            Image(systemName: "envelope.badge")
                .font(AppTheme.Typography.screenTitle.weight(.regular))
                .imageScale(.large)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            Text("Check your email")
                .font(AppTheme.Typography.cardTitle).fontWeight(.semibold)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            Text(
                "We sent a sign-in link to\n**\(email)**\n\n"
                    + "Tap the link in your email to continue. It may take a minute to arrive."
            )
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await sendLink() }
            } label: {
                if isLoading {
                    ProgressView()
                } else {
                    Text("Resend Link")
                }
            }
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .disabled(isLoading)

            Button("Use a different email") {
                step = .email
                errorMessage = nil
            }
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.Palette.textSecondary)
        }
    }

    private func sendLink() async {
        isLoading = true
        errorMessage = nil
        do {
            try await session.sendOTP(email: email.trimmingCharacters(in: .whitespaces))
            step = .waiting
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }
}
