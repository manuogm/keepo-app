import SwiftUI

/// `Color` has no built-in hex round-trip — categories and accounts store
/// color as a plain "#RRGGBB" string (the DB has no reason to know about
/// `Color` at all), so this is the one place that conversion happens.
extension Color {
    init(hex: String) {
        self = HexColorCache.color(for: hex)
    }

    /// `nil` when the color can't be resolved to sRGB components at all
    /// (e.g. a dynamic system color never round-tripped through `init(
    /// hex:)`) — callers fall back to `CategoryAppearance.randomColor()`
    /// rather than persist a wrong value.
    ///
    /// **Converted, then rounded.** It read the raw components and
    /// truncated them, which was wrong twice. Truncating: the components
    /// come back from `init(hex:)` a hair under the byte they encode, so
    /// `#34C759` read back as `#33C758` — 16 of the 24 palette colours
    /// moved a step on every save of an untouched account or category, and
    /// the catalogue could never find the selected swatch among its own (it
    /// grew a second, near-identical one instead). Raw
    /// components: the system colour picker hands back greys in a
    /// two-component grayscale space, which read as "no colour", and
    /// vivid picks in extended sRGB, whose components run outside 0…1.
    var hexString: String? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = UIColor(self).cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3
        else { return nil }
        let channels = components.prefix(3).map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
}

/// A colour's hue/saturation/brightness, as a named type rather than a
/// tuple — three unlabelled `Double`s at a call site is exactly the shape
/// that silently swaps two of them.
struct HSBComponents {
    var hue: Double
    var saturation: Double
    var brightness: Double
}

extension Color {
    /// The colour's HSB components, or `nil` for a dynamic system colour that
    /// has no fixed value to read. Only ever called on colours that came from
    /// a stored hex string, so the `nil` path is a safety net rather than a
    /// case any screen actually hits.
    var hsbComponents: HSBComponents? {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return nil
        }
        return HSBComponents(
            hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness)
        )
    }

    /// A shade of the same colour — used to build a card face out of an
    /// account's own colour without any card needing a colour of its own.
    /// Every argument is a delta, so the identity call returns `self`.
    func shifted(hue: Double = 0, saturation: Double = 0, brightness: Double = 0) -> Color {
        guard let components = hsbComponents else { return self }
        return Color(
            hue: (components.hue + hue).truncatingRemainder(dividingBy: 1).magnitude,
            saturation: min(max(components.saturation + saturation, 0), 1),
            brightness: min(max(components.brightness + brightness, 0), 1)
        )
    }
}

/// Every account and category row parses its color string on every render
/// pass, and SwiftUI re-evaluates those bodies far more often than the data
/// changes. The parse is cheap individually but allocates a `Scanner` each
/// time; across a scrolling list it is pure waste for a value that, by
/// definition, only has as many distinct results as there are stored colors.
///
/// Same `NSLock` + `nonisolated(unsafe)` shape as `LocalStore`'s own cache —
/// the values are immutable once built, so concurrent reads are safe.
private enum HexColorCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Color] = [:]

    static func color(for hex: String) -> Color {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[hex] { return cached }
        let color = parse(hex)
        cache[hex] = color
        return color
    }

    private static func parse(_ hex: String) -> Color {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString.removeAll { $0 == "#" }
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        let red = Double((value & 0xFF0000) >> 16) / 255
        let green = Double((value & 0x00FF00) >> 8) / 255
        let blue = Double(value & 0x0000FF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}
