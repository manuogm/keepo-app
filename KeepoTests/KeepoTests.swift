import Testing
@testable import Keepo

@Suite("Keepo app target smoke test")
struct KeepoTests {
    @Test("target compiles and links")
    func targetLinks() {
        #expect(true)
    }
}
