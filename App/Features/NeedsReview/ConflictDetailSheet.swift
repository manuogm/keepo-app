import KeepoCore
import SwiftUI

/// E: tapping a `sync_conflict` Needs Review row used to offer nothing but
/// a swipe-to-dismiss ("Resolve", which only marks the audit row resolved
/// without telling the user what happened or letting them choose which
/// side wins). This is the modal that replaces it.
///
/// Showing raw `client_version`/`server_version` integers told the user
/// nothing actionable — "3 vs 4" answers no question a person actually
/// has. What they need is what changed, in their own words: fetches the
/// server's current row (a network call, since that's the only place the
/// authoritative "what's saved right now" answer lives before a pull
/// overwrites the local copy) and diffs it field-by-field against what
/// this device still has queued, showing only the fields that disagree.
/// The loading/diffing logic lives in `ConflictDetailSheet+Loading.swift`
/// purely to keep this file under the project's type-body-length lint
/// threshold — same reasoning as `TransactionsListView`'s own split.
///
/// "Keep Mine" is intentionally scoped to what this app's conflicts
/// actually are: a transaction re-submits its current local edit; an
/// account re-submits its archived flag, the one account field a version
/// conflict has actually been observed to come from (a local delete/
/// unavailable row disables the option rather than guessing).
struct ConflictDetailSheet: View {
    let session: SessionStore
    let conflictId: UUID
    var onResolved: () -> Void

    @Environment(\.dismiss) var dismiss

    // Not `private` — read/written from ConflictDetailSheet+Loading.swift,
    // an extension in a different file (kept there purely for file-length).
    @State var detail: SyncConflictDetail?
    @State var fields: [ConflictField] = []
    @State var myAccount: PublicSchema.AccountsSelect?
    @State var myTransaction: PublicSchema.TransactionsWithDetailsSelect?
    @State var couldNotReachServer = false
    @State var isLoading = true
    @State var isWorking = false
    @State var errorMessage: String?

    private var canKeepMine: Bool {
        guard let detail else { return false }
        return detail.tableName == "accounts" ? myAccount != nil : myTransaction != nil
    }

    private var subjectName: String {
        detail?.tableName == "accounts" ? "account" : "transaction"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let detail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                            subjectHeader
                            explanation
                            if !fields.isEmpty {
                                comparisonCard
                            } else if couldNotReachServer {
                                Label(
                                    "Couldn't reach the server to show what changed. "
                                        + "Check your connection and reopen this.",
                                    systemImage: "wifi.slash"
                                )
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                            } else {
                                Text(
                                    "Nothing about this \(subjectName) looks different anymore "
                                        + "— it may be safe to keep either version."
                                )
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                            }
                            if let errorMessage {
                                FormErrorText(message: errorMessage)
                            }
                        }
                        .padding()
                    }
                } else {
                    VStack(spacing: AppTheme.Spacing.s) {
                        Image(systemName: "checkmark.circle")
                            .font(AppTheme.Typography.screenTitle)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                        Text("This conflict no longer applies.").foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                }
            }
            .navigationTitle("Sync Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if detail != nil { actionButtons }
            }
        }
        .task { await load() }
    }

    /// Which transaction or account this conflict is actually about — the
    /// one thing the sheet never showed before. `myTransaction`/`myAccount`
    /// are already loaded in full for the diff below; this just renders
    /// their identity instead of only their changed fields, so it appears
    /// whether or not `fields` ends up empty.
    @ViewBuilder
    private var subjectHeader: some View {
        if let myTransaction {
            HStack(spacing: AppTheme.Spacing.m) {
                // `TransactionsWithDetailsSelect` carries `categoryName`
                // but not the category's own icon/color — a neutral badge,
                // same fallback `CategoryIconView` already uses for a
                // transfer or an uncached category.
                CategoryIconView(category: nil)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(myTransaction.merchantRaw ?? myTransaction.categoryName ?? "—")
                        .font(AppTheme.Typography.rowTitle)
                    Text("\(formattedDate(myTransaction.occurredAt)) · \(myTransaction.accountName ?? "—")")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                Spacer()
                Text(formattedAmount(myTransaction))
                    .font(AppTheme.Typography.label)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .padding()
            .background(AppTheme.Palette.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control))
        } else if let myAccount {
            HStack(spacing: AppTheme.Spacing.m) {
                CategoryIconView(icon: myAccount.icon, color: Color(hex: myAccount.color))
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(myAccount.name).font(AppTheme.Typography.rowTitle)
                    Text("Account").font(AppTheme.Typography.micro).foregroundStyle(AppTheme.Palette.textSecondary)
                }
                Spacer()
            }
            .padding()
            .background(AppTheme.Palette.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control))
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Label("Changed in two places", systemImage: "arrow.triangle.branch")
                .font(AppTheme.Typography.rowTitle)
            Text(
                "You changed this \(subjectName) on this device, but it was also changed elsewhere "
                    + "(another device, or directly on the server) before the two could sync up. "
                    + "Pick which version should win — the other will be discarded."
            )
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.Palette.textSecondary)
        }
    }

    private var comparisonCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(field.label)
                        .font(AppTheme.Typography.label)
                        .fontWeight(.semibold)
                    HStack(spacing: AppTheme.Spacing.s) {
                        fieldValue(icon: "iphone", caption: "This device", value: field.mine)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(AppTheme.Typography.micro)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                        fieldValue(icon: "icloud", caption: "Currently saved", value: field.server)
                    }
                }
            }
        }
        .padding()
        .background(AppTheme.Palette.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control))
    }

    private func fieldValue(icon: String, caption: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Label(caption, systemImage: icon)
                .font(AppTheme.Typography.micro)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Text(value)
                .font(AppTheme.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(AppTheme.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionButtons: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            Button {
                Task { await keepServer() }
            } label: {
                Text("Keep What's Saved").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            if canKeepMine {
                Button {
                    Task { await keepMine() }
                } label: {
                    Text("Keep My Change").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
        .padding()
    }
}

/// One field the local and server rows disagree on, in plain-English form
/// — only fields that actually differ are shown, per `load()`'s field
/// builders, so this never carries noise like unchanged timestamps.
struct ConflictField: Identifiable {
    let label: String
    let mine: String
    let server: String
    var id: String { label }
}
