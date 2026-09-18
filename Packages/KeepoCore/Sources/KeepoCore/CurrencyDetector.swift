import Foundation

/// Reads the currency out of Wallet's machine-formatted `Amount` string —
/// "€50.00", "1,06 US$", "CHF 10.00" — so a purchase charged in a currency
/// other than the account's can be recognised instead of silently recorded
/// as if it were in the account's (money rule 6).
///
/// **It does not carry a symbol table, and that is the design.** A
/// hand-written `$ → USD` map is a guess about what some formatter meant;
/// this inverts *the same table Foundation used to produce the string*,
/// restricted to the currencies Keepo actually supports. A symbol resolves
/// only when exactly one supported currency could have produced it, so the
/// ambiguity rule is **derived rather than asserted** — which matters,
/// because the honest answer changes by device:
///
/// - On a British, German or Spanish phone, `$` is unambiguously USD:
///   those locales write `CA$`, `A$` and `MX$` for the other dollars.
/// - On an Australian, Canadian, Singaporean, New Zealand or Mexican
///   phone, `$` means the **local** dollar, and there is no way to tell it
///   from a US one. Detection returns `nil` and the capture falls back to
///   the account's currency, exactly as before this existed.
/// - `¥` is JPY almost everywhere and CNY on a Chinese phone, so it
///   resolves there too — to nothing.
///
/// The device's own table is unioned with `en_US`'s, because the string was
/// not necessarily formatted by this device: **a disagreement between the
/// two is itself a reason not to act.** That union is what turns `$` on an
/// Australian phone into "don't know" rather than a coin flip between two
/// real answers.
///
/// Wrong here is expensive — it would convert an amount that never needed
/// converting — and silence is cheap, because silence is the behaviour
/// that shipped for a year. So every uncertain case returns `nil`.
public enum CurrencyDetector {
    /// - Parameter supported: the codes in the `currencies` reference
    ///   table. Restricting to them is what makes detection possible at
    ///   all — inverted over every ISO currency, `$` names dozens.
    /// - Returns: the detected code, or `nil` when the string names no
    ///   supported currency **or** names more than one. The caller must
    ///   treat `nil` as "use the account's currency", never as an error.
    public static func detect(in text: String, supported: [String], locale: Locale = .current) -> String? {
        let codes = supported.map { $0.uppercased() }
        guard !codes.isEmpty else { return nil }

        // An explicit ISO code wins outright, and it is not a rare case:
        // Spanish and Swedish phones render most foreign currencies as the
        // bare code ("1,06 CAD", "SEK 1,06"), and a code cannot be
        // ambiguous with anything.
        let spelled = codes.filter { contains(code: $0, in: text) }
        if spelled.count == 1 { return spelled[0] }
        if spelled.count > 1 { return nil }

        // Longest match first, so `US$` beats the `$` inside it and `R$`
        // (Brazil) beats the `R` (South Africa) inside it.
        let table = symbolTable(for: codes, locale: locale)
        let matches = table.keys
            .filter { text.localizedCaseInsensitiveContains($0) }
            .sorted { $0.count > $1.count }
        guard let symbol = matches.first, let owners = table[symbol], owners.count == 1 else { return nil }
        return owners.first
    }

