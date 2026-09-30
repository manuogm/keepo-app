import KeepoCore
import SwiftUI

/// The drop-down's multi-select axes, one sheet each.
///
/// **Sheets rather than menus, because these tick several.** A `Menu`
/// dismisses on every tap, so picking three categories through one means
/// opening it three times; and a menu cannot draw a category's icon in its
/// own colour, which is how a category is recognised. Each sheet stays open
/// until it is confirmed, which is also what makes "all of them" expressible
/// — see `FilterSelection` for why that is `nil` rather than every id ticked.
///
/// **Each one edits a draft and commits it on the checkmark**, the same
/// contract `CustomRangeSheet` has: the cross leaves the ledger exactly as it
/// was, and so does a swipe down. That is what makes a cancel meaningful —
/// while these wrote straight through, every tick re-queried the list behind
/// the sheet and there was nothing to cancel back to. Confirming now reloads
/// the ledger once instead of once per tick.
///
/// The sheets are canvas-coloured, unlike the panel that opens them: a sheet
/// is its own surface, so it uses the app's ordinary `CheckboxRow` and
/// `CategoryChoiceTile` rather than the panel's white-on-brand vocabulary.

/// Every category as the tiles the transaction form already picks from, with
/// "All categories" over them.
///
/// Split by kind, because an alphabetical grid mixing "Salary" in among the
/// expense categories reads as one flat list of things that are not the same
/// thing. The headers appear only when the user actually has both kinds.
struct CategoryFilterSheet: View {
    let categories: [PublicSchema.CategoriesSelect]
    /// What the filter holds on the way in. The sheet never writes it — see
    /// `onCommit`, and this file's own header for why.
    let selection: Set<UUID>?
    let onCommit: (Set<UUID>?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: Set<UUID>?

    init(
        categories: [PublicSchema.CategoriesSelect],
        selection: Set<UUID>?,
        onCommit: @escaping (Set<UUID>?) -> Void
    ) {
        self.categories = categories
        self.selection = selection
        self.onCommit = onCommit
        _draft = State(initialValue: selection)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.s), count: 3)

    private func rows(of kind: PublicSchema.CategoryKind) -> [PublicSchema.CategoriesSelect] {
        categories.filter { $0.kind == kind }
    }

    private var showsKindHeaders: Bool {
        !rows(of: .expense).isEmpty && !rows(of: .income).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                        CheckboxRow(title: "All categories", isOn: draft == nil) { draft = nil }
                        section("Expenses", rows(of: .expense))
                        section("Income", rows(of: .income))
                    }
                    .padding(AppTheme.Spacing.l)
                }
            }
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { filterSheetToolbar(dismiss: dismiss) { onCommit(draft) } }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [PublicSchema.CategoriesSelect]) -> some View {
        if !rows.isEmpty {
            if showsKindHeaders {
                Text(title)
                    .font(AppTheme.Typography.label)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .padding(.top, AppTheme.Spacing.xs)
            }
            LazyVGrid(columns: columns, spacing: AppTheme.Spacing.s) {
                ForEach(rows, id: \.id) { category in
                    CategoryChoiceTile(
                        category: category,
                        isSelected: draft?.contains(category.id) ?? false,
                        diameter: AppTheme.Size.avatar
                    ) {
                        draft = FilterSelection.toggling(category.id, in: draft)
                    }
                }
            }
        }
    }
}

/// A checkbox list for an axis with a handful of fixed options — the type
/// filter's three, the "Added by" filter's two.
///
/// One generic view rather than two nearly-identical ones: the only thing
/// that differs between them is the ids' type, the wording of the "all" row
/// and the titles, and a second copy is how two lists that should behave
/// identically stop doing so.
struct FilterOptionsSheet<ID: Hashable>: View {
    struct Option: Identifiable {
        let id: ID
        let title: String
        /// A `KeepoIcon` asset name, for an answer the app already draws a
        /// glyph for elsewhere — see `CheckboxRow.icon`.
        var icon: String?
    }

    let title: String
    /// What "no filter at all" is called here — "All types", "Anyone".
    let allTitle: String
    let options: [Option]
    let selection: Set<ID>?
    let onCommit: (Set<ID>?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var draft: Set<ID>?

    init(
        title: String,
        allTitle: String,
        options: [Option],
        selection: Set<ID>?,
        onCommit: @escaping (Set<ID>?) -> Void
    ) {
        self.title = title
        self.allTitle = allTitle
        self.options = options
        self.selection = selection
        self.onCommit = onCommit
        _draft = State(initialValue: selection)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        CheckboxRow(title: allTitle, isOn: draft == nil) { draft = nil }
                        ForEach(options) { option in
                            CheckboxRow(
                                title: option.title, isOn: draft?.contains(option.id) ?? false,
                                icon: option.icon
                            ) {
                                draft = FilterSelection.toggling(option.id, in: draft)
                            }
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.l)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { filterSheetToolbar(dismiss: dismiss) { onCommit(draft) } }
        }
        .presentationDetents([.medium])
    }
}

/// Discard and confirm, spelled the way every form in the app spells them: a
/// cross on the leading side, a checkmark on the trailing one, both glyphs
/// rather than words (`TransactionFormView`, `AccountFormView`, the category
/// and export forms). A multi-select cannot dismiss on a tap the way the
/// single-choice pickers do — the tap is one of several answers, not the
/// answer — so these two are the only ways out, and both sheets spell them
/// identically.
///
/// The cross is not decoration: since these sheets edit a draft, it is the
/// difference between changing your mind and having to undo four ticks.
@ToolbarContentBuilder @MainActor
private func filterSheetToolbar(
    dismiss: DismissAction, confirm: @escaping @MainActor () -> Void
) -> some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
        Button { dismiss() } label: { Image(systemName: "xmark") }
            .accessibilityLabel("Discard filter changes")
    }
    ToolbarItem(placement: .confirmationAction) {
        Button {
            confirm()
            dismiss()
        } label: {
            Image(systemName: "checkmark")
        }
        .accessibilityLabel("Apply filter")
    }
}
