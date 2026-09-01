import Foundation

/// `NumberFormatter()` is one of the most expensive objects in Foundation to
/// construct, and every money label in the app used to build a fresh one on
/// every render pass: `MoneyFormatter.format` per call, `AmountParser` per
/// keystroke, `AmountFormatter` per prefill. A 50-row transactions list
/// renders two money labels per row, and SwiftUI re-evaluates those bodies
/// on every unrelated state change — so scrolling and typing were both
/// paying for hundreds of formatter allocations a second. That is the actual
/// mechanism behind "the UI feels laggy", not the SQLite reads.
///
/// Formatters are cached by everything that can vary about them and reused.
/// `NumberFormatter` is not `Sendable` and is not thread-safe for
/// *configuration*, but is safe for concurrent `string(from:)`/`number(from:)`
/// reads once fully configured — every formatter here is configured exactly
/// once, inside the lock, before it is ever returned. The `NSLock` +
/// `nonisolated(unsafe)` pairing matches `LocalStore`'s own precedent for
/// process-wide shared state in this codebase.
public extension Locale {
    /// The locale every **fixed-format** date formatter in this package
    /// uses. Apple's own long-standing guidance (QA1480): a `DateFormatter`
    /// with a hand-written `dateFormat` and a user locale can render digits,
    /// eras and years the format string never asked for.
    static let posix = Locale(identifier: "en_US_POSIX")
}

enum FormatterCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [Key: NumberFormatter] = [:]

    private struct Key: Hashable {
        let style: Style
        let code: String
        let minorUnit: Int
        let localeIdentifier: String
    }

    private enum Style: Hashable {
        case currency
        /// Plain decimal, no grouping separator — what an editable text
        /// field round-trips through (`AmountFormatter`).
        case editable
        /// Plain decimal, locale-aware, producing `NSDecimalNumber` — the
        /// parse direction (`AmountParser`).
        case parsing
    }

    static func currency(code: String, minorUnit: Int, locale: Locale) -> NumberFormatter {
        formatter(.currency, code: code, minorUnit: minorUnit, locale: locale) { formatter in
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            formatter.minimumFractionDigits = minorUnit
            formatter.maximumFractionDigits = minorUnit
        }
    }

    static func editable(minorUnit: Int, locale: Locale) -> NumberFormatter {
        formatter(.editable, code: "", minorUnit: minorUnit, locale: locale) { formatter in
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.minimumFractionDigits = minorUnit
            formatter.maximumFractionDigits = minorUnit
        }
    }

    static func parsing(locale: Locale) -> NumberFormatter {
        formatter(.parsing, code: "", minorUnit: 0, locale: locale) { formatter in
            formatter.numberStyle = .decimal
            formatter.generatesDecimalNumbers = true
        }
    }

    // MARK: - Dates

    /// A cached `DateFormatter` for rendering a **date-only** value in a
    /// given calendar. `DateFormatter` is as expensive to build as
    /// `NumberFormatter`, and a list of dated rows re-renders just as often,
    /// so it belongs behind the same cache rather than being constructed per
    /// row (this file's own header explains what that cost me last time).
    ///
    /// The calendar is part of the key and is applied to the formatter's
    /// time zone as well, which is the whole point: a `date` column has no
    /// time of day and no zone, so rendering it in the device's zone shifts
    /// it a day for anyone west of UTC. See `PostgresDate.dateOnlyLabel`.
    static func dateOnly(calendar: Calendar, template: String, locale: Locale) -> DateFormatter {
        let key = DateKey(
            template: template, calendarIdentifier: "\(calendar.identifier)",
            timeZoneIdentifier: calendar.timeZone.identifier, localeIdentifier: locale.identifier
        )
        lock.lock()
        defer { lock.unlock() }
        if let cached = dateFormatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        dateFormatters[key] = formatter
        return formatter
    }

    /// A cached `DateFormatter` for a **fixed** format string — a wire
    /// format (`yyyy-MM-dd`, the SQLite timestamp boundary), never something
    /// shown to a user.
    ///
    /// Separate from `dateOnly` above because the two want opposite things
    /// from the locale. A displayed date follows the reader's locale; a
    /// value that round-trips through Postgres must not, ever — so this
    /// pins `en_US_POSIX`. That is not only a caching decision: a bare
    /// `DateFormatter` with a fixed format inherits the device locale, and
    /// under a locale whose default numbering system isn't Latin (or whose
    /// calendar isn't Gregorian, when the caller passes `.current`)
    /// `yyyy-MM-dd` renders digits or a year Postgres cannot parse. Every
    /// caller here writes to or reads from a database column, so the
    /// fixed-locale formatter is the correct one regardless of the cache.
    static func fixedFormat(_ format: String, calendar: Calendar, locale: Locale = .posix) -> DateFormatter {
        let key = DateKey(
            template: format, calendarIdentifier: "\(calendar.identifier)",
            timeZoneIdentifier: calendar.timeZone.identifier, localeIdentifier: locale.identifier
        )
        lock.lock()
        defer { lock.unlock() }
        if let cached = fixedFormatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        fixedFormatters[key] = formatter
        return formatter
    }

    /// A cached `ISO8601DateFormatter`, keyed on its options.
    ///
    /// `ISO8601DateFormatter` is the most expensive of the three to build,
    /// and `PostgresDate.date(fromTimestamp:)` — which every transaction row
    /// in a day-grouped ledger goes through, on the main actor — used to
    /// construct one (sometimes two) per call.
    static func iso8601(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let cached = isoFormatters[options.rawValue] { return cached }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        isoFormatters[options.rawValue] = formatter
        return formatter
    }

    nonisolated(unsafe) private static var dateFormatters: [DateKey: DateFormatter] = [:]
    nonisolated(unsafe) private static var fixedFormatters: [DateKey: DateFormatter] = [:]
    nonisolated(unsafe) private static var isoFormatters: [UInt: ISO8601DateFormatter] = [:]

    private struct DateKey: Hashable {
        let template: String
        let calendarIdentifier: String
        let timeZoneIdentifier: String
        let localeIdentifier: String
    }

    private static func formatter(
        _ style: Style, code: String, minorUnit: Int, locale: Locale, configure: (NumberFormatter) -> Void
    ) -> NumberFormatter {
        let key = Key(style: style, code: code, minorUnit: minorUnit, localeIdentifier: locale.identifier)
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = NumberFormatter()
        formatter.locale = locale
        configure(formatter)
        formatters[key] = formatter
        return formatter
    }
}
