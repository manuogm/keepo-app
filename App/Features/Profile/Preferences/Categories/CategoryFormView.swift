import KeepoCore
import SwiftUI

/// Create and edit share one form, mirroring `AccountFormView` — including
/// its shape: a `ScrollView` of cards rather than a labelled `Form`, the big
/// tappable icon standing in for an "Icon" section plus a "Color" section,
/// and one centred destructive action at the bottom.
///
/// Kind is locked once a category exists, same reasoning as an account's
/// currency being locked on edit: `sign_matches_category_kind` ties every
/// transaction already referencing this category to its current kind, so
/// changing it would invalidate history rather than just this row.
///
/// Edit mode carries the whole row, not just an id — unlike
/// `AccountFormView`, there's no separate "raw row vs. enriched view" split
/// for categories (`CategoriesSelect` already has every field this form
/// needs), so the caller's already-loaded list row is reused directly and
/// no fetch is needed to open this sheet at all. That is also why this form
/// never shows a loading spinner.
struct CategoryFormView: View {
    let session: SessionStore
    var mode: Mode = .create(kind: .expense)
    var onSaved: () -> Void

    enum Mode {
        /// The kind is decided by whichever tab the user was on when they
        /// tapped "+", not by a control inside this sheet — asking twice for
        /// something already answered is exactly the redundant labelling this
        /// redesign is removing.
        case create(kind: PublicSchema.CategoryKind)
        case edit(PublicSchema.CategoriesSelect)
    }

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: PublicSchema.CategoryKind = .expense
    @State private var icon = CategoryAppearance.defaultIcon(forName: "", kind: .expense)
    @State private var color = Color(hex: CategoryAppearance.randomColor())
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isPickingIcon = false
    /// True once the user has opened the catalogue and chosen for
    /// themselves, which is what stops the name-driven icon suggestion from
    /// overwriting a deliberate choice.
    @State private var hasPickedIcon = false

    @State private var deleteTransactionCount = 0
    @State private var isCheckingDelete = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// Locked, not just hidden — the DB's own `prevent_default_category_
    /// deletion` trigger refuses both, this only keeps the UI honest about
    /// what will happen.
    private var isDefaultCategory: Bool {
        if case .edit(let category) = mode { return category.isDefault }
        return false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        IconPickerButton(icon: icon, color: color) { isPickingIcon = true }
                            .padding(.top, 8)

                        identityCard

                        if isDefaultCategory {
                            Text("The default category can't be renamed or deleted.")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                // Same reasoning as `AccountFormView`: the destructive action
                // belongs at the bottom of the SHEET, one predictable place,
                // not at the bottom of however much content there happens to be.
                .safeAreaInset(edge: .bottom) {
                    if isEditing && !isDefaultCategory {
                        DestructiveActionButton(
                            title: "Delete Category", isEnabled: !isCheckingDelete && !isDeleting
                        ) {
                            Task { await confirmDelete() }
                        }
                        .overlay(alignment: .trailing) {
                            if isCheckingDelete {
                                ProgressView().controlSize(.small).padding(.trailing, 20)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                        .background(.bar)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Category" : "New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .sheet(isPresented: $isPickingIcon) {
                IconCatalogView(icon: $icon, color: $color)
            }
            // Visiting the catalogue at all counts as choosing: from that
            // point the name-driven suggestion stops overriding what is on
            // screen, whether the user changed it or confirmed it.
            .onChange(of: isPickingIcon) { _, isPresented in
                if !isPresented { hasPickedIcon = true }
            }
            .alert("Delete \"\(name)\"?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    Task { await performDelete() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    deleteTransactionCount > 0
                        ? "\(deleteTransactionCount) transaction"
                            + "\(deleteTransactionCount == 1 ? "" : "s") will move to Other."
                        : "This category has no transactions."
                )
            }
        }
        .task { prefill() }
    }

    private var identityCard: some View {
        FormCard {
            TextField("Category Name", text: $name)
                .font(.title3.weight(.medium))
                .textInputAutocapitalization(.words)
                .disabled(isDefaultCategory)
                .foregroundStyle(isDefaultCategory ? Color.secondary : Color.primary)
                // Only while creating, and only until the user picks
                // something themselves — typing "Groceries" suggesting a
                // cart is helpful; silently reverting a chosen icon on the
                // next keystroke is not.
                .onChange(of: name) { _, newValue in
                    guard !isEditing, !hasPickedIcon else { return }
                    icon = CategoryAppearance.defaultIcon(forName: newValue, kind: kind)
                }
        }
    }

    private func prefill() {
        switch mode {
        case .edit(let category):
            name = category.name
            kind = category.kind
            icon = category.icon
            color = Color(hex: category.color)
            hasPickedIcon = true
        case .create(let createKind):
            kind = createKind
            icon = CategoryAppearance.defaultIcon(forName: "", kind: createKind)
        }
    }

    /// Goes through `session.outbox`, never `CategoryRepository` directly —
    /// same reasoning as AccountFormView's writes: an offline create/edit
    /// queues instead of erroring.
    private func save() async {
        isSaving = true
        errorMessage = nil
        let resolvedColor = color.hexString ?? CategoryAppearance.randomColor()
        switch mode {
        case .create:
            guard let userId = session.profile?.id else { return }
            let payload = CreateCategoryPayload(
                id: UUID(), ownerId: userId, kind: kind, name: name, icon: icon, color: resolvedColor
            )
            await session.outbox.submitCreateCategory(payload)
        case .edit(let category):
            let payload = UpdateCategoryPayload(id: category.id, name: name, icon: icon, color: resolvedColor)
            await session.outbox.submitUpdateCategory(payload)
        }
        onSaved()
        dismiss()
        isSaving = false
    }

    /// Reads a live transaction count before showing the warning — offline,
    /// this throws and surfaces the existing "you appear to be offline"
    /// message rather than presenting a stale or missing count, which is
    /// exactly why category deletion is never routed through the outbox
    /// (see CategoryRepository.deleteWithReassign's own header comment).
    private func confirmDelete() async {
        guard case .edit(let category) = mode else { return }
        isCheckingDelete = true
        errorMessage = nil
        do {
            deleteTransactionCount = try await CategoryRepository.transactionCount(
                client: session.client, categoryId: category.id
            )
            showDeleteConfirm = true
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isCheckingDelete = false
    }

    /// B: the RPC itself stays online-only (see `deleteWithReassign`'s own
    /// header comment — the live count this confirms against is only
    /// honest live), but a successful call still needs to be echoed into
    /// the local mirror immediately, exactly like every outbox write
    /// already is — otherwise this screen's `onSaved()`/`dismiss()` fires
    /// before the next sync pull, and the category stays visible locally
    /// until one happens. Mirrors the server's own two-statement effect:
    /// reassign local transactions off this category, then soft-delete it.
    private func performDelete() async {
        guard case .edit(let category) = mode else { return }
        isDeleting = true
        errorMessage = nil
        do {
            try await CategoryRepository.deleteWithReassign(client: session.client, categoryId: category.id)
            if let ownerId = session.profile?.id {
                try? await session.dbQueue.write { database in
                    try CategoryLocalWrite.deleteAndReassignToOther(
                        categoryId: category.id, kind: category.kind, ownerId: ownerId, in: database
                    )
                }
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isDeleting = false
    }
}
