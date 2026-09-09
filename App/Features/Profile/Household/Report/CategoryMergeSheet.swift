import KeepoCore
import SwiftUI

/// Declaring that your category and theirs are the same category — and
/// choosing what the result is called.
///
/// ## Why only one of the two tiles is tappable
///
/// The sheet shows your category on the left and theirs on the right, and only
/// the right one opens a picker. A merge is one act with a direction: you are
/// pointing one of *yours* at one of *theirs*. Making both sides swappable
/// would let the user rebuild the same pair from either end and produce two
/// ways to express one decision — and the one on the left is already fixed by
/// which row's Merge button was pressed.
///
/// ## What actually happens on save
///
/// `apply_category_merges` links the two rows into one `shared_group_id` and
/// writes the resultant name, icon and colour onto both. Nothing is created
/// and nothing changes owner: `transactions (category_id, owner_id) →
/// categories (id, owner_id)` means each member keeps filing under their own
/// row, and the merge is what makes the two rows read as one category.
struct CategoryMergeSheet: View {
    /// What is being merged — an existing pair being edited, or a new merge
    /// starting from one of your unpartnered categories.
    enum Subject: Identifiable {
        case existing(HouseholdMergedCategory)
        case new(HouseholdExtraCategory)

        var id: UUID {
            switch self {
            case .existing(let merged): return merged.groupId
            case .new(let extra): return extra.category.id
            }
        }

        var kind: PublicSchema.CategoryKind {
            switch self {
            case .existing(let merged): return merged.kind
            case .new(let extra): return extra.category.kind
            }
        }

        /// Your own row, which is always the left-hand tile.
        var mine: PublicSchema.CategoriesSelect {
            switch self {
            case .existing(let merged): return merged.mine
            case .new(let extra): return extra.category
            }
        }

        var isExisting: Bool {
            if case .existing = self { return true }
            return false
        }
    }

    let session: SessionStore
    let snapshot: HouseholdSnapshot
    let subject: Subject
    var onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var icon = ""
    /// A `Color`, not the hex string the row carries, because
    /// `IconCatalogView` binds to a `Color` — the same shape the Account and
    /// Category forms hand it. It converts back on save.
    @State private var color = AppTheme.Palette.brandPrimary
    @State private var partner: PublicSchema.CategoriesSelect?
    @State private var isPickingIcon = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.xl) {
                        resultant
                        pairing
                        if let errorMessage { FormErrorText(message: errorMessage) }
                        if subject.isExisting { unmerge }
                    }
                    .padding(.horizontal, AppTheme.Spacing.l)
                    .padding(.top, AppTheme.Spacing.l)
                    .padding(.bottom, AppTheme.Spacing.xl)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle(subject.isExisting ? "Merged Category" : "Merge Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing discards. The check is the commit, and a sheet
                    // where backing out silently saved would make the two
                    // controls mean the same thing.
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Discard")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .disabled(!canSave || isSaving)
                    .accessibilityLabel("Save merge")
                }
            }
            .sheet(isPresented: $isPickingIcon) {
                IconCatalogView(icon: $icon, color: $color)
            }
            .onAppear(perform: seed)
        }
    }

    // MARK: - The result

    private var resultant: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            IconPickerButton(icon: icon, color: color) { isPickingIcon = true }

            TextField("Category name", text: $name)
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)

            Text("Both of you will see this name, icon and colour.")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
    }

    // MARK: - The two sides

    private var pairing: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
            column("Shared by You") {
                MergeCategoryTile(
                    name: subject.mine.name,
                    icon: subject.mine.icon,
                    color: Color(hex: subject.mine.color)
                )
            }

            link

            column("Shared with You") {
                if partnerOptions.isEmpty && partner == nil {
                    // Nothing to merge with. Said in the tile's own place
                    // rather than as an error, because it is not a failure —
                    // it is what "they have no unmatched categories of this
                    // kind" looks like.
                    MergeEmptyTile(label: "Nothing left\nto merge with", isActionable: false)
                } else {
                    Menu {
                        ForEach(partnerOptions, id: \.id) { option in
                            Button {
                                partner = option
                            } label: {
                                Label(option.name, systemImage: option.icon)
                            }
                        }
                    } label: {
                        if let partner {
                            MergeCategoryTile(
                                name: partner.name,
                                icon: partner.icon,
                                color: Color(hex: partner.color),
                                isActionable: true
                            )
                        } else {
                            MergeEmptyTile(label: "Choose one", isActionable: true)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Text(title)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    /// The dotted join, with the link glyph riding on it. The same stroke the
    /// `HouseholdContainer` uses between the two members, for the same
    /// reason: two things, connected, still two.
    private var link: some View {
        VStack {
            Image(systemName: "link")
                .font(AppTheme.Typography.microEmphasis)
                .foregroundStyle(PublicSchema.AccountScope.household.tint)
                .padding(AppTheme.Spacing.xs)
                .background(
                    PublicSchema.AccountScope.household.tint.opacity(AppTheme.Opacity.fill),
                    in: Circle()
                )
        }
        // Level with the middle of the two tiles, below their column labels.
        .padding(.top, AppTheme.Spacing.xxl + AppTheme.Spacing.m)
    }

    // MARK: - Unmerge

    private var unmerge: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            if case .existing(let merged) = subject, merged.isAutomatic {
                HStack(spacing: AppTheme.Spacing.xs) {
                    KeepoIcon(name: "icon-robot", size: AppTheme.Size.glyphNano)
                    Text("Automatically merged")
                }
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            }

            DestructiveActionButton(title: "Unmerge Category", isEnabled: !isSaving) {
                Task { await performUnmerge() }
            }

            Text("Both categories go back to being separate. Neither loses a transaction.")
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Data

    /// The other member's categories of this kind that are not already in a
    /// merge — plus, when editing, the current partner, which would otherwise
    /// be missing from the list of things it is currently set to.
    private var partnerOptions: [PublicSchema.CategoriesSelect] {
        var options = snapshot.extras(subject.kind)
            .filter { !$0.isMine }
            .map(\.category)
        if case .existing(let merged) = subject {
            options.append(merged.theirs)
        }
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var canSave: Bool {
        partner != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func seed() {
        guard name.isEmpty else { return }
        switch subject {
        case .existing(let merged):
            name = merged.name
            icon = merged.icon
            color = Color(hex: merged.color)
            partner = merged.theirs
        case .new(let extra):
            // The result starts as a copy of the category whose Merge button
            // was pressed. It is the one thing the user has already chosen,
            // and starting blank would make them retype what they just
            // pointed at.
            name = extra.category.name
            icon = extra.category.icon
            color = Color(hex: extra.category.color)
        }
    }

    private func save() async {
        guard let partner else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await HouseholdRepository.applyCategoryMerges(
                client: session.client,
                merges: [
                    CategoryMerge(
                        mine: subject.mine.id,
                        theirs: partner.id,
                        name: name.trimmingCharacters(in: .whitespaces),
                        icon: icon,
                        // `hexString` can fail for a colour with no RGB
                        // representation, which the catalogue cannot produce
                        // — falling back to what the row already had keeps
                        // the merge from writing an empty column.
                        color: color.hexString ?? subject.mine.color
                    )
                ],
                automatic: false
            )
            await session.syncNow()
            session.refresh.bump()
            onChange()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }

    private func performUnmerge() async {
        guard case .existing(let merged) = subject else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await HouseholdRepository.unmergeCategoryGroup(
                client: session.client, groupId: merged.groupId
            )
            await session.syncNow()
            session.refresh.bump()
            onChange()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isSaving = false
    }
}
