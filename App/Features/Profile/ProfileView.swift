import KeepoCore
import SwiftUI
import UIKit

/// Everything about *you*, in one screen: who you are at the top, then what
/// the app does on your behalf, in widening circles — your household, your
/// automations, how the app presents itself, what it does with your data,
/// where to get help, the legal text, and the two ways out.
///
/// It used to be a hub of four pushes, two of which ("Preferences", "Data &
/// Privacy") were folders rather than screens: each held three or four
/// unrelated settings and existed only because the root had nowhere to put
/// them. Both are gone. A setting that fits on a row is a row here; the
/// things that push are the four that genuinely are screens.
///
/// Reached by tapping the avatar on any tab's scope banner, and presented as
/// a sheet — so the "✕" at the top left closes the whole thing, matching
/// every other modal in the app.
struct ProfileView: View {
    let session: SessionStore
    /// Passed in rather than read from the environment. A sheet's hosting
    /// controller does not inherit `.environment(_:)` applied to the
    /// presenting `TabView` — a non-optional `@Environment(AvatarStore.self)`
    /// here trapped inside `EnvironmentValues.subscript` the instant the
    /// sheet was presented, taking the app down every time the avatar was
    /// tapped. The same reason `ScopeBannerView` reads `AppNavigation` as an
    /// optional; this view is built in exactly one place, so a parameter is
    /// both simpler and impossible to get wrong.
    let avatars: AvatarStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var draftName = ""
    @State private var currencies: [PublicSchema.CurrenciesSelect] = []
    @State private var isPickingAvatar = false
    @State private var isPickingCurrency = false
    @FocusState private var isNamingSelf: Bool

    @AppStorage(AppSettingsKeys.appearanceMode) private var appearanceMode = AppearanceMode.system

    // Internal, not private: `ProfileView+Sections.swift` reads them, and
    // `private` is file-scoped. Same convention as `NeedsReviewPanel`'s own
    // split.
    @State var errorMessage: String?
    @State var isSyncingFX = false
    @State var lastFXSyncedAt: Date?
    @State var isSigningOut = false
    @State var isShowingDeleteConfirmation = false
    @State var isDeletingAccount = false
    @AppStorage(AppSettingsKeys.isFaceIDEnabled) var isFaceIDEnabled = true
    @AppStorage(AppSettingsKeys.isHideBalanceEnabled) var isHideBalanceEnabled = true

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        ZStack {
            AppTheme.Palette.bgCanvas.ignoresSafeArea()
            List {
                identity
                Section {
                    NavigationLink(value: AppNavigation.ProfileDestination.household) {
                        ProfileRowLabel(icon: "icon-home", title: "My Household")
                    }
                    NavigationLink(value: AppNavigation.ProfileDestination.automations) {
                        ProfileRowLabel(icon: "icon-robot", title: "My Automations")
                    }
                }
                general
                dataAndPrivacy
                helpAndSupport
                legal
                exits
                #if DEBUG
                Section("Developer") {
                    NavigationLink {
                        SimulateCaptureView(session: session)
                    } label: {
                        ProfileRowLabel(icon: "hammer", title: "Simulate Capture")
                    }
                    // Walk the setup flow again on a real device without
                    // deleting the app. Clears `onboarded_at` plus the
                    // device-local draft and intro flag — and nothing else,
                    // so the accounts and categories a previous run created
                    // survive (see `ProfileRepository.resetOnboarding`).
                    Button {
                        Task { await replayOnboarding() }
                    } label: {
                        ProfileRowLabel(icon: "hammer", title: "Replay Onboarding")
                    }
                }
                #endif
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("My Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
            }
        }
        .task(id: session.refresh.token) { await load() }
        .task { await loadLastFXSyncedAt() }
        .sheet(isPresented: $isPickingCurrency) {
            BaseCurrencySheet(currencies: currencies, selection: baseCurrency)
        }
        .avatarPicker(
            isPresentingOptions: $isPickingAvatar,
            canRemove: session.profile?.avatarPath != nil,
            onPicked: { image in Task { _ = await avatars.replace(with: image, session: session) } },
            onRemove: { Task { await avatars.removeAvatar(session: session) } }
        )
    }

