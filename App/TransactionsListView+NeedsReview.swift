import KeepoCore
import SwiftUI

/// The Needs Review inline section — split out of TransactionsListView.swift
/// purely to keep that file under the project's file-length/type-body-length
/// lint thresholds. Reads/writes the `review*` `@State` declared there.
extension TransactionsListView {
    @ViewBuilder
    func reviewRow(_ item: PublicSchema.NeedsReviewSelect) -> some View {
        Group {
            if item.kind == "pending_capture" {
                Button {
                    Task { await openForReview(item) }
                } label: {
                    NeedsReviewRow(item: item, minorUnit: reviewMinorUnit(for: item.currency))
                }
                .buttonStyle(.plain)
            } else if item.kind == "ambiguous_card" {
                Button {
                    reviewMappingCard = item
                    showReviewCardMapping = true
                } label: {
                    NeedsReviewRow(item: item, minorUnit: reviewMinorUnit(for: item.currency))
                }
                .buttonStyle(.plain)
            } else {
                NeedsReviewRow(item: item, minorUnit: reviewMinorUnit(for: item.currency))
            }
        }
        .swipeActions(edge: .trailing) { reviewTrailingActions(item) }
        .swipeActions(edge: .leading) { reviewLeadingActions(item) }
    }

    @ViewBuilder
    func reviewTrailingActions(_ item: PublicSchema.NeedsReviewSelect) -> some View {
        if item.kind == "sync_conflict" {
            Button("Resolve") {
                Task { await resolveConflict(item) }
            }
            .tint(Color.primary)
        } else if item.kind == "pending_capture" {
            Button("Confirm") {
                Task { await confirmCapture(item) }
            }
            .tint(Color.primary)
        } else if item.kind == "csv_import_candidate" {
            Button("Accept") {
                Task { await acceptImportCandidate(item) }
            }
            .tint(Color.primary)
        }
    }

    @ViewBuilder
    func reviewLeadingActions(_ item: PublicSchema.NeedsReviewSelect) -> some View {
        if item.kind == "csv_import_candidate" {
            Button("Reject", role: .destructive) {
                Task { await rejectImportCandidate(item) }
            }
        }
    }

    func reviewMinorUnit(for currencyCode: String?) -> Int {
        guard let currencyCode else { return 2 }
        return reviewCurrencies[currencyCode] ?? 2
    }

    func openForReview(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        reviewActionError = nil
        do {
            guard let transaction = try await TransactionRepository.fetchOne(client: session.client, id: id) else {
                return
            }
            reviewEditingTransaction = transaction
            showReviewEditing = true
        } catch {
            reviewActionError = UserFacingError.describe(error)
        }
    }

    func confirmCapture(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        reviewActionError = nil
        do {
            guard let transaction = try await TransactionRepository.fetchOne(client: session.client, id: id),
                  let version = transaction.version else { return }
            _ = try await CaptureRepository.confirmCapture(
                client: session.client, id: id, expectedVersion: Int(version)
            )
            session.refresh.bump()
        } catch {
            reviewActionError = UserFacingError.describe(error)
        }
    }

    func resolveConflict(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        reviewActionError = nil
        do {
            try await NeedsReviewRepository.resolveSyncConflict(client: session.client, id: id)
            session.refresh.bump()
        } catch {
            reviewActionError = UserFacingError.describe(error)
        }
    }

    func acceptImportCandidate(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        reviewActionError = nil
        do {
            try await ImportRepository.accept(client: session.client, id: id)
            session.refresh.bump()
        } catch {
            reviewActionError = UserFacingError.describe(error)
        }
    }

    func rejectImportCandidate(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId else { return }
        reviewActionError = nil
        do {
            try await ImportRepository.reject(client: session.client, id: id)
            session.refresh.bump()
        } catch {
            reviewActionError = UserFacingError.describe(error)
        }
    }
}
