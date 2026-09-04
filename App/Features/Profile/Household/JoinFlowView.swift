import KeepoCore
import SwiftUI

/// Accepting an invite: see what you are being given, choose what you give
/// back, then join.
///
/// The preview step is the point of the whole flow. Joining a household used
/// to be a code box and a button, and what changed afterwards — which
/// accounts appeared, which categories merged into which — was discoverable
/// only by going and looking. Now it is on screen before the decision.
struct JoinFlowView: View {
    let session: SessionStore
    var onJoined: () -> Void

    private enum Step: Int, CaseIterable {
        case code
        case accounts
        case categories
        case review
    }

    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .code
    @State private var token = ""
    @State var preview: [InvitePreviewRow] = []
    @State private var accounts: [PublicSchema.AccountsSelect] = []
    @State private var categories: [PublicSchema.CategoriesSelect] = []
    @State var selectedAccountIds: Set<UUID> = []
    @State var selectedCategoryIds: Set<UUID> = []
    @State private var isChecking = false
    @State private var isJoining = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                        switch step {
                        case .code: codePage
                        case .accounts: accountsPage
                        case .categories: categoriesPage
                        case .review: reviewPage
                        }

                        if let errorMessage {
                            FormErrorText(message: errorMessage)
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.l)
                    .padding(.top, AppTheme.Spacing.s)
                    .padding(.bottom, AppTheme.Spacing.xl)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom) { footer }
            }
            .navigationTitle("Join a Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .task { await load() }
        }
    }

    // MARK: - Pages

    private var codePage: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            ShareStepHeader(
                title: "Enter the code",
                subtitle: "Your partner created it on their phone. It works once and expires "
                    + "after seven days.",
                step: Step.code.rawValue, total: Step.allCases.count
            )
            FormCard {
                TextField("Invite code", text: $token)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await checkToken() } }
            }
        }
    }

    private var accountsPage: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            ShareStepHeader(
                title: "What you'll get",
                subtitle: incomingSummary,
                step: Step.accounts.rawValue, total: Step.allCases.count
            )

            if !incomingAccountNames.isEmpty {
                FormCard {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                        ForEach(incomingAccountNames, id: \.self) { name in
                            HStack(spacing: AppTheme.Spacing.s) {
                                SharedWithHouseholdIcon()
                                Text(name)
                                    .font(AppTheme.Typography.label)
                                    .foregroundStyle(AppTheme.Palette.textPrimary)
                            }
                        }
                    }
                }
            }

            Text("Which of yours do you want to share back?")
                .font(AppTheme.Typography.labelEmphasis)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            ShareSelectionCard(
                items: accounts, id: \.id,
                emptyMessage: "You have no accounts to share yet."
            ) { account in
                ShareSelectionRow(
                    title: account.name,
                    icon: account.icon,
                    tint: Color(hex: account.color),
                    isSelected: selectedAccountIds.contains(account.id)
                ) { toggle(account.id, in: &selectedAccountIds) }
            }
        }
    }

    private var categoriesPage: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            ShareStepHeader(
                title: "Your categories",
                subtitle: "Anything named the same as one of theirs becomes a single shared "
                    + "category. Anything else stays yours until you share it.",
                step: Step.categories.rawValue, total: Step.allCases.count
            )
            ShareSelectionCard(
                items: shareableCategories, id: \.id,
                emptyMessage: "You have no categories to share yet."
            ) { category in
                ShareSelectionRow(
                    title: category.name,
                    icon: category.icon,
                    tint: Color(hex: category.color),
                    isSelected: selectedCategoryIds.contains(category.id),
                    detail: matchDetail(for: category)
                ) { toggle(category.id, in: &selectedCategoryIds) }
            }
        }
    }

    private var reviewPage: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            ShareStepHeader(
                title: "Ready to join",
                subtitle: "Joining is not permanent — either of you can leave, and leaving forks "
                    + "every shared account back into private copies. Nothing is lost.",
                step: Step.review.rawValue, total: Step.allCases.count
            )
            FormCard {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                    reviewLine("You'll receive", incomingSummary)
                    Divider()
                    reviewLine("You'll share", outgoingSummary)
                }
            }
        }
    }

    private func reviewLine(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(title)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Text(detail)
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch step {
        case .code:
            ShareStepFooter(
                title: "Check Code",
                isEnabled: !token.trimmingCharacters(in: .whitespaces).isEmpty,
                isBusy: isChecking
            ) { Task { await checkToken() } }
        case .accounts:
            ShareStepFooter(title: "Continue") { step = .categories }
        case .categories:
            ShareStepFooter(title: "Continue") { step = .review }
        case .review:
            ShareStepFooter(title: "Join Household", isBusy: isJoining) { Task { await join() } }
        }
    }

    // MARK: - Data

    private var shareableCategories: [PublicSchema.CategoriesSelect] {
        categories.filter { !$0.isDefault }
    }

    private func toggle(_ id: UUID, in set: inout Set<UUID>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func load() async {
        guard let ownerId = session.profile?.id.uuidString else { return }
        let dbQueue = session.dbQueue
        accounts = (try? await dbQueue.read { database in
            try LocalTableQueries.accountsOwnedBy(database, ownerId: ownerId)
        }) ?? []
        categories = (try? await dbQueue.read { database in
            try LocalTableQueries.categories(database, ownerId: ownerId)
        }) ?? []
    }

    /// Validates the code *and* fetches what it carries in one call — a
    /// "check" that only said yes or no would make the user commit before
    /// seeing anything.
    private func checkToken() async {
        isChecking = true
        errorMessage = nil
        do {
            preview = try await HouseholdRepository.previewInvite(
                client: session.client, token: token.trimmingCharacters(in: .whitespaces)
            )
            step = .accounts
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isChecking = false
    }

    private func join() async {
        isJoining = true
        errorMessage = nil
        do {
            try await session.stepUp(reason: "Confirm it's you to join this household")
            _ = try await HouseholdRepository.acceptInvite(
                client: session.client,
                token: token.trimmingCharacters(in: .whitespaces),
                accountIds: Array(selectedAccountIds),
                categoryIds: Array(selectedCategoryIds)
            )
            await session.syncNow()
            onJoined()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isJoining = false
    }
}
