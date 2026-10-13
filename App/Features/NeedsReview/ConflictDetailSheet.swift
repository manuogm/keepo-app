import KeepoCore
import SwiftUI

/// What opens from a "Sync Conflict" row in Needs Review: the change this
/// iPhone tried to save, the version that is saved, and a choice between them.
///
/// Each version is its own card, and each card draws the thing the way the
/// rest of the app does — `TransactionRow` for a transaction or a transfer,
/// `AccountRowView` for an account. "Your change" is the saved tile with the
/// change drawn over it (see `VersionCard`). Raw `client_version`/
/// `server_version` integers are never shown: "3 vs 4" answers no question a
/// person actually has.
///
/// The comparison is built in `ConflictComparison`, from the write the server
/// kept on the conflict — see its header for why that, and not this device's
/// copy of the row, is "your change". Loading and the two actions live in
/// `ConflictDetailSheet+Loading.swift`.
///
/// When there is nothing to choose — the versions agree, or the conflict kept
/// no record of the change — the sheet says so and offers one button. That
/// should now be rare: the server no longer records a conflict for a write
/// that asks for what is already saved, and closes one when its row is
/// deleted (migration 20261018100000).
struct ConflictDetailSheet: View {
    let session: SessionStore
    let conflictId: UUID
    var onResolved: () -> Void

    @Environment(\.dismiss) var dismiss

    // Not `private` — read/written from ConflictDetailSheet+Loading.swift,
    // an extension in a different file (kept there purely for file-length).
    @State var comparison: ConflictComparison?
    @State var isLoading = true
    @State var isWorking = false
    @State var actionError: ActionError?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let comparison {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                            explanation(comparison)
                            VersionCard(
                                title: "Your change", place: "On this iPhone", symbol: "iphone",
                                tile: comparison.mine == nil ? nil : comparison.saved?.tile,
                                change: comparison.mine.map { mine in
                                    VersionCard.Change(fields: comparison.fields, deletes: mine.isDeleted)
                                },
                                date: comparison.requestedDate,
                                isDateChanged: comparison.requestedDate != comparison.savedDate,
                                missing: "Keepo didn't keep a copy of the change made on this iPhone, "
                                    + "so only the saved version can be kept."
                            )
                            VersionCard(
                                title: "Saved version", place: "In Keepo now", symbol: "icloud",
                                tile: comparison.saved?.tile, change: nil, date: comparison.savedDate,
                                missing: "This \(comparison.noun) is no longer in Keepo.", isAuthoritative: true
                            )
                        }
                        .padding()
                    }
                } else {
                    settled
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The canvas, so each version's card reads as its own surface.
            .background(AppTheme.Palette.bgCanvas)
            .navigationTitle("Sync Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let comparison { actionButtons(comparison) }
            }
        }
        .errorAlert($actionError)
        .task { await load() }
    }

    private func explanation(_ comparison: ConflictComparison) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Label("\(comparison.noun.capitalized) was changed in two places", systemImage: "arrow.triangle.branch")
                .font(AppTheme.Typography.rowTitle)
            Text(comparison.hasChoice
                ? "Choose which version you want to keep. The other one will be discarded."
                : "There is nothing left to choose, so the saved version will be kept.")
                .font(AppTheme.Typography.label)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Opened from a row a pull has since settled — deleted, or resolved on
    /// another device.
    private var settled: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: "checkmark.circle")
                .font(AppTheme.Typography.screenTitle)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Text("This has already been sorted out.")
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
    }

    /// The same pair for every kind of conflict — a delete, a confirm, an
    /// edit, an account — so the choice always reads the same way. Only the
    /// second is dropped, when there is nothing to choose.
    private func actionButtons(_ comparison: ConflictComparison) -> some View {
        VStack(spacing: AppTheme.Spacing.m) {
            PrimaryActionButton(title: "Keep Saved Version", isLoading: isWorking, fillsWidth: true) {
                Task { await keepSaved() }
            }
            if comparison.hasChoice {
                SecondaryActionButton(title: "Use My Change", fillsWidth: true, isEnabled: !isWorking) {
                    Task { await keepMine() }
                }
            }
        }
        .padding()
        .background(AppTheme.Palette.bgCanvas)
    }
}

