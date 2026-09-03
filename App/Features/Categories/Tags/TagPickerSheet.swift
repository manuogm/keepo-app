import KeepoCore
import SwiftUI

/// Choosing which tags are on one transaction.
///
/// Every tag is offered, for every kind of transaction including a transfer:
/// a tag carries no category, so there is nothing that could make one
/// inapplicable here. That is the point of tags rather than a second layer
/// of categories.
///
/// Selection is applied to the binding as the user taps, which is why the
/// sheet closes on an "✕" rather than a "Done": there is nothing to confirm
/// here. It is a multi-select over a set the caller already owns, and the
/// caller's own Save is still what writes anything — so a Cancel that had to
/// un-apply several taps would need a snapshot for no benefit.
struct TagPickerSheet: View {
    let session: SessionStore
    @Binding var selectedTagIds: Set<UUID>

    @Environment(\.dismiss) private var dismiss

    @State private var tags: [PublicSchema.TagsSelect] = []
    @State private var isLoading = true
    @State private var newTagName = ""
    @FocusState private var isNamingNewTag: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                if isLoading {
                    ProgressView()
                } else {
                    list
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .task(id: session.refresh.token) { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private var list: some View {
        List {
            Section {
                ForEach(tags, id: \.id) { tag in
                    row(tag)
                }
                // Creating from here rather than sending the user to the Tags
                // screen and back: the moment you discover you need a tag is
                // the moment you are tagging something.
                newTagRow
            } footer: {
                if tags.isEmpty {
                    Text("Type a name to make your first tag. A tag can go on any transaction.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: selectedTagIds)
    }

    private func row(_ tag: PublicSchema.TagsSelect) -> some View {
        Button {
            if selectedTagIds.contains(tag.id) {
                selectedTagIds.remove(tag.id)
            } else {
                selectedTagIds.insert(tag.id)
            }
        } label: {
            HStack {
                TagChip(name: tag.name, isFilled: selectedTagIds.contains(tag.id))
                Spacer()
                if selectedTagIds.contains(tag.id) {
                    Image(systemName: "checkmark")
                        .font(AppTheme.Typography.microEmphasis)
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
        .listRowBackground(AppTheme.Palette.bgSurface)
    }

    private var newTagRow: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: "plus")
                .font(AppTheme.Typography.microEmphasis)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            TextField("New tag", text: $newTagName)
                .font(AppTheme.Typography.label)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isNamingNewTag)
                .onSubmit { Task { await createAndSelect() } }
        }
        .listRowBackground(AppTheme.Palette.bgSurface)
    }

    /// A tag created here is **selected immediately** — the user typed it
    /// while tagging this transaction, so making them then tap it would be
    /// asking twice for one intent.
    private func createAndSelect() async {
        let trimmed = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let ownerId = session.profile?.id else { return }

        // A name they already have selects that tag instead of creating a
        // second one the unique index would refuse anyway.
        if let existing = tags.first(where: {
            $0.ownerId == ownerId
                && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == trimmed.lowercased()
        }) {
            selectedTagIds.insert(existing.id)
            newTagName = ""
            return
        }

        let id = UUID()
        newTagName = ""
        await session.outbox.submitCreateTag(CreateTagPayload(id: id, ownerId: ownerId, name: trimmed))
        selectedTagIds.insert(id)
        session.refresh.bump()
        await load()
    }

    private func load() async {
        let dbQueue = session.dbQueue
        tags = (try? await dbQueue.read { database in try LocalTableQueries.tags(database) }) ?? []
        isLoading = false
    }
}
