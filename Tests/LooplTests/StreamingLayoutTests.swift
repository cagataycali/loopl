import Testing
import LooplUI
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Guards for "the chat UI jumps while the agent streams" (owner, 2026-10-06).
/// Two layout facts measured on the iPhone 16 Pro simulator:
///  • the follow un-pinned itself at the first overflowing token because the at-bottom test ignored the
///    116 pt navigation inset (offset rests at -116, so `offset + container >= content` fails at the fold);
///  • a half-open code fence kept its trailing empty line (card shrank 21 pt when ``` arrived) and a bare
///    list marker was a paragraph until its first word (4 pt re-flow) — both moved the whole document.
@Suite struct StreamingLayoutTests {
    // iPhone 16 Pro, chat tab: container 617, nav inset 116, no bottom inset (composer is outside the scroll view).
    private func atBottom(offset: CGFloat, content: CGFloat) -> Bool {
        LooplDesign.isAtBottom(offset: offset, content: content, container: 617, insetTop: 116, insetBottom: 0)
    }

    @Test func documentShorterThanTheBandIsAtBottom() {
        #expect(atBottom(offset: -116, content: 300))
        #expect(atBottom(offset: -116, content: 501))   // exactly fills the band
    }

    @Test func restingAtTheTopWhileTheDocumentOverflowsIsNotAtBottomBeyondTheSlack() {
        #expect(atBottom(offset: -116, content: 560))       // 59 pt hidden < slack
        #expect(!atBottom(offset: -116, content: 601))      // 100 pt hidden: the reader is up
    }

    @Test func pinnedToTheBottomIsAtBottomRegardlessOfInset() {
        // Scrolled fully down: offset = content - container + insetBottom (0 here).
        #expect(atBottom(offset: 1394 - 617, content: 1394))
        // With a 300 pt keyboard inset the same rule holds.
        #expect(LooplDesign.isAtBottom(offset: 1394 - 617 + 300, content: 1394, container: 617, insetTop: 116, insetBottom: 300))
        #expect(!LooplDesign.isAtBottom(offset: -116, content: 1394, container: 617, insetTop: 116, insetBottom: 300))
    }

    @Test func geometryAloneCannotTellGrowthFromScrolling() {
        // Both the old and the new predicate go false when the document grows past the fold with the reader
        // still at the top — which is why the follow is un-pinned only by the reader's scroll PHASE, never by
        // geometry (the pre-fix view set `pinned = false` here and stopped following at the first overflowing token).
        let legacy = { (offset: CGFloat, content: CGFloat) in content <= 618 || offset + 617 >= content - 80 }
        #expect(!legacy(-116, 622) && !atBottom(offset: -116, content: 622))
    }

    @Test func halfOpenFenceDoesNotKeepTheTrailingNewline() {
        let open = "Code:\n```swift\nlet a = 1\n"
        let closed = open + "```\n"
        #expect(MarkdownBody.blocks(open) == MarkdownBody.blocks(closed))
        #expect(MarkdownBody.blocks(open).last == .code("let a = 1", lang: "swift"))
    }

    @Test func bareListMarkerIsAlreadyAListItem() {
        #expect(MarkdownBody.blocks("Points:\n- ").last == .bullet([""]))
        #expect(MarkdownBody.blocks("Points:\n-").last == .bullet([""]))
        #expect(MarkdownBody.blocks("Points:\n- When").last == .bullet(["When"]))
        #expect(MarkdownBody.blocks("Steps:\n1. ").last == .numbered([""]))
        #expect(MarkdownBody.blocks("Steps:\n1. Ask").last == .numbered(["Ask"]))
    }

    @Test func markerPrefixesAreHeldBackWhileStreamingOnly() {
        #expect(MarkdownBody.blocks("Intro.\n\n1", streaming: true) == [.paragraph("Intro.")])
        #expect(MarkdownBody.blocks("Intro.\n\n12.", streaming: true) == [.paragraph("Intro.")])
        #expect(MarkdownBody.blocks("Intro.\n\n``", streaming: true) == [.paragraph("Intro.")])
        #expect(MarkdownBody.blocks("Intro.\n\n```", streaming: true) == [.paragraph("Intro."), .code("", lang: "")])
        // Final text keeps every character.
        #expect(MarkdownBody.blocks("Intro.\n\n1") == [.paragraph("Intro."), .paragraph("1")])
        #expect(MarkdownBody.blocks("Score: 1") == [.paragraph("Score: 1")])
    }

    @Test func aBareNumberWithAPeriodIsProseNotAListItem() {
        // Seen in History (IMPROVE #10 capture): the final answer "42." rendered as an empty "1." list row.
        #expect(MarkdownBody.blocks("42.") == [.paragraph("42.")])
        #expect(MarkdownBody.blocks("The answer is\n1081.") == [.paragraph("The answer is 1081.")])
        #expect(MarkdownBody.blocks("1. ") == [.numbered([""])], "marker + space while the first word is still coming")
        #expect(MarkdownBody.blocks("1. one\n2. two") == [.numbered(["one", "two"])])
        #expect(MarkdownBody.blocks("42.", streaming: true) == [], "held back one token while streaming (marker prefix)")
    }

    @Test func streamingPrefixesNeverReflowAnEarlierBlock() {
        // Every character-boundary prefix of a streamed answer: when one more character lands, every block but
        // the one being written must keep its kind (no paragraph turning into a list or a code card later).
        let answer = "Intro.\n\n1. **Ask** — read.\n2. **Act** — run.\n\n```swift\nlet x = 1\n```\n\n- one\n- two\n\nDone."
        func kinds(_ s: String) -> [String] {
            MarkdownBody.blocks(s, streaming: true).map {
                switch $0 { case .paragraph: "p"; case .heading: "h"; case .bullet: "ul"; case .numbered: "ol"; case .code: "code"; case .table: "table"; case .quote: "q"; case .rule: "hr" }
            }
        }
        var prev: [String] = []
        for end in answer.indices {
            let k = kinds(String(answer[...end]))
            #expect(k.count >= prev.count, "a block vanished at \(answer[...end].suffix(10).debugDescription): \(prev) → \(k)")
            if k.count == prev.count { #expect(Array(k.dropLast()) == Array(prev.dropLast()), "re-flow at \(answer[...end].suffix(10).debugDescription): \(prev) → \(k)") }
            else { #expect(Array(k.dropLast()) == prev || Array(k.dropLast()) == Array(prev.dropLast()), "re-flow at \(answer[...end].suffix(10).debugDescription): \(prev) → \(k)") }
            prev = k
        }
    }
}
