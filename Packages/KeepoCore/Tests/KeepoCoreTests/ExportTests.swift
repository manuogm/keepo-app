import Foundation
import Testing

@testable import KeepoCore

/// The export's pure half: which days a period covers and what it is called,
/// and the bytes the two spreadsheet formats write.
@Suite("Export")
struct ExportTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid") ?? .current
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    // MARK: - ExportPeriod

    @Test("this month runs from its first day to the first day of the next, exclusive")
    func thisMonth() {
        let interval = ExportPeriod.thisMonth.interval(now: day(2026, 9, 23), calendar: calendar)
        #expect(interval == DateInterval(start: day(2026, 9, 1), end: day(2026, 10, 1)))
    }

    @Test("last month crosses a year boundary cleanly")
    func lastMonthInJanuary() {
        let interval = ExportPeriod.lastMonth.interval(now: day(2026, 1, 10), calendar: calendar)
        #expect(interval == DateInterval(start: day(2025, 12, 1), end: day(2026, 1, 1)))
    }

    @Test("the last twelve months include today")
    func lastTwelveMonths() {
        let interval = ExportPeriod.lastTwelveMonths.interval(now: day(2026, 9, 23), calendar: calendar)
        #expect(interval == DateInterval(start: day(2025, 9, 24), end: day(2026, 9, 24)))
    }

    @Test("all time has no window at all")
    func allTime() {
        #expect(ExportPeriod.allTime.interval(now: Date(), calendar: calendar) == nil)
        #expect(ExportPeriod.allTime.label(now: Date(), calendar: calendar) == "All time")
    }

    @Test("a custom range is inclusive of both days, whichever order they arrive in")
    func customRange() {
        let interval = ExportPeriod.custom(from: day(2026, 9, 10), through: day(2026, 9, 1))
            .interval(now: Date(), calendar: calendar)
        #expect(interval == DateInterval(start: day(2026, 9, 1), end: day(2026, 9, 11)))
    }

    @Test("a ledger window round-trips into the same days")
    func matchingLedgerWindow() {
        let window = DateInterval(start: day(2026, 9, 1), end: day(2026, 10, 1))
        let period = ExportPeriod.matching(window, calendar: calendar)
        #expect(period.interval(now: Date(), calendar: calendar) == window)
        #expect(ExportPeriod.matching(nil, calendar: calendar) == .allTime)
    }

    @Test("a period's days are its first and last day included")
    func days() {
        let now = day(2026, 9, 23)
        #expect(ExportPeriod.thisMonth.days(now: now, calendar: calendar) == day(2026, 9, 1)...day(2026, 9, 30))
        #expect(
            ExportPeriod.lastTwelveMonths.days(now: now, calendar: calendar) == day(2025, 9, 24)...day(2026, 9, 23)
        )
        #expect(ExportPeriod.allTime.days(now: now, calendar: calendar) == nil)
    }

    @Test("days picked on the calendar take a preset's name only when they are exactly its days")
    func named() {
        let now = day(2026, 9, 23)
        #expect(ExportPeriod.named(from: day(2026, 9, 1), through: day(2026, 9, 30), now: now, calendar: calendar)
            == .thisMonth)
        #expect(ExportPeriod.named(from: day(2026, 8, 1), through: day(2026, 8, 31), now: now, calendar: calendar)
            == .lastMonth)
        #expect(ExportPeriod.named(from: day(2025, 9, 24), through: day(2026, 9, 23), now: now, calendar: calendar)
            == .lastTwelveMonths)
        let near = ExportPeriod.named(from: day(2026, 9, 1), through: day(2026, 9, 29), now: now, calendar: calendar)
        #expect(near == .custom(from: day(2026, 9, 1), through: day(2026, 9, 29)))
    }

    @Test("a range that is exactly a month or a year is named as one")
    func labels() {
        let locale = Locale(identifier: "en_US")
        let month = ExportPeriod.custom(from: day(2026, 9, 1), through: day(2026, 9, 30))
        #expect(month.label(now: Date(), calendar: calendar, locale: locale) == "September 2026")
        let year = ExportPeriod.custom(from: day(2026, 1, 1), through: day(2026, 12, 31))
        #expect(year.label(now: Date(), calendar: calendar, locale: locale) == "2026")
        let single = ExportPeriod.custom(from: day(2026, 9, 23), through: day(2026, 9, 23))
        #expect(single.label(now: Date(), calendar: calendar, locale: locale) == "Sep 23, 2026")
        let span = ExportPeriod.custom(from: day(2026, 8, 1), through: day(2026, 9, 23))
        #expect(span.label(now: Date(), calendar: calendar, locale: locale) == "Aug 1, 2026 – Sep 23, 2026")
    }

    // MARK: - Money as a machine reads it

    @Test("a plain figure is signed, dotted, ungrouped, and rounded like the screen", arguments: [
        (Int64(-12_345_000), 2, "-1234.50"),
        (Int64(4_500_000), 2, "450.00"),
        (Int64(1_000_000), 0, "100"),
        (Int64(-50), 2, "-0.01")
    ])
    func plainMoney(amountE4: Int64, minorUnit: Int, expected: String) {
        #expect(MoneyFormatter.plain(amountE4, currency: CurrencyInfo(code: "X", minorUnit: minorUnit)) == expected)
    }

    // MARK: - CSV

    private var sampleRow: ExportRow {
        ExportRow(
            day: ExportDay(year: 2026, month: 9, day: 23), title: "Coffee, with \"Beth\"", merchant: "=HYPERLINK(1)",
            category: "Dining", account: "Checking", kind: "Expense",
            amount: ExportMoney(amountE4: -45_000, currency: CurrencyInfo(code: "EUR", minorUnit: 2)),
            baseAmountE4: nil, original: nil, tags: ["Work", "Trip"], notes: "Line one\nline two", status: "Confirmed"
        )
    }

    @Test("a CSV starts with a BOM, ends lines with CRLF, and quotes what needs quoting")
    func csvShape() throws {
        let base = CurrencyInfo(code: "EUR", minorUnit: 2)
        let data = CSVWriter.document(
            header: ExportTable.header(baseCurrency: "EUR"),
            rows: [ExportTable.cells(sampleRow, baseCurrency: base)]
        )
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = try #require(String(data: data.dropFirst(3), encoding: .utf8))
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines.first?.hasPrefix("Date,Title,Merchant,Category,Account,Type,Amount,Currency,Amount (EUR)") == true)
        #expect(text.contains("2026-09-23,\"Coffee, with \"\"Beth\"\"\","))
        #expect(text.contains(",-4.50,EUR,,"), "a missing conversion is an empty cell, never a zero")
        #expect(text.contains("\"Line one\nline two\""))
    }

    @Test("a text cell that starts like a formula is defused; a negative amount is not")
    func csvFormulaGuard() {
        #expect(CSVWriter.text(.text("=HYPERLINK(1)")) == "'=HYPERLINK(1)")
        #expect(CSVWriter.text(.money("-4.50", minorUnit: 2)) == "-4.50")
        #expect(CSVWriter.text(.text("Starbucks")) == "Starbucks")
    }

    // MARK: - Excel

    @Test("a spreadsheet date is days since 1899-12-30", arguments: [
        (ExportDay(year: 1900, month: 3, day: 1), 61),
        (ExportDay(year: 2026, month: 9, day: 23), 46_288)
    ])
    func serialDates(day: ExportDay, serial: Int) {
        #expect(XLSXWriter.serial(day) == serial)
    }

    @Test("columns are lettered the spreadsheet way", arguments: [(0, "A"), (13, "N"), (25, "Z"), (26, "AA")])
    func columnNames(index: Int, name: String) {
        #expect(XLSXWriter.columnName(index) == name)
    }

    @Test("XML escaping handles markup and drops what XML cannot carry")
    func xmlEscaping() {
        #expect(XLSXWriter.escape("A & B <c> \"d\"\u{0001}") == "A &amp; B &lt;c&gt; &quot;d&quot;")
    }

    @Test("money cells are numbers and dates are serials, not strings")
    func typedCells() {
        let base = CurrencyInfo(code: "EUR", minorUnit: 2)
        let sheet = XLSXWriter.sheet(
            header: ExportTable.header(baseCurrency: "EUR"),
            rows: [ExportTable.cells(sampleRow, baseCurrency: base)]
        )
        #expect(sheet.contains("<c r=\"A2\" s=\"2\"><v>46288</v></c>"))
        #expect(sheet.contains("<c r=\"G2\" s=\"3\"><v>-4.50</v></c>"))
        #expect(!sheet.contains("r=\"I2\""), "a missing conversion writes no cell at all")
    }

    // MARK: - The zip container

    @Test("CRC-32 matches the reference check value")
    func crc() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("an xlsx is a well-formed zip that begins with a local header")
    func xlsxIsAZip() throws {
        let base = CurrencyInfo(code: "EUR", minorUnit: 2)
        let data = XLSXWriter.document(
            sheetName: "Transactions", header: ExportTable.header(baseCurrency: "EUR"),
            rows: [ExportTable.cells(sampleRow, baseCurrency: base)]
        )
        #expect(data.starts(with: [0x50, 0x4B, 0x03, 0x04]))
        #if os(macOS)
        // The real test: the system's own unzip verifies every CRC and every
        // offset, which is exactly what Excel does before it opens anything.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keepo-\(UUID().uuidString).xlsx")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", url.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #endif
    }
}
