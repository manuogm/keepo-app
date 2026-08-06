import SwiftUI

/// "Verified X ago" — neutral when fresh, muted amber (`BrandSecondary`,
/// the same token the brand doc assigns to budget-limit reminders) when
/// stale. Shared by the Sync Ritual row and Home's banner per
/// app-architecture.md §2's component table — both read the same
/// `accounts_sync_status.is_stale`/`last_verified_at`, never re-deriving
/// the per-subtype threshold client-side.
struct StalenessBadge: View {
    let isStale: Bool
    let lastVerifiedAt: Date?

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isStale ? Color("BrandSecondary") : Color("TextSecondary"))
    }

    private var text: String {
        guard let lastVerifiedAt else { return "never verified" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "verified \(formatter.localizedString(for: lastVerifiedAt, relativeTo: Date()))"
    }
}
