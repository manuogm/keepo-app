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
                        VStack(alignment: .leading, spacing: 20) {
                            explanation
                            if !fields.isEmpty {
                                comparisonCard
                            } else if couldNotReachServer {
                                Label(
                                    "Couldn't reach the server to show what changed. "
                                        + "Check your connection and reopen this.",
                                    systemImage: "wifi.slash"
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            } else {
                                Text(
                                    "Nothing about this \(subjectName) looks different anymore "
                                        + "— it may be safe to keep either version."
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                            if let errorMessage {
                                Text(errorMessage).font(.footnote).foregroundStyle(.red)
                            }
                        }
                        .padding()
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.largeTitle)
                            .foregroundStyle(Color.secondary)
                        Text("This conflict no longer applies.").foregroundStyle(Color.secondary)
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

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Changed in two places", systemImage: "arrow.triangle.branch")
                .font(.headline)
            Text(
                "You changed this \(subjectName) on this device, but it was also changed elsewhere "
                    + "(another device, or directly on the server) before the two could sync up. "
                    + "Pick which version should win — the other will be discarded."
            )
            .font(.subheadline)
            .foregroundStyle(Color.secondary)
        }
    }

    private var comparisonCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.label)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    HStack(spacing: 8) {
                        fieldValue(icon: "iphone", caption: "This device", value: field.mine)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                        fieldValue(icon: "icloud", caption: "Currently saved", value: field.server)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func fieldValue(icon: String, caption: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(caption, systemImage: icon)
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
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
