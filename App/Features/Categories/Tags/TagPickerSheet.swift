import KeepoCore
import SwiftUI

/// Choosing which tags are on one transaction.
///
/// Every tag is offered, for every kind of transaction including a transfer:
/// a tag carries no category, so there is nothing that could make one
/// inapplicable here. That is the point of tags rather than a second layer
/// of categories.
///
/// The same wrapping field of pills as the All Tags list — a tap selects,
/// another deselects — so a tag looks like the same object on every screen.
///
/// **A draft, closed by ✕ or ✓.** Taps change only this sheet's copy of the
/// selection; ✓ hands it to the form and ✕ throws it away, the same pair
/// the form itself closes with. A tag *created* here is not part of the
/// draft: it is written to the user's tags the moment it is named, and stays
/// whichever way the sheet closes — naming a tag is its own decision, and
/// losing one typed a moment ago to a ✕ meant for the selection would be the
/// surprise.
struct TagPickerSheet: View {
    let session: SessionStore
    @Binding var selectedTagIds: Set<UUID>

    @Environment(\.dismiss) private var dismiss

    @State private var tags: [PublicSchema.TagsSelect] = []
    @State private var draft: Set<UUID> = []
    @State private var isLoading = true
    @State private var newTagName = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case newTag
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                if isLoading {
                    ProgressView()
                } else {
                    pills
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Discard changes")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        selectedTagIds = draft
                        dismiss()
                    } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("Use these tags")
                }
            }
            .task(id: session.refresh.token) { await load() }
        }
        .presentationDetents([.medium, .large])
        .onAppear { draft = selectedTagIds }
    }

    /// With no tags at all, the new-tag pill is the whole sheet — it is the
    /// one thing there is to do, and it says so by itself.
    private var pills: some View {
        ScrollView {
            TagFlowLayout(spacing: AppTheme.Spacing.s) {
                ForEach(tags, id: \.id) { tag in
                    Button { toggle(tag.id) } label: {
                        TagChip(name: tag.name, isSelected: draft.contains(tag.id))
                    }
                    .buttonStyle(.pressableCard)
                    .accessibilityAddTraits(draft.contains(tag.id) ? .isSelected : [])
                }
                // Creating from here rather than sending the user to the
                // Tags screen and back: the moment you discover you need a
                // tag is the moment you are tagging something.
                NewTagField(text: $newTagName, focus: $focusedField, field: .newTag) {
                    Task { await createAndSelect() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sensoryFeedback(AppTheme.Feedback.selection, trigger: draft)
    }

    private func toggle(_ id: UUID) {
        if draft.contains(id) {
            draft.remove(id)
        } else {
            draft.insert(id)
        }
    }

    /// A tag created here is **selected immediately** — the user typed it
    /// while tagging this transaction, so making them then tap it would be
    /// asking twice for one intent.
    private func createAndSelect() async {
        let trimmed = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let ownerId = session.profile?.id else { return }
        newTagName = ""

        // A name they already have selects that tag instead of creating a
        // second one the unique index would refuse anyway.
        if let existing = tags.first(where: {
            $0.ownerId == ownerId
                && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == trimmed.lowercased()
        }) {
            draft.insert(existing.id)
            return
        }

        let id = UUID()
        await session.outbox.submitCreateTag(CreateTagPayload(id: id, ownerId: ownerId, name: trimmed))
        draft.insert(id)
        session.refresh.bump()
        await load()
    }

    private func load() async {
        let dbQueue = session.dbQueue
        tags = (try? await dbQueue.read { database in try LocalTableQueries.tags(database) }) ?? []
        isLoading = false
    }
}
