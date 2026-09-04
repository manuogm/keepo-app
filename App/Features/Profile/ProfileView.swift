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
                baseCurrencySection
                Section {
                    NavigationLink("My Household", value: AppNavigation.ProfileDestination.household)
                    NavigationLink("Automations", value: AppNavigation.ProfileDestination.automations)
                } footer: {
                    Text("Invite a partner, share accounts, or leave — your data is always yours.")
                }
                general
                dataAndPrivacy
                helpAndSupport
                legal
                exits
                #if DEBUG
                Section("Developer") {
                    NavigationLink("Simulate Capture") { SimulateCaptureView(session: session) }
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
    private var identity: some View {
        Section {
            VStack(spacing: AppTheme.Spacing.s) {
                Button {
                    isPickingAvatar = true
                } label: {
                    ProfileAvatarView(
                        name: session.profile?.displayName, email: session.userEmail,
                        image: avatars.image, size: AppTheme.Size.illustration
                    )
                    // The one affordance saying the circle is tappable at
                    // all. Overlaid rather than placed beside it, because a
                    // camera button next to an avatar reads as a second
                    // control rather than as this one's verb.
                    .overlay(alignment: .bottomTrailing) {
                        if avatars.isBusy {
                            ProgressView()
                        } else {
                            Image(systemName: "camera.fill")
                                .font(AppTheme.Typography.nanoEmphasis)
                                .foregroundStyle(AppTheme.Palette.textOnAccent)
                                .frame(width: AppTheme.Size.glyph, height: AppTheme.Size.glyph)
                                .background(AppTheme.Palette.textPrimary, in: Circle())
                                .overlay(Circle().strokeBorder(AppTheme.Palette.bgCanvas, lineWidth: 2))
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(avatars.isBusy)
                .accessibilityLabel("Change profile photo")

                TextField("Add your name", text: $draftName)
                    .font(AppTheme.Typography.cardTitle)
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($isNamingSelf)
                    .onSubmit { Task { await commitName() } }
                    // Blur commits too: tapping away from a name just typed
                    // means the edit is finished, and losing it there would
                    // be the surprise.
                    .onChange(of: isNamingSelf) { wasEditing, _ in
                        if wasEditing { Task { await commitName() } }
                    }

                Text(session.userEmail ?? "—")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)

                Text("Keepo member since \(memberSince)")
                    .font(AppTheme.Typography.micro)
                    .foregroundStyle(AppTheme.Palette.textSecondary)

                if let message = errorMessage ?? avatars.lastError {
                    FormErrorText(message: message)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.m)
            .listRowBackground(Color.clear)
        }
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

    private var baseCurrencySection: some View {
        Section {
            Picker("Base Currency", selection: baseCurrency) {
                ForEach(currencies, id: \.code) { currency in
                    Text(currency.code).tag(currency.code)
                }
            }
        } footer: {
            Text("Every balance and chart converts into your chosen base currency.")
        }
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
            NavigationLink("Notifications", value: AppNavigation.ProfileDestination.notifications)
            // A toggle, not the three-way System/Light/Dark picker this
            // replaces. Until it is touched the app still follows iOS, and
            // the toggle reflects whichever way that resolved — so its first
            // position is never a surprise. Touching it pins the choice.
            Toggle("Dark Mode", isOn: isDarkMode)
                .tint(AppTheme.Palette.statusPositive)
        } header: {
            Text("General")
        } footer: {
            Text("Dark Mode applies to Keepo only, independent of your iOS system setting.")
        }
    }

    private var isDarkMode: Binding<Bool> {
        Binding(
            get: { appearanceMode == .dark || (appearanceMode == .system && colorScheme == .dark) },
            set: { appearanceMode = $0 ? .dark : .light }
        )
    }
}
