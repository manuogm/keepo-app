import SwiftUI

/// `Color` has no built-in hex round-trip — categories store color as a
/// plain "#RRGGBB" string (the DB has no reason to know about `Color` at
/// all), so this is the one place that conversion happens.
extension Color {
    init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString.removeAll { $0 == "#" }
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        let red = Double((value & 0xFF0000) >> 16) / 255
        let green = Double((value & 0x00FF00) >> 8) / 255
        let blue = Double(value & 0x0000FF) / 255
        self = Color(red: red, green: green, blue: blue)
    }

    /// `nil` when the color can't be resolved to sRGB components at all
    /// (e.g. a dynamic system color never round-tripped through `init(
    /// hex:)`) — callers fall back to `CategoryAppearance.randomColor()`
    /// rather than persist a wrong value.
    var hexString: String? {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return nil }
        let red = Int(components[0] * 255)
        let green = Int(components[1] * 255)
        let blue = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
