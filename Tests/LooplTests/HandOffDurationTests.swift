import XCTest
@testable import Loopl

/// a tool row may only print a duration that measures the WORK. `use_agent` hands back an envelope
/// the instant the child starts, so the row read "Helper · 4 ms" directly above a sub-agent card that was 42 s into
/// a background run — the 4 ms is the hand-off, and a person reads it as the helper's own time.
final class HandOffDurationTests: XCTestCase {
    private static let info = SubAgentInfo(id: "agent_1a2b", parentToolUseId: "tooluse_1", name: "issues",
                                           systemPrompt: "summarise issues", input: "go", tools: ["http"],
                                           background: true, startedAt: Date())

    private func result(_ content: String) -> ToolResult {
        ToolResult(toolUseId: "tooluse_1", name: "use_agent", status: .success, content: content, durationMs: 4)
    }

    /// A detached child: the envelope says it is still going, so the row keeps quiet.
    func testPendingEnvelopeHidesTheDuration() {
        let env = SubAgentEnvelope(info: Self.info, status: .background)
        XCTAssertTrue(result(env.json.compact).reportsPending, env.json.compact)
    }

    /// The same tool, waited for: that duration IS the work and must stay on the row.
    func testFinishedEnvelopeKeepsTheDuration() {
        let env = SubAgentEnvelope(info: Self.info, status: .done, result: "three bullets", endedAt: Date())
        XCTAssertFalse(env.json.compact.contains("\"pending\""), env.json.compact)
        XCTAssertFalse(result(env.json.compact).reportsPending)
    }

    /// Every ordinary tool is unaffected — including one whose text merely mentions the word.
    func testOrdinaryResultsAreUntouched() {
        XCTAssertFalse(result("23*47 = 1081").reportsPending)
        XCTAssertFalse(result("the invoice is pending approval").reportsPending)
        XCTAssertFalse(result("{\"pending\": false}").reportsPending)
        XCTAssertFalse(result("{not json at all \"pending\"").reportsPending, "a broken body may not change the row")
    }
}
