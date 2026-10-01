import Foundation

/// The one place a Wallet capture's raw merchant string becomes the
/// canonical form used for merchant learning (`merchant_category_map`) and
/// idempotency (`CaptureIdentity.externalId`). `merchant_raw` is always kept
/// alongside it — see `capture_transaction` — so normalization can improve
/// later without re-capturing anything.
///
/// **The rule the matchers turn on: punctuation *inside* a name is
/// identity; punctuation at a *boundary* is a separator.** Real Square
/// output is `SQ * Equity Park,Llc`, and matching corporate suffixes
/// against a literal leading space produced three learning keys for one
/// shop — `EQUITY PARK,LLC`, `EQUITY PARK`, `EQUITY PARK,` — so a category
/// learned under one never matched the next. The fix is not to strip
/// punctuation, which was measured and rejected: it collides distinct
/// payees (`M&S` with `MS`, `H&M` with `HM`), it glues suffixes on
/// (`EQUITY PARKLLC`), and removing the `*` from `SQ *` stops the
/// aggregator prefix matching at all, leaving `SQ` as noise in every
/// result. The punctuation stays and the boundaries become patterns.
///
/// What this still does not fix, and is fine: `AT&T` against `AT AND T`,
/// `MCDONALDS` against `MC DONALDS`, truncated descriptors, and company
/// forms outside `MerchantTokens`. That is a fuzzy layer's remit if one is
/// ever wanted — it is explicitly **not** the mechanism, because several
/// `merchant_category_map` rows per shop is the thing normalization exists
/// to prevent.
public enum MerchantNormalizer {
    /// - Returns: an uppercased, whitespace-normalized merchant name with
    ///   aggregator prefixes, company forms and trailing store numbers
    ///   stripped. Never empty for non-empty input — a string that is
    ///   entirely noise falls back to its own trimmed, uppercased self.
    public static func normalize(_ raw: String) -> String {
        // Uppercased once, up front, rather than per comparison: every
        // pattern below is written in upper case and the result is
        // uppercased anyway, so this is the only place case is decided.
        let cleaned = collapseWhitespace(raw.trimmingCharacters(in: .whitespacesAndNewlines)).uppercased()
        var value = strip(Patterns.aggregatorPrefix, from: cleaned)
        value = strip(Patterns.companyPrefix, from: value)

        // A store number and a company form appear in either order
        // (`STORE 00042 LLC` and `STORE LLC 00042`), and stripping one can
        // expose the other, so all three run until nothing more matches.
        // That loop is also what makes this function **idempotent**, which
        // is now an explicit test rather than a claim in a comment.
        var previous: String
        repeat {
            previous = value
            value = trimBoundary(strip(Patterns.trailingStoreNumber, from: value))
            value = trimBoundary(strip(Patterns.corporateSuffix, from: value))
            value = trimBoundary(strip(Patterns.ideographicCompanyForm, from: value))
        } while value != previous

        return value.isEmpty ? cleaned : value
    }

    private static func strip(_ pattern: String, from value: String) -> String {
        value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// The separators a strip can leave stranded at an edge — the comma in
    /// `EQUITY PARK,` once ` LLC` has gone, and the dash in `FOO - LLC`.
    /// Run after **every** strip, not once at the end, because the next
    /// pass's `[\s,]+` boundary has to see a clean edge to match against.
    private static func trimBoundary(_ value: String) -> String {
        value.trimmingCharacters(in: boundaryCharacters)
    }

    private static let boundaryCharacters = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: ",;-–—"))

    private static func collapseWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

private extension MerchantNormalizer {
    enum Patterns {
        /// `SQ *`, `SQ*`, `SUMUP * ` — one pattern where there used to be a
        /// pair of literals per aggregator, tolerating whatever spacing the
        /// acquirer emits around the star.
        static let aggregatorPrefix = "^(?:\(alternation(MerchantTokens.aggregators)))\\s*\\*\\s*"

        /// Whitespace behind it is required, and an optional dot allowed, so
        /// `PT. SUMBER REJEKI` resolves and `PTY LTD` is left alone.
        static let companyPrefix = "^(?:\(alternation(MerchantTokens.companyPrefixes)))\\.?\\s+"

        /// `[\s,]+` as the boundary rather than a literal leading space —
        /// the actual defect. `,LLC` matches here where ` LLC` could not.
        static let corporateSuffix = "[\\s,]+(?:\(alternation(MerchantTokens.corporateSuffixes)))$"

        /// Either end, no separator — CJK company forms run straight into
        /// the name.
        static let ideographicCompanyForm: String = {
            let forms = alternation(MerchantTokens.ideographicCompanyForms)
            return "^(?:\(forms))|(?:\(forms))$"
        }()

        /// Three digits or more, so `SHELL OIL 66` keeps its 66 while
        /// `TARGET 00123` and `TARGET #4821` lose their store id.
        static let trailingStoreNumber = #"[\s,]+#?\d{3,}$"#

        /// **Longest-first is load-bearing.** Alternation is first-match-
        /// wins, so with `LTD` ahead of `PTY LTD` a Sydney café normalizes
        /// to `BONDI CAFE PTY`. Sorting here rather than hand-ordering the
        /// lists makes that correct by construction: a list can be appended
        /// to in any order without reopening this hazard.
        private static func alternation(_ tokens: [String]) -> String {
            tokens.sorted { $0.count > $1.count }
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
        }
    }
}
