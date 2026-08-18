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
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 32) {
                VStack(spacing: 4) {
                    Text("Keepo")
                        .font(.largeTitle).fontWeight(.bold)
                        .foregroundStyle(Color.primary)
                    Text("Personal finance, captured automatically.")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }

                switch step {
                case .email: emailStep
                case .waiting: waitingStep
                }

                // Errors from a stale/invalid link arriving via deep link
                let linkError = session.linkError ?? errorMessage
                if let linkError {
                    Text(linkError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(24)
        }
    }

    private var emailStep: some View {
        VStack(spacing: 16) {
            Text("Sign in to continue")
                .font(.title3).fontWeight(.semibold)
                .foregroundStyle(Color.primary)

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
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.primary)
            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
        }
    }

    private var waitingStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 48))
                .foregroundStyle(Color.primary)

            Text("Check your email")
                .font(.title3).fontWeight(.semibold)
                .foregroundStyle(Color.primary)

            Text(
                "We sent a sign-in link to\n**\(email)**\n\n"
                    + "Tap the link in your email to continue. It may take a minute to arrive."
            )
                .font(.callout)
                .foregroundStyle(Color.secondary)
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
            .font(.footnote)
            .foregroundStyle(Color.primary)
            .disabled(isLoading)

            Button("Use a different email") {
                step = .email
                errorMessage = nil
            }
            .font(.footnote)
            .foregroundStyle(Color.secondary)
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
