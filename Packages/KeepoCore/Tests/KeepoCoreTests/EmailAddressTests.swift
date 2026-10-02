import Testing
@testable import KeepoCore

/// Sign-in's shape check. It errs permissive on purpose — refusing a real
/// address locks someone out — so the accepted cases matter as much as the
/// refused ones.
@Suite("EmailAddress")
struct EmailAddressTests {
    @Test("ordinary and unusual-but-real addresses pass", arguments: [
        "manu@example.com",
        "first.last@example.co.uk",
        "name+keepo@gmail.com",
        "o'brien@example.ie",
        "user@sub.domain.example",
        "  padded@example.com  "
    ])
    func plausibleAddressesPass(_ address: String) {
        #expect(EmailAddress.isPlausible(address))
    }

    @Test("typos the user can see and fix are refused", arguments: [
        "",
        "manu",
        "manu@",
        "@example.com",
        "manu@example",
        "manu@example.",
        "manu@.com",
        "manu@example..com",
        "manu@@example.com",
        "ma nu@example.com",
        "manu@example.c",
        "manu@example.c0m"
    ])
    func implausibleAddressesAreRefused(_ address: String) {
        #expect(!EmailAddress.isPlausible(address))
    }
}
