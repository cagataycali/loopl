import Testing
import LooplUI

/// Pipe tables, block quotes and rules in `MarkdownBody.blocks` (IMPROVE audit #11) — including the streaming
/// stability rule: a prefix must never re-flow an earlier block when the next token arrives.
struct MarkdownBlocksTests {
    typealias B = MarkdownBody.Block

    @Test func tableWithRuleRow() {
        let md = "| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 | 4 |"
        #expect(MarkdownBody.blocks(md) == [.table(header: ["a", "b"], rows: [["1", "2"], ["3", "4"]])])
    }

    @Test func raggedRowsArePaddedToTheHeader() {
        let md = "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |"
        #expect(MarkdownBody.blocks(md) == [.table(header: ["a", "b", "c"], rows: [["1", "", ""], ["1", "2", "3"]])])
    }

    @Test func tableEndsAtABlankLineOrProse() {
        let md = "| a |\n|---|\n| 1 |\n\nAfter.\n| not a table row without a header? |"
        let b = MarkdownBody.blocks(md)
        #expect(b[0] == .table(header: ["a"], rows: [["1"]]))
        #expect(b[1] == .paragraph("After."))
        #expect(b[2] == .table(header: ["not a table row without a header?"], rows: []), "a lone pipe line is a one-row header table, never a paragraph with pipes")
    }

    @Test func quoteAndRule() {
        let b = MarkdownBody.blocks("> one\n> two\n\n---\n\ntext")
        #expect(b == [.quote("one two"), .rule, .paragraph("text")])
    }

    @Test func aDashListIsNotARule() {
        #expect(MarkdownBody.blocks("- a\n- b") == [.bullet(["a", "b"])])
        #expect(MarkdownBody.blocks("--") == [.paragraph("--")])
        #expect(MarkdownBody.blocks("***") == [.rule])
    }

    @Test func streamingATableNeverReflowsTheHeader() {
        // Token by token: the header shows as a table from its first full line, the rule row never shows, rows append.
        let full = "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
        var prev: [B] = []
        for n in 1...full.count {
            let prefix = String(full.prefix(n))
            let now = MarkdownBody.blocks(prefix, streaming: true)
            // every block but the last of the previous prefix must still be there, unchanged
            if prev.count > 1 { #expect(Array(now.prefix(prev.count - 1)) == Array(prev.dropLast()), "re-flow at \(n): \(prefix.suffix(8))") }
            #expect(!now.contains { if case .table(let h, let rows) = $0 { return h.allSatisfy { $0.allSatisfy { $0 == "-" } } || rows.contains { $0.allSatisfy { $0.allSatisfy { $0 == "-" || $0 == ":" } && !$0.isEmpty } } }; return false }, "a rule row rendered as cells at \(n)")
            prev = now
        }
        #expect(prev == [.paragraph("Intro"), .table(header: ["a", "b"], rows: [["1", "2"], ["3", "4"]])])
    }

    @Test func pipeQuoteAndRuleStartsAreHeldBackWhileStreaming() {
        #expect(MarkdownBody.blocks("x\n|", streaming: true) == [.paragraph("x")])
        #expect(MarkdownBody.blocks("x\n>", streaming: true) == [.paragraph("x")])
        #expect(MarkdownBody.blocks("x\n--", streaming: true) == [.paragraph("x")])
        #expect(MarkdownBody.blocks("x\n|", streaming: false) == [.paragraph("x"), .table(header: [""], rows: [])], "final text is never trimmed")
    }
}