    /// Standalone-letters only, so a code can never be found inside a
    /// longer run of letters.
    private static func contains(code: String, in text: String) -> Bool {
        text.range(of: "(?<![A-Za-z])\(code)(?![A-Za-z])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Symbol → the supported currencies that render as it, across the
    /// device's locale and `en_US`.
    ///
    /// Built fresh rather than cached: this runs once per captured
    /// purchase, where three dozen `NumberFormatter`s cost a few
    /// milliseconds in a background App Intent. `FormatterCache` exists for
    /// the opposite shape — a formatter rebuilt hundreds of times a second
    /// inside a scrolling list — and putting these in it would retain two
    /// formatters per supported currency forever to save nothing.
    private static func symbolTable(for codes: [String], locale: Locale) -> [String: Set<String>] {
        var table: [String: Set<String>] = [:]
        for tableLocale in [locale, Locale(identifier: "en_US")] {
            for code in codes {
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.locale = tableLocale
                formatter.currencyCode = code
                guard let symbol = formatter.currencySymbol, !symbol.isEmpty else { continue }
                table[symbol, default: []].insert(code)
            }
        }
        return table
    }
}

public extension CurrencyDetector {
    /// The currency mark as it literally appeared in Wallet's string, with
    /// no attempt to say what it means — `"$"`, `"US$"`, `"CHF"`, `"kr"`.
    ///
    /// **This is not detection and must never be treated as it.** `detect`
    /// above answers "which supported currency is this?" and refuses
    /// whenever the honest answer is more than one, because a wrong answer
    /// there converts an amount that never needed converting. This answers
    /// only "what characters did Wallet print next to the digits?", which
    /// has no wrong answer — it is the input, echoed back.
    ///
    /// That distinction is what makes it safe to show a mark Keepo cannot
    /// resolve. A capture on an unmapped card in an ambiguous currency has
    /// no account currency to fall back on and no detected code either, so
    /// the notification used to render a bare `5,000.00`. It can now render
    /// `$5,000.00` — the same glyph the user just saw on the terminal —
    /// while the stored row still, correctly, claims no currency at all.
    ///
    /// Display only. It never reaches a payload, a column, or `fx_convert`.
    struct SymbolHint: Equatable, Sendable {
        /// Every character that was neither a digit nor formatting noise,
        /// in the order it appeared.
        public let token: String
        /// Whether it led the digits (`$5.00`) or trailed them (`5,00 €`).
        public let isPrefix: Bool

        public init(token: String, isPrefix: Bool) {
            self.token = token
            self.isPrefix = isPrefix
        }

        /// The mark reattached to an already-formatted figure, spaced the
        /// way the conventions that use each shape space it: a glyph sits
        /// tight against a leading figure (`$5.00`) and a code does not
        /// (`CHF 5.00`), and anything trailing takes a non-breaking space
        /// so the pair cannot wrap apart in a notification title.
        public func applied(to formattedAmount: String) -> String {
            guard isPrefix else { return formattedAmount + "\u{00A0}" + token }
            let separator = token.allSatisfy(\.isLetter) ? "\u{00A0}" : ""
            return token + separator + formattedAmount
        }
    }

    /// - Returns: `nil` when the string carries no digits, no mark at all
    ///   (a bare `50.00`), or a mark too long to be one — see below.
    static func symbol(in text: String) -> SymbolHint? {
        var token = ""
        var firstSymbol: Int?
        var firstDigit: Int?

        for (offset, character) in text.enumerated() {
            if character.isASCII && character.isNumber {
                if firstDigit == nil { firstDigit = offset }
            } else if !isFormattingNoise(character) {
                if firstSymbol == nil { firstSymbol = offset }
                token.append(character)
            }
        }

        guard let firstDigit, let firstSymbol, !token.isEmpty else { return nil }
        // No currency renders as more than four characters (`MOP$`, `CHF`,
        // `US$`, `kr`), so a longer run is not a currency mark — it is a
        // string that was never a machine-formatted amount in the first
        // place, and echoing it into a notification title would be worse
        // than the bare figure this exists to replace.
        guard token.count <= 4 else { return nil }
        return SymbolHint(token: token, isPrefix: firstSymbol < firstDigit)
    }

    /// Everything `AmountParser.plainDecimalString` also discards: the two
    /// separator characters, every grouping mark that is not one (the Swiss
    /// apostrophe, the spaces France, Sweden and Hungary group with), and
    /// the sign in both its ASCII and typographic forms.
    private static func isFormattingNoise(_ character: Character) -> Bool {
        character == "." || character == "," || character == "'" || character == "\u{2019}"
            || character == "-" || character == "\u{2212}" || character.isWhitespace
    }
}
