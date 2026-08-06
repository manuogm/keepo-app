import Foundation

/// One parsed CSV row, ready to hand to `ImportRepository.importRows` —
/// matching happens server-side (`import_csv_rows`), this only turns text
/// into typed fields. Reuses `AmountParser` rather than a bespoke numeric
/// parse (money rule: one place), never `Double` (money rule: never for
/// money).
public struct CSVImportRow: Sendable, Equatable {
    public let occurredAt: Date
    public let amount: Decimal
    public let merchantRaw: String?

    public init(occurredAt: Date, amount: Decimal, merchantRaw: String?) {
        self.occurredAt = occurredAt
        self.amount = amount
        self.merchantRaw = merchantRaw
    }
}

public enum CSVImportParseError: Error, Equatable {
    case empty
    case missingColumn(String)
    case unparseableDate(line: Int, value: String)
    case unparseableAmount(line: Int, value: String)
}

/// A minimal, dependency-free CSV parser for bank/card statement exports.
/// Deliberately narrow: header-driven column lookup for `date`/`amount`/
/// `description` (case-insensitive, a few common synonyms), positional
/// fallback (date, amount, description) when no recognizable header
/// exists. Full RFC 4180 quoting (commas and escaped quotes inside a
/// quoted field) is supported since merchant descriptions routinely
/// contain commas; multi-line quoted fields are not, which every
/// consumer-bank export this was tested against never produces.
public enum CSVImportParser {
    private static let dateColumnNames = ["date", "occurred_at", "transaction date", "posted date"]
    private static let amountColumnNames = ["amount", "value", "debit/credit"]
    private static let merchantColumnNames = ["description", "merchant", "name", "payee"]

    public static func parse(_ csv: String) throws -> [CSVImportRow] {
        let lines = csv
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { throw CSVImportParseError.empty }

        let allFields = lines.map(splitFields)
        let header = allFields[0].map { $0.lowercased() }

        let dateIndex = header.firstIndex { dateColumnNames.contains($0) }
        let amountIndex = header.firstIndex { amountColumnNames.contains($0) }
        let merchantIndex = header.firstIndex { merchantColumnNames.contains($0) }

        let hasHeader = dateIndex != nil || amountIndex != nil
        let dataRows = hasHeader ? Array(allFields.dropFirst()) : allFields

        let resolvedDateIndex = dateIndex ?? 0
        let resolvedAmountIndex = amountIndex ?? 1
        let resolvedMerchantIndex = merchantIndex ?? 2

        return try dataRows.enumerated().map { offset, fields in
            let lineNumber = offset + (hasHeader ? 2 : 1)
            let dateText = field(fields, at: resolvedDateIndex)
            let amountText = field(fields, at: resolvedAmountIndex)

            guard let date = parseDate(dateText) else {
                throw CSVImportParseError.unparseableDate(line: lineNumber, value: dateText)
            }
            guard let amount = AmountParser.parse(amountText, locale: Locale(identifier: "en_US")) else {
                throw CSVImportParseError.unparseableAmount(line: lineNumber, value: amountText)
            }

            let merchant = field(fields, at: resolvedMerchantIndex)
            return CSVImportRow(occurredAt: date, amount: amount, merchantRaw: merchant.isEmpty ? nil : merchant)
        }
    }

    private static func field(_ fields: [String], at index: Int) -> String {
        index < fields.count ? fields[index] : ""
    }

    private static let dateFormats = ["yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "M/d/yy", "MM/dd/yy"]

    private static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Splits one CSV line into fields, honoring double-quoted fields
    /// (commas and escaped `""` inside quotes never split or corrupt).
    private static func splitFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        var iterator = line.makeIterator()
        var pending: Character?

        while let char = pending ?? iterator.next() {
            pending = nil
            if insideQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")
                        } else {
                            insideQuotes = false
                            pending = next
                        }
                    } else {
                        insideQuotes = false
                    }
                } else {
                    current.append(char)
                }
            } else if char == "\"" {
                insideQuotes = true
            } else if char == "," {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }
}
