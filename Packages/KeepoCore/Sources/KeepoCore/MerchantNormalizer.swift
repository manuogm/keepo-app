import Foundation

/// The one place a Wallet capture's raw merchant string becomes the
/// canonical form used for merchant learning (`merchant_category_map`) and
/// idempotency (`CaptureIdentity.externalId`). `merchant_raw` is always kept
/// alongside it — see `capture_transaction` — so normalization can improve
/// later without re-capturing anything.
public enum MerchantNormalizer {
    private static let aggregatorPrefixes = [
        "SQ *", "SQ*", "TST*", "TST *", "SP *", "SP*", "PAYPAL *", "PP *", "IZ *", "IZ*"
    ]
    private static let corporateSuffixes = [
        " LLC", " L.L.C.", " INC", " INC.", " CORP", " CORP.", " CO", " LTD", " LTD."
    ]
    private static let trailingStoreNumber = #"\s+#?\d{3,}$"#

    /// - Returns: an uppercased, whitespace-normalized merchant name with
    ///   aggregator prefixes, trailing store numbers, and corporate suffixes
    ///   stripped. Never empty for non-empty input — a string that's
    ///   entirely noise falls back to its own trimmed, uppercased self.
    public static func normalize(_ raw: String) -> String {
        var value = stripPrefix(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        // A trailing store number and a corporate suffix can appear in
        // either order ("STORE 00042 LLC" vs "STORE LLC 00042") — strip
        // both repeatedly until neither matches, so the result (and this
        // function's idempotency) never depends on which came first.
        var previous: String
        repeat {
            previous = value
            value = value.replacingOccurrences(of: trailingStoreNumber, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            value = stripSuffix(from: value)
        } while value != previous
        return collapseWhitespace(value.trimmingCharacters(in: .whitespaces)).uppercased()
    }

    private static func stripPrefix(from value: String) -> String {
        let upper = value.uppercased()
        for prefix in aggregatorPrefixes where upper.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func stripSuffix(from value: String) -> String {
        let upper = value.uppercased()
        for suffix in corporateSuffixes where upper.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
