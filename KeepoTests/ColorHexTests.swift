import KeepoCore
import SwiftUI
import Testing
@testable import Keepo

/// A stored colour must survive being read and saved again untouched.
/// `hexString` used to truncate, so `#34C759` came back as `#33C758` — 16 of
/// the 24 palette colours drifted a step on every save of an untouched
/// account or category.
@Suite("Color hex round trip")
struct ColorHexTests {
    @Test("every palette colour round-trips exactly", arguments: CategoryAppearance.palette)
    func paletteRoundTrips(hex: String) {
        #expect(Color(hex: hex).hexString == hex)
    }

    @Test("a grey from the system picker's grayscale space still resolves")
    func grayscaleResolves() {
        #expect(Color(uiColor: UIColor(white: 1, alpha: 1)).hexString == "#FFFFFF")
        #expect(Color(uiColor: UIColor(white: 0, alpha: 1)).hexString == "#000000")
    }
}