/// One version of the thing in conflict, on its own card: where it lives and
/// the tile the rest of the app draws for it.
///
/// "Your change" is the saved tile with the change drawn over it — each value
/// the change touches struck through in red, the requested value after it —
/// so the two cards read as the same thing, and the difference is the only
/// thing that stands out. A value the tile has nowhere to show (a note, the
/// amount paid) gets a line of its own, drawn the same way; the date is each
/// card's own. A delete fades the saved tile and says so in red.
private struct VersionCard: View {
    /// What a change does to the saved version.
    struct Change {
        let fields: [ConflictField]
        /// The change was a delete: the tile is drawn as saved but faded, with
        /// nothing struck — there is no requested value to set against it.
        let deletes: Bool
    }

    let title: String
    let place: String
    let symbol: String
    let tile: ConflictComparison.Tile?
    let change: Change?
    /// A transaction's date, under its tile — each card its own, never struck.
    let date: String?
    /// "Your change" moved the date: drawn in the brand colour.
    var isDateChanged = false
    /// What the card says when there is nothing to draw.
    let missing: String
    /// The saved version: outlined in the brand colour, as what stands
    /// unless the user chooses otherwise.
    var isAuthoritative = false

    private var lines: [ConflictField] {
        change?.fields.filter { $0.placement == .line } ?? []
    }

    var body: some View {
        FormCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                HStack {
                    Label(title, systemImage: symbol)
                        .font(AppTheme.Typography.labelEmphasis)
                    Spacer()
                    Text(place)
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }

                if let tile {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                        row(tile)
                        if let date {
                            Label(date, systemImage: "calendar")
                                .font(AppTheme.Typography.caption)
                                .fontWeight(isDateChanged ? .semibold : nil)
                                .foregroundStyle(
                                    isDateChanged ? AppTheme.Palette.brandPrimary : AppTheme.Palette.textSecondary
                                )
                        }
                    }
                    .opacity(change?.deletes == true ? AppTheme.Opacity.muted : 1)
                    if change?.deletes == true {
                        Label("Deleted on this iPhone", systemImage: "trash")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Palette.statusNegative)
                    } else if !lines.isEmpty {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                            ForEach(lines) { field in
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                    Text(field.label)
                                        .font(AppTheme.Typography.micro)
                                        .foregroundStyle(AppTheme.Palette.textSecondary)
                                    edit(field)
                                        .font(AppTheme.Typography.caption)
                                }
                            }
                        }
                    }
                } else {
                    Text(missing)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .overlay {
            if isAuthoritative {
                RoundedRectangle(cornerRadius: AppTheme.Radius.surface)
                    .strokeBorder(AppTheme.Palette.brandPrimary, lineWidth: AppTheme.Stroke.emphasis)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The saved value struck through in red, then the requested one — the
    /// same treatment the tile gives its own parts.
    private func edit(_ field: ConflictField) -> Text {
        let negative = AppTheme.Palette.statusNegative
        let struck = Text(field.saved).strikethrough(color: negative).foregroundStyle(negative)
        let requested = Text(field.mine).foregroundStyle(AppTheme.Palette.brandPrimary).fontWeight(.semibold)
        if field.saved.isEmpty { return requested }
        if field.mine.isEmpty { return struck }
        return struck + Text(" ") + requested
    }

    @ViewBuilder
    private func row(_ tile: ConflictComparison.Tile) -> some View {
        switch tile {
        case .transaction(let transaction):
            TransactionRow(
                transaction: transaction.row, category: transaction.category, counterpart: transaction.counterpart,
                merchant: transaction.row.merchantRaw, edits: transactionEdits, showsExactAmount: true
            )
        case .account(let account):
            AccountRowView(row: account.row, edits: accountEdits, showsExactBalance: true)
        }
    }

    private var transactionEdits: [TransactionRow.Part: String?] {
        guard let change, !change.deletes else { return [:] }
        return Dictionary(uniqueKeysWithValues: change.fields.compactMap { field -> (TransactionRow.Part, String?)? in
            guard case .transaction(let part) = field.placement else { return nil }
            return (part, field.mine.isEmpty ? nil : field.mine)
        })
    }

    private var accountEdits: [AccountRowView.Part: String?] {
        guard let change, !change.deletes else { return [:] }
        return Dictionary(uniqueKeysWithValues: change.fields.compactMap { field -> (AccountRowView.Part, String?)? in
            guard case .account(let part) = field.placement else { return nil }
            return (part, field.mine.isEmpty ? nil : field.mine)
        })
    }
}
