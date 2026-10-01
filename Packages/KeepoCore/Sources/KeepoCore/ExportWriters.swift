import Foundation

/// CSV, as the widest possible audience reads it — RFC 4180 quoting, CRLF line
/// ends, and a UTF-8 byte-order mark.
///
/// The BOM is the part that looks optional and is not: Excel opens a UTF-8
/// file without one as the machine's legacy code page, so "Café" arrives as
/// "CafÃ©". Numbers, Google Sheets and every importer worth the name read it
/// and move on.
public enum CSVWriter {
    public static func document(header: [String], rows: [[ExportTable.Cell]]) -> Data {
        var lines = [header.map(field).joined(separator: ",")]
        for row in rows {
            lines.append(row.map { field(text($0)) }.joined(separator: ","))
        }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Dates as ISO 8601 and money as plain machine figures: a CSV has no
    /// types, so the only safe spelling is the one no reader can misread.
    ///
    /// **A text cell that starts like a formula is defused** with a leading
    /// apostrophe (OWASP's CSV-injection mitigation). A merchant name comes
    /// from a card network, not from the user, and `=HYPERLINK(...)` in one is
    /// a formula the spreadsheet would run on open. Money cells are exempt —
    /// they are ours, and a leading minus there is a sign, not an attack.
    static func text(_ cell: ExportTable.Cell) -> String {
        switch cell {
        case .text(let value):
            guard let first = value.first, "=+-@\t\r".contains(first) else { return value }
            return "'" + value
        case .money(let figure, _): return figure
        case .date(let day): return day.iso
        case .empty: return ""
        }
    }

    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// A single-sheet `.xlsx` — the smallest SpreadsheetML package Excel, Numbers
/// and Google Sheets all open without complaint: six XML parts in a stored zip.
///
/// **Why bother, when CSV exists**: here a date is a date and an amount is a
/// number, stored as values and *displayed* in the reader's own locale. A
/// Spanish Excel shows `1.234,50` and `23/09/2026`, sums the column, and sorts
/// by date, because nothing was ever a string. That is the whole reason this
/// format is offered.
///
/// Text goes in as inline strings rather than a shared-strings table: one
/// part fewer, and the size saving a shared table buys only matters for files
/// far larger than one person's ledger.
public enum XLSXWriter {
    public static func document(sheetName: String, header: [String], rows: [[ExportTable.Cell]]) -> Data {
        ZipArchive.stored([
            .init(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            .init(path: "_rels/.rels", data: Data(packageRelationships.utf8)),
            .init(path: "xl/workbook.xml", data: Data(workbook(sheetName: sheetName).utf8)),
            .init(path: "xl/_rels/workbook.xml.rels", data: Data(workbookRelationships.utf8)),
            .init(path: "xl/styles.xml", data: Data(styles.utf8)),
            .init(path: "xl/worksheets/sheet1.xml", data: Data(sheet(header: header, rows: rows).utf8))
        ])
    }

    // MARK: - The sheet

    /// Style indexes into `styles`' `cellXfs`, in order.
    private enum Style: Int {
        case plain = 0, header, date, money2, money0
    }

    static func sheet(header: [String], rows: [[ExportTable.Cell]]) -> String {
        var xml = xmlDeclaration
        xml += "<worksheet xmlns=\"\(mainNamespace)\">"
        // The header row stays put while the rows scroll under it.
        xml += "<sheetViews><sheetView workbookViewId=\"0\">"
        xml += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
        xml += "</sheetView></sheetViews>"
        xml += "<cols>"
        for index in header.indices {
            let width = index < columnWidths.count ? columnWidths[index] : 14
            xml += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }
        xml += "</cols><sheetData>"
        xml += row(1, header.map { ExportTable.Cell.text($0) }, isHeader: true)
        for (offset, cells) in rows.enumerated() {
            xml += row(offset + 2, cells, isHeader: false)
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    /// Characters wide, per column, in `ExportTable.header` order — wide
    /// enough that a typical value is readable without the reader resizing
    /// anything, which is most of what makes a file feel finished.
    private static let columnWidths = [12, 24, 24, 16, 18, 10, 14, 10, 14, 16, 17, 20, 30, 11]

    private static func row(_ number: Int, _ cells: [ExportTable.Cell], isHeader: Bool) -> String {
        var xml = "<row r=\"\(number)\">"
        for (index, cell) in cells.enumerated() {
            let reference = "\(columnName(index))\(number)"
            switch cell {
            case .empty:
                continue
            case .text(let value):
                let style = isHeader ? " s=\"\(Style.header.rawValue)\"" : ""
                xml += "<c r=\"\(reference)\" t=\"inlineStr\"\(style)><is>"
                xml += "<t xml:space=\"preserve\">\(escape(value))</t></is></c>"
            case .money(let figure, let minorUnit):
                let style = minorUnit == 0 ? Style.money0 : Style.money2
                xml += "<c r=\"\(reference)\" s=\"\(style.rawValue)\"><v>\(figure)</v></c>"
            case .date(let day):
                xml += "<c r=\"\(reference)\" s=\"\(Style.date.rawValue)\"><v>\(serial(day))</v></c>"
            }
        }
        return xml + "</row>"
    }

    /// `A`…`Z`, `AA`…: bijective base 26.
    static func columnName(_ index: Int) -> String {
        var number = index + 1
        var name = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            number = (number - 1) / 26
        }
        return name
    }

    /// Days since 1899-12-30, which is how a spreadsheet stores a date.
    /// Worked out from the calendar fields alone — no `Date`, no time zone —
    /// so the cell is the day the user saw in the ledger and cannot shift by
    /// one on its way through an instant.
    static func serial(_ day: ExportDay) -> Int {
        daysFromCivil(day.year, day.month, day.day) - daysFromCivil(1899, 12, 30)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard
    /// Hinnant's `days_from_civil`).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// XML-escaped, with the control characters XML 1.0 cannot carry at all
    /// dropped rather than escaped — a stray one from a pasted note would
    /// otherwise make Excel refuse the entire file.
    static func escape(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "\t", "\n", "\r": escaped.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    // MARK: - The package

    private static let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let spreadsheetTypes = "application/vnd.openxmlformats-officedocument.spreadsheetml"

    private static let contentTypes = xmlDeclaration
        + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"\(spreadsheetTypes).sheet.main+xml\"/>"
        + "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"\(spreadsheetTypes).worksheet+xml\"/>"
        + "<Override PartName=\"/xl/styles.xml\" ContentType=\"\(spreadsheetTypes).styles+xml\"/>"
        + "</Types>"

    private static let packageRelationships = xmlDeclaration
        + "<Relationships xmlns=\"\(relationshipNamespace)\">"
        + "<Relationship Id=\"rId1\" Type=\"\(officeRelationships)/officeDocument\" Target=\"xl/workbook.xml\"/>"
        + "</Relationships>"

    private static func workbook(sheetName: String) -> String {
        xmlDeclaration
            + "<workbook xmlns=\"\(mainNamespace)\" xmlns:r=\"\(officeRelationships)\">"
            + "<sheets><sheet name=\"\(escape(sheetName))\" sheetId=\"1\" r:id=\"rId1\"/></sheets>"
            + "</workbook>"
    }

    private static let workbookRelationships = xmlDeclaration
        + "<Relationships xmlns=\"\(relationshipNamespace)\">"
        + "<Relationship Id=\"rId1\" Type=\"\(officeRelationships)/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
        + "<Relationship Id=\"rId2\" Type=\"\(officeRelationships)/styles\" Target=\"styles.xml\"/>"
        + "</Relationships>"

    /// Built-in number formats only, so every reader renders them in its own
    /// locale: 14 is the short date, 4 is `#,##0.00`, 3 is `#,##0` (for a
    /// zero-decimal currency).
    private static let styles = xmlDeclaration
        + "<styleSheet xmlns=\"\(mainNamespace)\">"
        + "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font>"
        + "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
        + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill>"
        + "<fill><patternFill patternType=\"gray125\"/></fill></fills>"
        + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        + "<cellXfs count=\"5\">"
        + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        + "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
        + "<xf numFmtId=\"14\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        + "<xf numFmtId=\"4\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        + "<xf numFmtId=\"3\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        + "</cellXfs>"
        + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        + "</styleSheet>"
}
