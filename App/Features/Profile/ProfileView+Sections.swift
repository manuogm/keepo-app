import KeepoCore
import Supabase
import SwiftUI

// The three settings groups below "General", split out of ProfileView.swift
// for this project's file-length lint — the same precedent as
// `NeedsReviewPanel+Actions.swift` and `TransactionsListView+Loading.swift`.

extension ProfileView {
    /// What the app does with your data, in one place — the contents of the
    /// old "Data & Privacy" screen and the old "Security" screen inside it,
    /// which between them held five settings across two levels of pushing.
    /// Export and Archived are screens and still push; the other three are a
    /// button and two switches, and a screen that exists to hold two
    /// switches is a folder wearing a title bar.
    var dataAndPrivacy: some View {
        Section {
            NavigationLink(value: AppNavigation.ProfileDestination.export) {
                ProfileRowLabel(icon: "square.and.arrow.up", title: "Export")
            }
            NavigationLink(value: AppNavigation.ProfileDestination.archive) {
                ProfileRowLabel(icon: "archivebox", title: "Archived")
            }

            Button {
                Task { await syncFXRates() }
            } label: {
                HStack {
                    if isSyncingFX {
                        ProgressView().id("fx-sync-spinner")
                    } else {
                        ProfileRowLabel(icon: "icon-planet", title: "Sync Exchange Rates")
                    }
                    Spacer()
                    if let lastFXSyncedAt {
                        let relative = ProfileView.relativeFormatter.localizedString(
                            for: lastFXSyncedAt, relativeTo: Date()
                        )
                        Text("Last synced \(relative)")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                }
            }
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .disabled(isSyncingFX)

            // Only offered where it can be honoured. A switch labelled "Enable
            // Face ID" on an account type with no biometric step-up is a
            // promise the app cannot keep.
            if session.authCapabilities.requiresBiometricStepUp {
                Toggle(isOn: $isFaceIDEnabled) {
                    ProfileRowLabel(icon: "faceid", title: "Enable Face ID")
                }
                .tint(AppTheme.Palette.statusPositive)
            }

            Toggle(isOn: $isHideBalanceEnabled) {
                ProfileRowLabel(icon: "icon-hidden", title: "Enable Hiding Balance")
            }
            .tint(AppTheme.Palette.statusPositive)
            .onChange(of: isHideBalanceEnabled) { _, enabled in
                // The button that would normally let the user reveal it
                // again is the very thing being turned off here — force it
                // back on so nothing stays stuck hidden with no
                // affordance to undo it.
                if !enabled { session.isPrivacyMode = false }
            }
        } header: {
            Text("Data and Privacy")
        }
    }

    var helpAndSupport: some View {
        Section {
            ComingSoonRow(icon: "questionmark.circle", title: "FAQ")
            ComingSoonRow(icon: "envelope", title: "Contact the Keepo Team")
            ComingSoonRow(icon: "text.bubble", title: "Give Us Feedback")
        } header: {
            Text("Help and Support")
        }
    }

    var legal: some View {
        Section {
            ComingSoonRow(icon: "doc.text", title: "Terms and Conditions")
            ComingSoonRow(icon: "hand.raised", title: "Privacy Policy")
        } header: {
            Text("Legal")
        }
    }

    func syncFXRates() async {
        isSyncingFX = true
        do {
            struct SyncBody: Encodable { let days: Int }
            try await session.client.functions.invoke(
                "sync-fx-rates",
                options: FunctionInvokeOptions(body: SyncBody(days: 400))
            )
            session.refresh.bump()
            await loadLastFXSyncedAt()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSyncingFX = false
    }

    var exits: some View {
        Section {
            Button(role: .destructive) {
                Task { await signOut() }
            } label: {
                HStack {
                    ProfileRowLabel(
                        icon: "rectangle.portrait.and.arrow.right",
                        title: "Sign Out",
                        tint: AppTheme.Palette.statusNegative
                    )
                    Spacer()
                    if isSigningOut { ProgressView() }
                }
            }
            .disabled(isSigningOut)

            Button(role: .destructive) {
                isShowingDeleteConfirmation = true
            } label: {
                HStack {
                    ProfileRowLabel(
                        icon: "trash",
                        title: "Delete Account",
                        tint: AppTheme.Palette.statusNegative
                    )
                    Spacer()
                    if isDeletingAccount { ProgressView() }
                }
            }
            .disabled(isDeletingAccount)
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes all your financial data, accounts, and transactions. "
                    + "You will be signed out immediately. This cannot be undone."
            )
        }
    }

    func signOut() async {
        isSigningOut = true
        errorMessage = nil
        do {
            try await session.signOut()
        } catch {
            errorMessage = UserFacingError.describe(error)
            isSigningOut = false
        }
    }

    func deleteAccount() async {
        isDeletingAccount = true
        errorMessage = nil
        do {
            try await session.stepUp(reason: "Confirm account deletion")
            try await session.deleteAccount()
        } catch {
            errorMessage = UserFacingError.describe(error)
            isDeletingAccount = false
        }
    }

    func loadLastFXSyncedAt() async {
        lastFXSyncedAt = try? await FxRateRepository.latestFetchedAt(client: session.client)
    }
}

/// A row for something the app will do and does not do yet.
///
/// Drawn rather than hidden because the absence is itself information: a
/// settings screen with no Privacy Policy row reads as an app that has not
/// thought about one, and these are the five places a user will look first
/// when they want help or want to complain. It is deliberately **not**
/// tappable — a row that opens an alert saying "coming soon" makes the user
/// do work to learn what the label beside it already told them.
struct ComingSoonRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack {
            // Grey, not brand-coloured: the glyph belongs to a row that is
            // deliberately inert, and a live-looking icon beside a dead
            // label is the mixed signal the "Soon" chip exists to avoid.
            ProfileRowLabel(icon: icon, title: title, tint: AppTheme.Palette.textSecondary)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Spacer()
            Text("Soon")
                .font(AppTheme.Typography.nanoEmphasis)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .padding(.horizontal, AppTheme.Spacing.s)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(Capsule().fill(AppTheme.Palette.fillSubtle))
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Coming soon")
    }
}
