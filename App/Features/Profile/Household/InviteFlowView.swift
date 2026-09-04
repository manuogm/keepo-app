import KeepoCore
import SwiftUI

/// Inviting a partner: choose what they get, then hand over the code.
///
/// A flow rather than a button because the question "what does inviting
/// somebody actually give them?" used to have no answer on screen at all —
/// the old Household screen produced a code immediately and left sharing to
/// a row of toggles further down, which meant the moment of consequence and
/// the moment of choice were in different places.
///
/// **Nothing is shared until the code is used.** The selections ride along
/// on the invite and are applied when it is accepted, so an invite that
/// expires unused changes nothing.
struct InviteFlowView: View {
    let session: SessionStore
    var onInvited: () -> Void

    private enum Step: Int, CaseIterable {
        case accounts
        case categories
        case code
    }

    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .accounts
    @State private var accounts: [PublicSchema.AccountsSelect] = []
    @State private var categories: [PublicSchema.CategoriesSelect] = []
    @State private var selectedAccountIds: Set<UUID> = []
    @State private var selectedCategoryIds: Set<UUID> = []
    @State private var token: String?
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                        switch step {
                        case .accounts: accountsPage
                        case .categories: categoriesPage
                        case .code: codePage
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
                .safeAreaInset(edge: .bottom) { footer }
            }
            .navigationTitle("Invite a Partner")
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

    private var accountsPage: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            ShareStepHeader(
                title: "Which accounts?",
                subtitle: "A shared account is visible and editable by both of you — balances, "
                    + "transactions, everything on it. Anything you leave out stays yours alone.",
                step: Step.accounts.rawValue, total: Step.allCases.count
            )
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
                title: "Which categories?",
                subtitle: "A shared category is one category on both phones — rename it and it "
                    + "renames for them too. It shares the label, not your spending: only shared "
                    + "accounts show their transactions.",
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
                    isSelected: selectedCategoryIds.contains(category.id)
                ) { toggle(category.id, in: &selectedCategoryIds) }
            }
        }
    }

    private var codePage: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            ShareStepHeader(
                title: token == nil ? "Ready to invite" : "Send them this code",
                subtitle: token == nil
                    ? summary
                    : "It works once and expires in seven days. Nothing is shared until they use it.",
                step: Step.code.rawValue, total: Step.allCases.count
            )

            if let token {
                FormCard {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                        Text(token)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .foregroundStyle(AppTheme.Palette.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ShareLink(item: token) {
                            HStack(spacing: AppTheme.Spacing.s) {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share Code")
                            }
                            .font(AppTheme.Typography.labelEmphasis)
                            .foregroundStyle(AppTheme.Palette.textPrimary)
                        }
                    }
                }
            }
        }
    }

    /// What they are about to agree to, in words, on the last screen before
    /// it becomes true — the review step this flow exists to provide.
    private var summary: String {
        let accountCount = selectedAccountIds.count
        let categoryCount = selectedCategoryIds.count
        if accountCount == 0 && categoryCount == 0 {
            return "They'll join your household, and you'll share nothing yet. "
                + "You can share accounts and categories any time afterwards."
        }
        let accountPart = accountCount == 1 ? "1 account" : "\(accountCount) accounts"
        let categoryPart = categoryCount == 1 ? "1 category" : "\(categoryCount) categories"
        return "They'll get \(accountPart) and \(categoryPart) when they accept."
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch step {
        case .accounts:
            ShareStepFooter(title: "Continue") { step = .categories }
        case .categories:
            ShareStepFooter(title: "Continue") { step = .code }
        case .code:
            if token == nil {
                ShareStepFooter(title: "Create Invite", isBusy: isCreating) {
                    Task { await createInvite() }
                }
            } else {
                ShareStepFooter(title: "Done") {
                    onInvited()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Data

    /// The two "Other" rows are each member's own fallback and the server
    /// refuses to share one, so they are not offered — a control that always
    /// fails is worse than no control.
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

    private func createInvite() async {
        isCreating = true
        errorMessage = nil
        do {
            token = try await HouseholdRepository.createInvite(
                client: session.client,
                accountIds: Array(selectedAccountIds),
                categoryIds: Array(selectedCategoryIds)
            )
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isCreating = false
    }
}
