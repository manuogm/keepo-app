import Foundation

/// The tags the transaction form offers before the user has asked for any —
/// the ones they have used before on transactions like this one.
///
/// "Like this one" is decided by the caller's query, which counts each tag
/// twice: once over the **close** matches and once over the **broad** ones.
/// For an expense or income, broad is every transaction in the same
/// category and close is the ones on the same account too. For a transfer,
/// which has no category, broad is every transfer that leaves the same
/// origin or reaches the same destination, and close is the ones between
/// that exact pair.
///
/// Ranked close first, then broad, so on a busy category the account the
/// user is entering against decides which three they see — a tag used
/// twice on this card beats one used ten times on another. Name breaks a
/// tie, so the row is the same every time it is drawn.
public enum TagSuggestions {
    /// Three, never more: a row of suggestions longer than that stops being
    /// a shortcut and becomes a second, worse copy of the tag sheet.
    public static let limit = 3

    public struct Usage: Equatable, Sendable {
        public let tagId: String
        public let name: String
        /// Transactions with this tag among the close matches.
        public let close: Int
        /// Transactions with this tag among the broad matches, close ones
        /// included.
        public let broad: Int

        public init(tagId: String, name: String, close: Int, broad: Int) {
            self.tagId = tagId
            self.name = name
            self.close = close
            self.broad = broad
        }
    }

    /// The tag ids to suggest, best first, at most `limit`. A tag never
    /// used on anything alike is never suggested.
    public static func rank(_ usage: [Usage], limit: Int = limit) -> [String] {
        usage
            .filter { $0.broad > 0 }
            .sorted { lhs, rhs in
                if lhs.close != rhs.close { return lhs.close > rhs.close }
                if lhs.broad != rhs.broad { return lhs.broad > rhs.broad }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(limit)
            .map(\.tagId)
    }
}
