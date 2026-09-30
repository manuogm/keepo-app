import Foundation
import GRDB
import KeepoCore

/// The reads behind the title "memory" — the user's own titled transactions,
/// consulted for which category a title, or a merchant spelled like one,
/// belongs in. Every decision about what counts as a match is
/// `TitleMatching`'s (KeepoCore, where it is tested); this only fetches what
/// that type needs, from the local mirror, so it works offline and costs no
/// round trip.
///
/// **Two callers, deliberately different in how loosely they match.** The
/// transaction form asks with a person watching, who can see the suggestion
/// and decline it, so it also tries the title's leading words. A capture is
/// filed with nobody watching, so it takes the whole key or nothing.
enum LocalTitleMemory {
    /// Every (title, category) pairing the owner has filed, of one category
    /// kind — raw titles, grouped as typed. Grouping by *key* has to happen
    /// in Swift, because SQL cannot run `MerchantNormalizer`.
    ///
    /// `owner_id` rather than `created_by`: a transaction's owner is its
    /// account's owner (the composite FK makes it so), which is also the
    /// only owner its category can belong to — so every id this returns is
    /// one the owner may file under, which the server re-checks anyway.
    private static func uses(
        _ database: Database, ownerId: String, categoryKind: String
    ) throws -> [TitleMatching.Use] {
        try Row.fetchAll(
            database,
            sql: """
            SELECT t.title, t.category_id, COUNT(*) AS uses, MAX(t.occurred_at) AS last_used_at
            FROM transactions t JOIN categories c ON c.id = t.category_id
            WHERE t.owner_id = ? AND t.title IS NOT NULL AND t.deleted_at IS NULL
              AND c.deleted_at IS NULL AND c.kind = ?
            GROUP BY t.title, t.category_id
            """,
            arguments: [ownerId, categoryKind]
        ).map { row in
            TitleMatching.Use(
                title: row["title"], categoryId: row["category_id"], count: row["uses"], lastUsedAt: row["last_used_at"]
            )
        }
    }

    /// For a capture whose merchant taught Keepo nothing: the category the
    /// user files a title **exactly** matching that merchant under, as the
    /// row `CaptureLocalWrite` resolves with (`id`, `name`, `is_default`), or
    /// `nil`.
    static func category(
        forUnlearnedMerchant merchantNormalized: String, ownerId: String, in database: Database
    ) throws -> Row? {
        let uses = try uses(database, ownerId: ownerId, categoryKind: "expense")
        guard let id = TitleMatching.bestCategory(for: merchantNormalized, among: uses) else { return nil }
        return try Row.fetchOne(
            database, sql: "SELECT id, name, is_default FROM categories WHERE id = ?", arguments: [id]
        )
    }

    /// For the transaction form: the category a typed title points at, or
    /// `nil`.
    ///
    /// At each run of the title's leading words, longest first, the user's
    /// own history with that title is asked before the merchant map — a
    /// title is the user's word for the thing, and how they have filed it
    /// themselves is the most direct evidence there is. A learned merchant is
    /// the fallback that makes a first-ever title useful: "Starbucks coffee"
    /// finds `STARBUCKS` even if nobody has typed that title before.
    static func suggestedCategory(
        forTitle title: String, ownerId: String, categoryKind: String, in database: Database
    ) throws -> String? {
        guard let key = TitleMatching.key(for: title) else { return nil }
        let prefixes = TitleMatching.leadingWordPrefixes(of: key)
        let uses = try uses(database, ownerId: ownerId, categoryKind: categoryKind)
        let learned = try learnedMerchants(database, ownerId: ownerId, categoryKind: categoryKind, patterns: prefixes)
        for prefix in prefixes {
            if let id = TitleMatching.bestCategory(for: prefix, among: uses) { return id }
            if let id = learned[prefix] { return id }
        }
        return nil
    }

    /// **What a form does with a title being typed**, in one place: wait for
    /// the typing to settle, ask the memory above, and keep the answer only
    /// if it is a category this form may actually offer.
    ///
    /// The transaction form and the recurring-rule form ask the identical
    /// question of the identical memory — a rule is named the same way a
    /// transaction is, and "Rent" points at the same category whether it is
    /// being entered once or every month. What the two screens genuinely
    /// differ on is what they then *do* with the answer (whether it may
    /// select as well as suggest), which stays with each of them.
    ///
    /// Cancellation is the caller's `.task(id:)`: the sleep and the read both
    /// run in its task, so a title that changes again abandons this lookup
    /// mid-flight and only the settled title is ever answered.
    static func categoryForTypedTitle(
        _ title: String,
        categoryKind: PublicSchema.CategoryKind,
        ownerId: UUID,
        among offered: [PublicSchema.CategoriesSelect],
        in dbQueue: DatabaseQueue
    ) async -> UUID? {
        guard !title.isEmpty else { return nil }
        try? await Task.sleep(for: typingSettles)
        guard !Task.isCancelled else { return nil }
        let match = try? await dbQueue.read { database in
            try suggestedCategory(
                forTitle: title, ownerId: ownerId.uuidString, categoryKind: categoryKind.rawValue, in: database
            )
        }
        guard !Task.isCancelled else { return nil }
        return match
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in offered.contains { $0.id == id } ? id : nil }
    }

    /// Long enough that a word being typed is not looked up letter by letter,
    /// short enough that the category has moved by the time the eye comes
    /// back down to it.
    static let typingSettles: Duration = .milliseconds(350)

    /// `merchant_category_map` rows for exactly these patterns — already
    /// normalized on both sides, so plain equality is the right comparison.
    private static func learnedMerchants(
        _ database: Database, ownerId: String, categoryKind: String, patterns: [String]
    ) throws -> [String: String] {
        guard !patterns.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT m.merchant_pattern, m.category_id FROM merchant_category_map m
            JOIN categories c ON c.id = m.category_id
            WHERE m.owner_id = ? AND m.deleted_at IS NULL AND c.kind = ? AND c.deleted_at IS NULL
              AND m.merchant_pattern IN (\(databaseQuestionMarks(count: patterns.count)))
            """,
            arguments: StatementArguments([ownerId, categoryKind] + patterns)
        )
        return Dictionary(
            rows.map { (row: Row) -> (String, String) in (row["merchant_pattern"], row["category_id"]) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
