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
/// That same tap fills the pill and puts a red cross beside it that deletes
/// it. A tag has exactly two things you can do to it and both belong to one
/// "working on this one" state, so one tap opens both rather than making
/// delete a separate long-press nobody can see is there.
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
    /// Every pill's height — what the delete circle beside one matches.
    @State private var pillHeight: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    private enum Field: Hashable {
        case existing(UUID)
        case new
    }

    /// A delete waiting on the user, for a tag that is on transactions.
    private struct PendingDelete {
        let tag: PublicSchema.TagsSelect
        let transactionCount: Int
    }

    @State private var pendingDelete: PendingDelete?

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
                ToolbarItem(placement: .principal) { titleWithInfo }
            }
            .task(id: session.refresh.token) { await load() }
            // An alert, centred, not a confirmation dialog: on iOS 26 that
            // draws as a popover pointing at the cross, which reads as a menu
            // of options rather than a question to answer.
            .alert(
                "Delete \"\(pendingDelete?.tag.name ?? "")\"?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { pending in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { Task { await delete(pending.tag) } }
            } message: { pending in
                Text(deleteWarning(pending))
            }
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

    /// The title and its ⓘ as one object, which is why this is a `principal`
    /// item and not a trailing button: the question it answers is "what is
    /// this screen", so it belongs against the screen's name. In the
    /// trailing corner it sat where every other screen puts an *action* on
    /// the content, and read as one.
    ///
    /// `navigationTitle` stays for VoiceOver and for anything that pushes
    /// this — a principal item replaces the title's view, not its name.
    private var titleWithInfo: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text("All Tags")
                .font(AppTheme.Typography.rowTitle)
                .foregroundStyle(AppTheme.Palette.textPrimary)
            infoButton
        }
    }

    /// The screen's instructions, behind an ⓘ rather than printed under the
    /// pills. They are read once and in the way from then on — and the pills
    /// are the content, so a paragraph sitting under two of them made the
    /// screen look like a page about tags instead of the tags themselves.
    private var infoButton: some View {
        Button {
            isShowingGuide = true
        } label: {
            Image(systemName: "info.circle")
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .hitTarget()
        }
        .buttonStyle(.plain)
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
            Text("Tap a tag to rename it. The red cross beside it deletes it.")
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
            // owner-only — a caret and a delete would be offering two writes
            // the server refuses.
            TagChip(name: tag.name, isSelected: false)
        }
    }

    /// The pill *is* the text field. `fixedSize` makes it hug its own
    /// content so the capsule grows with the name as it is typed, which is
    /// what keeps it reading as the same object it was before the tap rather
    /// than an input that replaced it.
    ///
    /// Hollow at rest and filled while it is being edited — the one tag
    /// being worked on is the selected one. Its delete sits **beside** it,
    /// a red circle the pill's own height, and pushes the next pills along:
    /// a badge on the corner covered the neighbour's edge and was a target
    /// smaller than a fingertip.
    private func editablePill(_ tag: PublicSchema.TagsSelect) -> some View {
        let isEditing = focusedField == .existing(tag.id)
        return HStack(spacing: AppTheme.Spacing.xs) {
            TextField(
                "Tag",
                text: Binding(
                    get: { drafts[tag.id] ?? tag.name },
                    set: { drafts[tag.id] = $0 }
                )
            )
            .font(AppTheme.Typography.label)
            .tint(AppTheme.Palette.inkOnPrimaryFill(colorScheme))
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .focused($focusedField, equals: .existing(tag.id))
            .fixedSize()
            .tagPill(isSelected: isEditing)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pillHeight = $0 }
            .onSubmit { Task { await commitRename(tag) } }
            // Blur commits too — tapping away from a pill just edited means
            // the edit is finished, and losing it there would be the surprise.
            .onChange(of: focusedField) { previous, _ in
                if previous == .existing(tag.id) { Task { await commitRename(tag) } }
            }

            if isEditing {
                deleteButton(tag)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(AppTheme.Motion.standard, value: isEditing)
    }

    private func deleteButton(_ tag: PublicSchema.TagsSelect) -> some View {
        Button {
            Task { await requestDelete(tag) }
        } label: {
            Image(systemName: "xmark")
                .font(AppTheme.Typography.microEmphasis)
                .foregroundStyle(AppTheme.Palette.textOnAccent)
                .frame(width: pillHeight, height: pillHeight)
                .background(Circle().fill(AppTheme.Palette.statusNegative))
                .contentShape(Circle())
        }
        .buttonStyle(.pressableCard)
        .accessibilityLabel("Delete tag \(tag.name)")
    }

    /// See `NewTagField`.
    private var newTagPill: some View {
        NewTagField(text: $newTagName, focus: $focusedField, field: .new) {
            Task { await commitCreate() }
        }
    }

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

    /// A tag on no transaction goes at once — there is nothing to lose. One
    /// that is on some asks first, the way deleting an account does: the
    /// delete takes it off every one of them (the server's
    /// `tags_cascade_soft_delete`), which the red cross alone does not say.
    private func requestDelete(_ tag: PublicSchema.TagsSelect) async {
        let count = (try? await session.dbQueue.read { database in
            try LocalTableQueries.transactionCount(database, tagId: tag.id.uuidString)
        }) ?? 0
        if count == 0 {
            await delete(tag)
        } else {
            pendingDelete = PendingDelete(tag: tag, transactionCount: count)
        }
    }

    private func deleteWarning(_ pending: PendingDelete) -> String {
        let count = pending.transactionCount
        let transactions = count == 1 ? "1 transaction" : "\(count) transactions"
        return "This tag is currently being used in \(transactions). Deleting it will permanently remove it "
            + "from all of them. This action can't be undone."
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