    // MARK: - Who you are

    /// Avatar, name, email, and the date you joined — centred, and the only
    /// part of the screen that is not a list of settings. The name is a
    /// **text field**, not a row that pushes a form: it is one line of text
    /// with nothing else to configure, so a form containing it would be a
    /// screen over a screen already showing the field.
    #if DEBUG
    private func replayOnboarding() async {
        guard let userId = session.profile?.id else { return }
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.onboardingDraft)
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.hasSeenIntro)
        try? await ProfileRepository.resetOnboarding(client: session.client, userId: userId)
        // The phase is derived from the profile, so nothing moves until it
        // is re-read — the sheet dismisses itself on the way out because
        // `RootView` swaps the whole signed-in shell underneath it.
        try? await session.refreshProfile()
        dismiss()
    }
    #endif

    private var identity: some View {
        Section {
            VStack(spacing: AppTheme.Spacing.s) {
                // Shared with onboarding's first step — see `AvatarButton`,
                // which is where the camera badge's own reasoning now lives.
                AvatarButton(
                    name: session.profile?.displayName, email: session.userEmail,
                    image: avatars.image, isBusy: avatars.isBusy
                ) {
                    isPickingAvatar = true
                }

                // Their own stack, tighter than the one around it. Name and
                // email are one thing — who you are — and at the outer `s`
                // they read as two unrelated lines that happen to be
                // stacked.
                VStack(spacing: AppTheme.Spacing.xxs) {
                    TextField("Add your name", text: $draftName)
                        .font(AppTheme.Typography.cardTitle)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .textContentType(.givenName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isNamingSelf)
                        .onSubmit { Task { await commitName() } }
                        // Blur commits too: tapping away from a name just
                        // typed means the edit is finished, and losing it
                        // there would be the surprise.
                        .onChange(of: isNamingSelf) { wasEditing, _ in
                            if wasEditing { Task { await commitName() } }
                        }

                    Text(session.userEmail ?? "—")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }

                metrics

                if let message = errorMessage ?? avatars.lastError {
                    FormErrorText(message: message)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, AppTheme.Spacing.m)
            .listRowBackground(Color.clear)
            // Zeroed on purpose. A grouped list insets a row's *content*
            // inside the rounded tile it draws, which is right for a label
            // and wrong for the two cards below: they are tiles themselves,
            // and inset a second time they sat visibly narrower than every
            // row under them. With no inset the row spans the section's own
            // rectangle, so a card's edge and a row tile's edge are the same
            // line.
            .listRowInsets(EdgeInsets())
        }
        // The cards are tiles, and the rows below them are tiles; a grouped
        // list's default section gap is sized for a *header* to sit in, and
        // there is none here. `m` is the gap between the two cards
        // themselves, so the whole block reads as one grid rather than as a
        // header floating above a list.
        .listSectionSpacing(AppTheme.Spacing.m)
    }

    /// Money rule 5: a value that cannot be computed renders as `—`, never as
    /// a plausible-looking guess. A profile with an unparseable `created_at`
    /// has no join date, and "since January 1970" would be a lie with a date
    /// on it.
    private var memberSince: String {
        guard let createdAt = session.profile?.createdAt,
              let date = PostgresDate.date(fromTimestamp: createdAt) else { return "—" }
        return date.formatted(.dateTime.month(.wide).year())
    }

    /// The two facts about the account that are worth reading rather than
    /// configuring: when you joined, and what everything in the app is
    /// converted into. Side by side under the name, as cards, because a
    /// settings row is the shape of something you change and the join date
    /// is not — and the base currency, which *is* a setting, is the single
    /// one that changes the meaning of every number on every other screen.
    private var metrics: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            ProfileMetricCard(title: "Keepo member since") {
                Text(memberSince)
                    .font(AppTheme.Typography.cardTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
            }

            ProfileMetricCard(
                title: "Base currency",
                action: { isPickingCurrency = true },
                content: {
                    if let code = session.profile?.baseCurrency, !code.isEmpty {
                        // `icon`, not `glyph`: this is the card's headline,
                        // the peer of the join date's `cardTitle` beside it,
                        // and at badge size it read as a caption under one.
                        // The badge scales its own code from the disc, so
                        // the letters come up with it.
                        CurrencyBadge(code: code, diameter: AppTheme.Size.icon)
                    } else {
                        Text("—")
                            .font(AppTheme.Typography.cardTitle)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                }
            )
        }
        // Two cards, one shape. Each card already asks for all the height it
        // is offered (`maxHeight: .infinity` inside `ProfileMetricCard`);
        // this pins how much that is to the taller card's *ideal* height
        // rather than letting the pair stretch to whatever the list row
        // gives them. A date is one line and a currency badge is a 24pt
        // disc, so without it the two cards were visibly different heights.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, AppTheme.Spacing.s)
    }

    // MARK: - Writes

    /// Silently no-ops on an unchanged or empty name — an empty field means
    /// "I have not set one", which is the same state a fresh profile is in,
    /// not an instruction to erase the one already there.
    private func commitName() async {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        guard let userId = session.profile?.id else { return }
        guard !trimmed.isEmpty, trimmed != session.profile?.displayName else {
            draftName = session.profile?.displayName ?? ""
            return
        }
        errorMessage = nil
        do {
            try await ProfileRepository.updateDisplayName(
                client: session.client, userId: userId, displayName: trimmed
            )
            try await session.refreshProfile()
        } catch {
            errorMessage = UserFacingError.describe(error)
            draftName = session.profile?.displayName ?? ""
        }
    }

    /// A binding rather than `@State` plus an `onChange`: the picker's only
    /// job is to write this, and a separate selection variable would need
    /// seeding, guarding against its own first assignment, and re-seeding on
    /// every refresh — which is exactly where the old Preferences screen's
    /// `guard oldValue != newValue, !oldValue.isEmpty` came from.
    private var baseCurrency: Binding<String> {
        Binding(
            get: { session.profile?.baseCurrency ?? "" },
            set: { code in
                guard let userId = session.profile?.id, code != session.profile?.baseCurrency else { return }
                Task { await saveBaseCurrency(code, userId: userId) }
            }
        )
    }

    private func saveBaseCurrency(_ code: String, userId: UUID) async {
        errorMessage = nil
        do {
            try await ProfileRepository.updateBaseCurrency(
                client: session.client, userId: userId, baseCurrency: code
            )
            try await session.refreshProfile()
            session.refresh.bump()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
    }

    private func load() async {
        currencies = (try? await session.dbQueue.read { database in
            try LocalTableQueries.currencies(database)
        }) ?? []
        // Never while the caret is in the field: a sync pull landing
        // mid-rename would otherwise replace what is being typed with what
        // the server still has.
        if !isNamingSelf {
            draftName = session.profile?.displayName ?? ""
        }
        await avatars.load(path: session.profile?.avatarPath, client: session)
    }

    // MARK: - Settings

    private var general: some View {
        Section {
            NavigationLink(value: AppNavigation.ProfileDestination.notifications) {
                ProfileRowLabel(icon: "icon-bell", title: "Notifications")
            }
            // A toggle, not the three-way System/Light/Dark picker this
            // replaces. Until it is touched the app still follows iOS, and
            // the toggle reflects whichever way that resolved — so its first
            // position is never a surprise. Touching it pins the choice.
            Toggle(isOn: isDarkMode) {
                ProfileRowLabel(icon: "moon", title: "Dark Mode")
            }
            .tint(AppTheme.Palette.statusPositive)
        } header: {
            Text("General")
        }
    }

    private var isDarkMode: Binding<Bool> {
        Binding(
            get: { appearanceMode == .dark || (appearanceMode == .system && colorScheme == .dark) },
            set: { appearanceMode = $0 ? .dark : .light }
        )
    }
}
