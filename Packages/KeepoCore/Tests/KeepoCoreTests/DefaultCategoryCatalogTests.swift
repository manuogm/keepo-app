import Foundation
import Testing
@testable import KeepoCore

/// The colour is the only part of a tile the eye uses when a twenty-three
/// item grid is scanned rather than read, so two categories wearing the
/// same one are read as the same thing twice. This used to be broken in
/// seven places — Transport and Education both `#007AFF`, Housing, Pets and
/// Rental all `#A2845E`, and most of the income list borrowing an expense
/// colour outright.
@Suite("No two default categories share a colour")
struct DefaultCategoryColourTests {
    @Test("every catalogue colour is unique")
    func coloursAreDistinct() {
        let colours = DefaultCategoryCatalog.all.map(\.color)
        #expect(Set(colours).count == colours.count)
    }

    @Test("every colour is a full six-digit hex")
    func coloursAreWellFormed() {
        for category in DefaultCategoryCatalog.all {
            #expect(category.color.count == 7, "\(category.name) has a malformed colour")
            #expect(category.color.hasPrefix("#"), "\(category.name) has a malformed colour")
        }
    }

    /// Adding a case to `DefaultCategoryKey` without adding its row leaves a
    /// key that persists into a draft and then resolves to nothing.
    @Test("every key has a catalogue entry")
    func everyKeyIsRepresented() {
        for key in DefaultCategoryKey.allCases {
            #expect(DefaultCategoryCatalog.category(for: key) != nil, "\(key) has no catalogue row")
        }
    }
}
