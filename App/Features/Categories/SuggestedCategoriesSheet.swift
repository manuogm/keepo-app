import KeepoCore
import SwiftUI

/// Onboarding's category catalogue, offered again on the Categories tab to
/// a user who skipped it (`CategoriesView.offersSuggestions`).
///
/// Opens with the same seven ticked that the onboarding step starts with:
/// the user tapped "See categories" because they wanted a starting point,
/// and the short list almost everyone files against is that starting point.
/// Confirming with nothing ticked would add nothing, so the checkmark waits
/// for at least one.
struct SuggestedCategoriesSheet: View {
    let session: SessionStore
    let onAdded: () -> Void

    @State private var selection = DefaultCategoryCatalog.preselected
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    Text("Pick the ones you'll use. You can always add more or change them later.")
                        .font(AppTheme.Typography.label)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DefaultCategoryCatalogGrid(selection: $selection)
                }
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.bottom, AppTheme.Spacing.xl)
            }
            .background(AppTheme.Palette.bgCanvas)
            .navigationTitle("Suggested Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await add() }
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Add")
                    .disabled(selection.isEmpty || isSaving)
                }
            }
        }
    }

    /// Through the outbox, exactly as onboarding's commit writes the same
    /// rows: durable on this device the moment they are submitted, drained
    /// to the server on their own.
    private func add() async {
        guard let ownerId = session.profile?.id else { return }
        isSaving = true
        for payload in CreateCategoryPayload.catalog(selection, ownerId: ownerId) {
            await session.outbox.submitCreateCategory(payload)
        }
        onAdded()
        dismiss()
    }
}
