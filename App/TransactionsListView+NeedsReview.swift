import KeepoCore
import SwiftUI

/// The Needs Review inline section — split out of TransactionsListView.swift
/// purely to keep that file under the project's file-length/type-body-length
/// lint thresholds. Reads/writes the `review*` `@State` declared there.
///
/// The list itself (`reviewItems`) is a local read (Phase L6). The actions
/// below stay network calls — `confirm_capture`/`resolve_sync_conflict`/
/// accept/reject import have real server-side logic (merchant learning,
/// audit rows, CSV-candidate matching) `Outbox`'s write-through never
/// modeled, unlike the plain create/update/delete paths it covers.
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
            } else if item.kind == "sync_conflict" {
                Button {
                    conflictId = item.itemId
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
        guard let id = item.itemId, let ownerId = session.profile?.id,
              let baseCurrency = session.profile?.baseCurrency else { return }
        reviewActionError = nil
        do {
            guard let transaction = try await session.dbQueue.read({ database in
                try LocalTransactionRow.fetchOne(
                    database, id: id.uuidString, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
                )
            }) else { return }
            reviewEditingTransaction = transaction
            showReviewEditing = true
        } catch {
            reviewActionError = UserFacingError.describe(error)
        }
    }

    func confirmCapture(_ item: PublicSchema.NeedsReviewSelect) async {
        guard let id = item.itemId, let ownerId = session.profile?.id,
              let baseCurrency = session.profile?.baseCurrency else { return }
        reviewActionError = nil
        do {
            guard let transaction = try await session.dbQueue.read({ database in
                try LocalTransactionRow.fetchOne(
                    database, id: id.uuidString, baseCurrency: baseCurrency, ownerId: ownerId.uuidString
                )
            }), let version = transaction.version else { return }
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
            try? await session.dbQueue.write { database in
                try ConflictLocalQueries.markResolved(id: id.uuidString, in: database)
            }
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
