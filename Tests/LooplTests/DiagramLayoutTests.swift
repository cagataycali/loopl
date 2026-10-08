import XCTest
import Loopl
@testable import LooplUI

/// the diagram's pure layout: a back edge (retry → form) must not push the form below the step it loops from.
final class DiagramLayoutTests: XCTestCase {
    private func n(_ id: String) -> RenderComponent.Node { .init(id: id) }
    private func e(_ a: String, _ b: String) -> RenderComponent.Edge { .init(from: a, to: b) }

    func testLoginFlowWithRetryLoopKeepsTheFormAboveVerify() {
        let nodes = ["open", "creds", "verify", "mfa", "home", "error"].map(n)
        let edges = [e("open", "creds"), e("creds", "verify"), e("verify", "mfa"), e("verify", "error"), e("mfa", "home"), e("error", "creds")]
        let l = DiagramLayout(nodes: nodes, edges: edges)
        XCTAssertEqual(l.layers, [["open"], ["creds"], ["verify"], ["mfa", "error"], ["home"]])
        XCTAssertEqual(l.backEdges, [5])
    }

    func testLinearChainIsOneNodePerLayerAndIsolatedNodesSitOnTop() {
        let l = DiagramLayout(nodes: ["a", "b", "c", "x"].map(n), edges: [e("a", "b"), e("b", "c")])
        XCTAssertEqual(l.layers, [["a", "x"], ["b"], ["c"]])
        XCTAssertTrue(l.backEdges.isEmpty)
    }

    func testTwoNodeCycleAndSelfLoopDoNotRecurseForever() {
        let l = DiagramLayout(nodes: ["a", "b"].map(n), edges: [e("a", "b"), e("b", "a"), e("a", "a")])
        XCTAssertEqual(l.layers, [["a"], ["b"]])
        XCTAssertEqual(l.backEdges, [1])
    }

    func testSpokenSummaries() {
        let chart = RenderA11y.chart(title: "Steps", kind: .bar, series: [.init(points: [.init(label: "Mon", value: 4000), .init(label: "Tue", value: 6200.5)])])
        XCTAssertEqual(chart, "bar chart Steps: Mon 4000, Tue 6200.50")
        let d = RenderA11y.diagram(title: nil, nodes: [.init(id: "a", label: "Open"), .init(id: "b", label: "Home")], edges: [.init(from: "a", to: "b", label: "ok")])
        XCTAssertEqual(d, "diagram with 2 steps: Open to Home (ok)")
        XCTAssertEqual(RenderA11y.map(pins: [.init(lat: 1, lon: 2, label: "café")], route: [.init(lat: 1, lon: 2), .init(lat: 1, lon: 3)]), "map with 1 pin: café; with a route of 2 points")
    }
}
