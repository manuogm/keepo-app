import KeepoCore
import Testing

@Suite("Tag suggestions")
struct TagSuggestionsTests {
    private func use(_ name: String, close: Int, broad: Int) -> TagSuggestions.Usage {
        TagSuggestions.Usage(tagId: name, name: name, close: close, broad: broad)
    }

    @Test("never more than three")
    func capsAtThree() {
        let usage = ["A", "B", "C", "D", "E"].map { use($0, close: 0, broad: 1) }
        #expect(TagSuggestions.rank(usage).count == 3)
    }

    @Test("the selected account decides first, however busy a tag is elsewhere")
    func accountFirst() {
        let usage = [use("Busy", close: 0, broad: 10), use("Here", close: 2, broad: 2)]
        #expect(TagSuggestions.rank(usage) == ["Here", "Busy"])
    }

    @Test("then the number of transactions")
    func thenCount() {
        let usage = [use("Rare", close: 1, broad: 1), use("Common", close: 1, broad: 6), use("Mid", close: 1, broad: 3)]
        #expect(TagSuggestions.rank(usage) == ["Common", "Mid", "Rare"])
    }

    @Test("a tie reads in name order, so the row never reshuffles")
    func nameBreaksTies() {
        let usage = [use("beta", close: 1, broad: 1), use("Alpha", close: 1, broad: 1)]
        #expect(TagSuggestions.rank(usage) == ["Alpha", "beta"])
    }

    @Test("a tag never used on anything alike is not suggested")
    func unusedIsDropped() {
        #expect(TagSuggestions.rank([use("Never", close: 0, broad: 0)]).isEmpty)
    }
}
