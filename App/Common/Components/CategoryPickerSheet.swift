import KeepoCore
import SwiftUI

/// What a form needs to offer a category that does not exist yet from inside
/// the picker: the store that writes it, the kind it would be, and the
/// caller's own re-read once it exists. One value rather than three
/// parameters, same reasoning as `ForeignAmount` — they are meaningless
/// apart, and every screen carrying a category row would otherwise grow
/// three.
///
/// **`nil` wherever creating one here could not work** — see
/// `TransactionFormView.categoryCreation` for the one case that is: a
/// category the viewer creates is private to them, and `AccountCategories`
/// offers a private category no counterpart on somebody else's account. A
/// tile that can only produce a choice the server refuses is worse than no
/// tile.
struct CategoryCreation {
    let session: SessionStore
    /// Which kind the new category is, taken from the tab the form is on
    /// rather than asked again inside the sheet — the same reasoning
    /// `CategoriesView` states for opening `CategoryFormView` per tab.
    let kind: PublicSchema.CategoryKind
    /// Re-reads the caller's own category list from the local mirror.
    /// **Awaited before the selection lands**, so the new category is a tile
    /// the row can draw rather than a gap where one should be: the row
    /// resolves its seats against the list the form holds, and a selection
    /// naming a category that list does not have yet renders as nothing.
    let onCreated: () async -> Void
}

/// Every category for the kind on screen, as the same tiles the form's row
/// is made of — icon, colour, name — rather than as menu text.
///
/// One tap selects, closes, and lands the category in the row's first
/// slot, for the same reason the date picker dismisses on a tap: the tap
/// IS the answer, and a Done button behind it asks the user to confirm a
/// choice they have already made.
///
/// Split out of CategoryPicker.swift for the project's file-length lint once
/// it gained the create flow, same precedent as TransactionFormView+Date.swift.
struct CategoryPickerSheet: View {
    @Binding var selection: UUID?
    let categories: [PublicSchema.CategoriesSelect]
    /// `nil` draws the grid without the "New" tile — see `CategoryCreation`.
    var creation: CategoryCreation?

    @Environment(\.dismiss) private var dismiss

    @State private var isCreatingCategory = false
    /// The category the create form just wrote, held until that form's own
    /// sheet has finished closing. Selecting it and dismissing this sheet
    /// from inside the create form's save would start this sheet's exit
    /// while a sheet above it is still animating away.
    @State private var createdCategoryId: UUID?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.s), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                ScrollView {
                    LazyVGrid(columns: columns, spacing: AppTheme.Spacing.s) {
                        ForEach(categories, id: \.id) { category in
                            CategoryChoiceTile(
                                category: category,
                                isSelected: category.id == selection,
                                diameter: AppTheme.Size.avatar
                            ) {
                                selection = category.id
                                dismiss()
                            }
                        }
                        if creation != nil { newCategoryTile }
                    }
                    .padding(AppTheme.Spacing.l)
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .sheet(isPresented: $isCreatingCategory) { createForm }
            .onChange(of: isCreatingCategory) { _, isPresented in
                guard !isPresented, let id = createdCategoryId else { return }
                createdCategoryId = nil
                Task { await adopt(id) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// **Last cell, dashed ring.**
    ///
    /// Last because the grid is scanned for a category you already have, and
    /// the first seat is where that scan starts: a control in it is read
    /// before every category and chosen less often than any of them. Reaching
    /// it past a long list costs a scroll on the medium detent, which is the
    /// trade being made — the sheet is opened to pick, not to create.
    ///
    /// Dashed because that is already how this app draws "make a new one"
    /// (`AddTagButton`), and because the tile the user tapped to get here is a
    /// solid-ringed plus meaning "more of these". The same glyph twice in one
    /// flow needs the two to be told apart by something.
    private var newCategoryTile: some View {
        Button {
            isCreatingCategory = true
        } label: {
            VStack(spacing: AppTheme.Spacing.s) {
                Image(systemName: "plus")
                    .font(AppTheme.Typography.sectionTitle)
                    .foregroundStyle(AppTheme.Palette.fillStrong)
                    .frame(width: AppTheme.Size.avatar, height: AppTheme.Size.avatar)
                    .overlay {
                        Circle().strokeBorder(
                            AppTheme.Palette.fillStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                    }
                Text("New")
                    .font(AppTheme.Typography.captionEmphasis)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.m)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("New category")
    }

    /// **`CategoryFormView`, not a name field.** A category is a name, an icon
    /// and a colour; that form asks for all three, suggests the icon from the
    /// name, refuses a duplicate before the write leaves the device, and goes
    /// through the outbox so this works offline. The inline row
    /// `TagPickerSheet` uses is right there because a tag genuinely *is* just
    /// a name — here it would have to grow every one of those back.
    @ViewBuilder private var createForm: some View {
        if let creation {
            CategoryFormView(
                session: creation.session,
                mode: .create(kind: creation.kind),
                // The duplicate check compares within one kind, and this is
                // exactly the viewer's own live list for the kind on screen.
                existing: categories,
                onCreated: { createdCategoryId = $0 },
                // Every screen that lists categories gets to see the new one,
                // the same way `CategoriesView` announces its own creates.
                onSaved: { creation.session.refresh.bump() }
            )
        }
    }

    /// A category created here is **selected immediately** — the user made it
    /// while choosing one for this transaction, so making them then tap it
    /// asks twice for one intent. Same contract as a tag created inside
    /// `TagPickerSheet`.
    private func adopt(_ id: UUID) async {
        await creation?.onCreated()
        selection = id
        dismiss()
    }
}
