import KeepoCore
import SwiftUI

/// Every tag the user can see — the "All Tags" destination reached from the
/// bottom of the Categories screen.
///
/// Drawn as a wrapping field of **pills**, the same `TagChip` the transaction
/// form shows: a tag is a name and nothing else, so the thing the user
/// recognises is the pill itself, and a list of plain text rows would make
/// the same objects look like two different kinds of thing depending on
/// which screen you were on.
///
/// Everything is edited **in place**. Tapping a pill puts the caret in it —
/// there is nothing else a tag has, so a form containing one text field
/// would be a sheet over a screen already showing that field.
///
/// That same tap reveals the `RemoveBadge` that deletes it, the way a
/// dashboard tile wears one in edit mode. A tag has exactly two things you
/// can do to it and both belong to one "working on this one" state, so one
/// tap opens both rather than making delete a separate long-press nobody can
/// see is there.
struct TagsListView: View {
    let session: SessionStore

    @Environment(\.dismiss) private var dismiss

    @State private var tags: [PublicSchema.TagsSelect] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Drafts keyed by tag id, so a half-typed rename survives the list
    /// reloading underneath it (a sync pull landing while the caret is in a
    /// pill). Committed on return or blur; discarded if it would collide.
    @State private var drafts: [UUID: String] = [:]
    @State private var newTagName = ""
    @State private var isShowingGuide = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case existing(UUID)
        case new
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Palette.bgCanvas.ignoresSafeArea()
                if isLoading {
                    ProgressView()
                } else {
                    content
                }
            }
            .navigationTitle("All Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .primaryAction) { infoButton }
            }
            .task(id: session.refresh.token) { await load() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                TagFlowLayout(spacing: AppTheme.Spacing.s) {
                    ForEach(tags, id: \.id) { tag in
                        pill(tag)
                    }
                    newTagPill
                }

                if let errorMessage {
                    FormErrorText(message: errorMessage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The screen's instructions, behind an ⓘ beside the title rather than
    /// printed under the pills. They are read once and in the way from then
    /// on — and the pills are the content, so a paragraph sitting under two
    /// of them made the screen look like a page about tags instead of the
    /// tags themselves.
    private var infoButton: some View {
        Button {
            isShowingGuide = true
        } label: {
            Image(systemName: "info.circle")
        }
        .accessibilityLabel("About tags")
        .popover(isPresented: $isShowingGuide) { guide }
    }

    /// A popover rather than a sheet: it answers a question about the screen
    /// underneath, so covering that screen would be the wrong move — and
    /// this one is already a sheet, which a second sheet would stack on.
    ///
    /// A fixed width with `fixedSize` vertical, not `fixedSize` in both
    /// directions the way `FxRateWidget`'s note does it: that one is two
    /// short lines that never wrap, and this is prose, which without a width
    /// would lay itself out in a single line wider than the phone — and
    /// wider still at accessibility text sizes.
    private var guide: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text(
                "A tag is a name that cuts across categories — a coffee habit, a trip, "
                    + "a side income. It can go on any transaction, whatever its category."
            )
            Text("Tap a tag to rename it. The red minus deletes it.")
        }
        .font(AppTheme.Typography.caption)
        .foregroundStyle(AppTheme.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(AppTheme.Spacing.l)
        .frame(width: AppTheme.Size.proseWidth)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private func pill(_ tag: PublicSchema.TagsSelect) -> some View {
        if isOwn(tag) {
            editablePill(tag)
        } else {
            // A household member's shared tag. It is visible here because it
            // is on a transaction in a shared account, but `tags_update` is
            // owner-only — a caret and a minus would be offering two writes
            // the server refuses.
            TagChip(name: tag.name)
        }
    }

    /// The pill *is* the text field. `fixedSize` makes it hug its own
    /// content so the capsule grows with the name as it is typed, which is
    /// what keeps it reading as the same object it was before the tap rather
    /// than an input that replaced it.
    private func editablePill(_ tag: PublicSchema.TagsSelect) -> some View {
        TextField(
            "Tag",
            text: Binding(
                get: { drafts[tag.id] ?? tag.name },
                set: { drafts[tag.id] = $0 }
            )
        )
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.Palette.textOnAccent)
        // The caret would otherwise be the system accent on a dark fill.
        .tint(AppTheme.Palette.textOnAccent)
        .textInputAutocapitalization(.words)
        .submitLabel(.done)
        .focused($focusedField, equals: .existing(tag.id))
        .fixedSize()
        .padding(.horizontal, AppTheme.Spacing.m)
        .padding(.vertical, AppTheme.Spacing.s)
        .background(Capsule().fill(AppTheme.Palette.tagTint))
        .onSubmit { Task { await commitRename(tag) } }
        // Blur commits too — tapping away from a pill just edited means the
        // edit is finished, and losing it there would be the surprise.
        .onChange(of: focusedField) { previous, _ in
            if previous == .existing(tag.id) { Task { await commitRename(tag) } }
        }
        .overlay(alignment: .topTrailing) {
            if focusedField == .existing(tag.id) {
                RemoveBadge(label: "Delete tag \(tag.name)", diameter: AppTheme.Size.glyphSmall) {
                    Task { await delete(tag) }
                }
                // Straddling the corner, not tucked inside it: a capsule's
                // corner is empty space, so the badge sits over nothing and
                // covers no part of the name it belongs to.
                .offset(x: AppTheme.Spacing.m, y: -AppTheme.Spacing.m)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(AppTheme.Motion.standard, value: focusedField)
    }

    /// Dashed until it is tapped, because a dashed outline reads as "a
    /// slot, not a thing" — it is the one pill here that is not yet a tag.
    /// The moment the caret lands in it, it **fills**: from then on the user
    /// is typing a tag, and a hollow outline that only became a tag on
    /// return made the thing they were naming look like it wasn't there yet.
    ///
    /// The plus and the placeholder go with the outline. Both say "start
    /// something"; the caret already says it, and keeping them would leave a
    /// filled tag with a `+` inside it.
    ///
    /// A minimum width so an empty field is still a target; `fixedSize`
    /// alone would collapse it to the caret.
    private var newTagPill: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if !isNamingNewTag {
                Image(systemName: "plus")
                    .font(AppTheme.Typography.microEmphasis)
            }
            TextField(isNamingNewTag ? "" : "Add Tag", text: $newTagName)
                .font(AppTheme.Typography.label)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($focusedField, equals: .new)
                .tint(AppTheme.Palette.textOnAccent)
                .fixedSize()
                .frame(minWidth: AppTheme.Size.illustration, alignment: .leading)
                .accessibilityLabel("New tag name")
                .onSubmit { Task { await commitCreate() } }
                .onChange(of: focusedField) { previous, _ in
                    if previous == .new { Task { await commitCreate() } }
                }
        }
        .foregroundStyle(isNamingNewTag ? AppTheme.Palette.textOnAccent : AppTheme.Palette.fillStrong)
        .padding(.horizontal, AppTheme.Spacing.m)
        .padding(.vertical, AppTheme.Spacing.s)
        .background {
            if isNamingNewTag {
                Capsule().fill(AppTheme.Palette.tagTint)
            } else {
                Capsule()
                    .strokeBorder(AppTheme.Palette.fillStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .animation(AppTheme.Motion.standard, value: isNamingNewTag)
    }

    private var isNamingNewTag: Bool { focusedField == .new }

    // MARK: - Writes

    /// Silently no-ops on an unchanged or empty name, and refuses a
    /// collision here rather than letting the unique index reject it after
    /// the sheet has closed. `isDuplicate` compares the way that index does
    /// — trimmed and case-insensitive.
    private func commitRename(_ tag: PublicSchema.TagsSelect) async {
        guard let draft = drafts[tag.id] else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        drafts[tag.id] = nil
        guard !trimmed.isEmpty, trimmed != tag.name else { return }
        guard !isDuplicate(trimmed, excluding: tag.id) else {
            errorMessage = "You already have a tag called \"\(trimmed)\"."
            return
        }
        errorMessage = nil
        await session.outbox.submitUpdateTag(UpdateTagPayload(id: tag.id, name: trimmed))
        session.refresh.bump()
    }

    private func commitCreate() async {
        let trimmed = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let ownerId = session.profile?.id else { return }
        guard !isDuplicate(trimmed, excluding: nil) else {
            errorMessage = "You already have a tag called \"\(trimmed)\"."
            return
        }
        errorMessage = nil
        newTagName = ""
        await session.outbox.submitCreateTag(CreateTagPayload(id: UUID(), ownerId: ownerId, name: trimmed))
        session.refresh.bump()
    }

    /// Drops the draft before the focus, so the blur this causes has nothing
    /// left to commit — a rename racing the delete of the same tag would
    /// otherwise queue an update for a row already tombstoned.
    private func delete(_ tag: PublicSchema.TagsSelect) async {
        drafts[tag.id] = nil
        focusedField = nil
        errorMessage = nil
        await session.outbox.submitDeleteTag(DeleteTagPayload(id: tag.id))
        session.refresh.bump()
    }

    private func isOwn(_ tag: PublicSchema.TagsSelect) -> Bool {
        tag.ownerId == session.profile?.id
    }

    /// Only the user's **own** tags can collide: the unique index is
    /// `(owner_id, lower(name))`, and this screen can also hold a household
    /// member's shared tag, which is free to share a name with one of theirs.
    private func isDuplicate(_ name: String, excluding tagId: UUID?) -> Bool {
        tags.contains { tag in
            tag.id != tagId
                && isOwn(tag)
                && tag.name.trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            tags = try await session.dbQueue.read { database in try LocalTableQueries.tags(database) }
        } catch {
            errorMessage = UserFacingError.describe(error)
        }
        isLoading = false
    }
}
