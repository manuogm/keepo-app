import Foundation
import Testing
@testable import KeepoCore

@Suite("CSVImportParser")
struct CSVImportParserTests {
    @Test("parses a standard header with date/amount/description columns")
    func parsesStandardHeader() throws {
        let csv = "Date,Amount,Description\n2026-01-15,-42.50,Blue Bottle Coffee\n2026-01-16,1200.00,Payroll"
        let rows = try CSVImportParser.parse(csv)
        #expect(rows.count == 2)
        #expect(rows[0].amountE4 == -425000)
        #expect(rows[0].merchantRaw == "Blue Bottle Coffee")
        #expect(rows[1].amountE4 == 12000000)
    }

    @Test("a quoted merchant field containing a comma is not split into two fields")
    func handlesQuotedCommas() throws {
        let csv = "Date,Amount,Description\n2026-01-15,-9.99,\"Cafe, Downtown\""
        let rows = try CSVImportParser.parse(csv)
        #expect(rows.count == 1)
        #expect(rows[0].merchantRaw == "Cafe, Downtown")
    }

    @Test("falls back to positional (date, amount, description) with no recognizable header")
    func fallsBackToPositional() throws {
        let csv = "2026-01-15,-42.50,Blue Bottle Coffee"
        let rows = try CSVImportParser.parse(csv)
        #expect(rows.count == 1)
        #expect(rows[0].amountE4 == -425000)
    }

    @Test("empty input throws, never returns an empty success")
    func emptyInputThrows() {
        #expect(throws: CSVImportParseError.empty) {
            try CSVImportParser.parse("")
        }
    }

    @Test("an unparseable amount throws with the offending line number")
    func unparseableAmountThrows() {
        let csv = "Date,Amount,Description\n2026-01-15,not-a-number,Coffee"
        #expect(throws: CSVImportParseError.unparseableAmount(line: 2, value: "not-a-number")) {
            try CSVImportParser.parse(csv)
        }
    }

    @Test("a merchant column with an empty value decodes as nil, not an empty string")
    func emptyMerchantIsNil() throws {
        let csv = "Date,Amount,Description\n2026-01-15,-9.99,"
        let rows = try CSVImportParser.parse(csv)
        #expect(rows[0].merchantRaw == nil)
    }
}
