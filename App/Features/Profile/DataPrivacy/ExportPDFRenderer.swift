import KeepoCore
import SwiftUI
import UIKit

/// The PDF export: a statement a person reads — what period, which accounts,
/// what came in and went out, and then every transaction, one line each.
///
/// **Written for paper, not for the screen.** Colours are the palette's
/// light-appearance values whatever the phone is set to (a dark-mode export
/// would print white text on white paper), sizes are the text styles at the
/// default Dynamic Type size (a document should not change with the reader's
/// accessibility setting on the day it was made), and the page is A4 or US
/// Letter by the device's own measurement system.
///
/// **A transfer is one line**, "Checking → Savings", exactly as the ledger
/// shows it, because this is the format for reading. The spreadsheet formats
/// keep both legs, because those are for summing.
enum ExportPDFRenderer {
    struct Statement {
        let periodLabel: String
        let accountsLabel: String
        let generatedAt: Date
        let totals: [LocalExportQueries.CurrencyTotals]
        let entries: [TransactionEntry]
    }

    static func render(_ statement: Statement) -> Data {
        let page = pageRect
        let content = page.insetBy(dx: margin, dy: margin)
        let pages = paginate(statement, content: content)
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: documentFormat)
        return renderer.pdfData { context in
            for (index, rows) in pages.enumerated() {
                context.beginPage()
                var cursor = content.minY
                if index == 0 {
                    cursor = drawHeader(statement, in: content, at: cursor)
                }
                cursor = drawColumnHeader(in: content, at: cursor)
                for entry in rows {
                    drawRow(entry, in: content, at: cursor)
                    cursor += rowHeight
                }
                drawFooter(page: index + 1, of: pages.count, in: content)
            }
            if pages.isEmpty {
                context.beginPage()
                _ = drawHeader(statement, in: content, at: content.minY)
                drawFooter(page: 1, of: 1, in: content)
            }
        }
    }

    // MARK: - Pages

    /// Rows per page decided up front, so the footer can say "Page 2 of 5"
    /// on page 2.
    private static func paginate(_ statement: Statement, content: CGRect) -> [[TransactionEntry]] {
        let available = content.height - footerHeight - columnHeaderHeight
        let firstPage = max(1, Int((available - headerHeight(statement)) / rowHeight))
        let otherPages = max(1, Int(available / rowHeight))
        var pages: [[TransactionEntry]] = []
        var remaining = statement.entries[...]
        while !remaining.isEmpty {
            let take = pages.isEmpty ? firstPage : otherPages
            pages.append(Array(remaining.prefix(take)))
            remaining = remaining.dropFirst(take)
        }
        return pages
    }

    private static func headerHeight(_ statement: Statement) -> CGFloat {
        font(.title1).lineHeight + font(.subheadline).lineHeight + font(.footnote).lineHeight
            + AppTheme.Spacing.xl + CGFloat(statement.totals.count) * summaryLineHeight
            + (statement.totals.isEmpty ? 0 : AppTheme.Spacing.xl)
    }

    // MARK: - Drawing

    private static func drawHeader(_ statement: Statement, in content: CGRect, at top: CGFloat) -> CGFloat {
        var cursor = top
        cursor = draw("Transactions", font: font(.title1, bold: true), color: ink, in: content, at: cursor)
        cursor = draw(
            "\(statement.periodLabel) · \(statement.accountsLabel)", font: font(.subheadline), color: ink,
            in: content, at: cursor
        )
        let generated = statement.generatedAt.formatted(date: .abbreviated, time: .omitted)
        let count = statement.entries.count
        cursor = draw(
            "Exported from Keepo on \(generated) · \(count) transaction\(count == 1 ? "" : "s")",
            font: font(.footnote), color: secondaryInk, in: content, at: cursor
        )
        cursor += AppTheme.Spacing.xl

        for totals in statement.totals {
            let currency = totals.currency
            let line = [
                currency.code,
                "Income \(MoneyFormatter.format(totals.incomeE4, currency: currency))",
                "Expenses \(MoneyFormatter.format(totals.expensesE4, currency: currency, signStyle: .magnitude))",
                "Net \(MoneyFormatter.format(totals.netE4, currency: currency))"
            ].joined(separator: "     ")
            _ = draw(line, font: font(.footnote, bold: true), color: ink, in: content, at: cursor)
            cursor += summaryLineHeight
        }
        if !statement.totals.isEmpty {
            _ = draw(
                "Transfers between your own accounts are not counted as income or expenses.",
                font: font(.caption2), color: secondaryInk, in: content, at: cursor - AppTheme.Spacing.xs
            )
            cursor += AppTheme.Spacing.xl
        }
        return cursor
    }

    private static func drawColumnHeader(in content: CGRect, at top: CGFloat) -> CGFloat {
        let titles = ["Date", "Description", "Account", "Amount"]
        for (index, title) in titles.enumerated() {
            let frame = column(index, in: content, top: top, height: columnHeaderHeight)
            drawCell(title, font: font(.caption1, bold: true), color: secondaryInk, in: frame, alignRight: index == 3)
        }
        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: content.minX, y: top + columnHeaderHeight - 1))
        rule.addLine(to: CGPoint(x: content.maxX, y: top + columnHeaderHeight - 1))
        rule.lineWidth = 0.5
        secondaryInk.setStroke()
        rule.stroke()
        return top + columnHeaderHeight
    }

    private static func drawRow(_ entry: TransactionEntry, in content: CGRect, at top: CGFloat) {
        let row = entry.transaction
        let legs = entry.counterpart.map { other in
            (row.amountE4 ?? 0) < 0 ? (from: row, to: other) : (from: other, to: row)
        }
        let shown = legs?.from ?? row
        let isTransfer = row.kind == "transfer"

        let date = row.occurredAt.flatMap(PostgresDate.date(fromTimestamp:))
            .map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "—"
        let headline = row.title ?? (isTransfer ? "Transfer" : (row.categoryName ?? "—"))
        let detail = row.title != nil ? (isTransfer ? nil : row.categoryName) : row.merchantRaw
        let description = [headline, detail].compactMap { $0 }.joined(separator: " · ")
        let account = legs.map { "\($0.from.accountName ?? "—") → \($0.to.accountName ?? "—")" }
            ?? (row.accountName ?? "—")
        let amount: String = {
            guard let code = shown.currency, let minorUnit = shown.minorUnit else { return "—" }
            let currency = CurrencyInfo(code: code, minorUnit: Int(minorUnit))
            return MoneyFormatter.format(
                shown.amountE4, currency: currency, signStyle: legs == nil ? .standard : .magnitude
            )
        }()

        let cells = [date, description, account, amount]
        for (index, text) in cells.enumerated() {
            let frame = column(index, in: content, top: top, height: rowHeight)
            drawCell(text, font: font(.caption1), color: ink, in: frame, alignRight: index == 3)
        }
    }

    private static func drawFooter(page: Int, of pageCount: Int, in content: CGRect) {
        let frame = CGRect(
            x: content.minX, y: content.maxY - footerHeight, width: content.width, height: footerHeight
        )
        drawCell("Keepo", font: font(.caption2), color: secondaryInk, in: frame, alignRight: false)
        drawCell(
            "Page \(page) of \(pageCount)", font: font(.caption2), color: secondaryInk, in: frame, alignRight: true
        )
    }

    // MARK: - Primitives

    /// One line of text across the content width; returns the next line's top.
    private static func draw(
        _ text: String, font: UIFont, color: UIColor, in content: CGRect, at top: CGFloat
    ) -> CGFloat {
        let frame = CGRect(x: content.minX, y: top, width: content.width, height: font.lineHeight)
        drawCell(text, font: font, color: color, in: frame, alignRight: false)
        return top + font.lineHeight
    }

    /// Single line, truncated at the tail — a statement row that wraps would
    /// break every row count the pagination made.
    private static func drawCell(_ text: String, font: UIFont, color: UIColor, in frame: CGRect, alignRight: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignRight ? .right : .left
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
        let lineFrame = CGRect(
            x: frame.minX, y: frame.midY - font.lineHeight / 2, width: frame.width, height: font.lineHeight
        )
        attributed.draw(with: lineFrame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    /// Date, description, account, amount — as fractions of the content
    /// width, with a gutter between them.
    private static func column(_ index: Int, in content: CGRect, top: CGFloat, height: CGFloat) -> CGRect {
        let fractions: [CGFloat] = [0.12, 0.44, 0.24, 0.20]
        let leading = fractions.prefix(index).reduce(0, +) * content.width
        let width = fractions[index] * content.width - (index == fractions.count - 1 ? 0 : AppTheme.Spacing.s)
        return CGRect(x: content.minX + leading, y: top, width: width, height: height)
    }

    // MARK: - Metrics

    /// US Letter where the device measures in inches, A4 everywhere else.
    private static var pageRect: CGRect {
        Locale.current.measurementSystem == .us
            ? CGRect(x: 0, y: 0, width: 612, height: 792)
            : CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    }

    private static let margin = AppTheme.Spacing.xxl + AppTheme.Spacing.s
    private static var rowHeight: CGFloat { font(.caption1).lineHeight + AppTheme.Spacing.s }
    private static var columnHeaderHeight: CGFloat { font(.caption1).lineHeight + AppTheme.Spacing.m }
    private static var footerHeight: CGFloat { font(.caption2).lineHeight + AppTheme.Spacing.m }
    private static var summaryLineHeight: CGFloat { font(.footnote).lineHeight + AppTheme.Spacing.xs }

    private static var documentFormat: UIGraphicsPDFRendererFormat {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "Keepo", kCGPDFContextTitle as String: "Transactions"]
        return format
    }

    /// The text styles at the default content size, so a document does not
    /// depend on the reader's Dynamic Type setting.
    private static func font(_ style: UIFont.TextStyle, bold: Bool = false) -> UIFont {
        let base = UIFont.preferredFont(
            forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        guard bold, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private static let paper = UITraitCollection(userInterfaceStyle: .light)
    private static var ink: UIColor { UIColor(AppTheme.Palette.textPrimary).resolvedColor(with: paper) }
    private static var secondaryInk: UIColor { UIColor(AppTheme.Palette.textSecondary).resolvedColor(with: paper) }
}
