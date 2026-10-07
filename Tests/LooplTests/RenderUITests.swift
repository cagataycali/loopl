import XCTest
@testable import Loopl

/// Phase 7 — `render_ui` spec parsing: lenient for small models, honest about what it fixed, never silent on unknown types.
final class RenderUITests: XCTestCase {
    private func spec(_ json: String) throws -> RenderSpec {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return try RenderSpec(args: v.objectValue ?? [:])
    }

    func testChartFromSeriesWithStringNumbers() throws {
        let s = try spec(#"{"title":"Steps","components":[{"type":"chart","kind":"bar","series":[{"name":"steps","points":[{"label":"Mon","value":"4k"},{"label":"Tue","value":6200},{"label":"Wed","value":"7,100"}]}]}]}"#)
        XCTAssertEqual(s.title, "Steps")
        guard case .chart(_, let kind, let series) = s.components[0] else { return XCTFail("not a chart") }
        XCTAssertEqual(kind, .bar)
        XCTAssertEqual(series[0].points.map(\.value), [4000, 6200, 7100])
        XCTAssertTrue(s.issues.isEmpty, "\(s.issues)")
        XCTAssertTrue(s.resultText.hasPrefix("rendered 1 component (chart)."))
    }

    func testChartShortcutsPointsAndDictionary() throws {
        let a = try spec(#"{"components":[{"type":"chart","kind":"line","points":[{"label":"a","value":1},{"label":"b","value":2}]}]}"#)
        guard case .chart(_, .line, let s1) = a.components[0] else { return XCTFail() }
        XCTAssertEqual(s1.count, 1); XCTAssertEqual(s1[0].points.count, 2)
        let b = try spec(#"{"components":[{"type":"chart","kind":"pie","data":{"Rent":1200,"Food":480,"Fun":"n/a"}}]}"#)
        guard case .chart(_, .pie, let s2) = b.components[0] else { return XCTFail() }
        XCTAssertEqual(s2[0].points.map(\.label), ["Food", "Rent"])
        XCTAssertEqual(b.issues.count, 1)
        XCTAssertTrue(b.issues[0].contains("1 point had no numeric"))
    }

    func testMapPinsAndRouteRejectOutOfRange() throws {
        let s = try spec(#"{"components":[{"type":"map","title":"Cafés","pins":[{"lat":40.7447,"lon":-74.0323,"label":"bwè kafe"},{"lat":40.74,"lng":-74.03},{"lat":200,"lon":0}],"route":[[40.74,-74.03],[40.745,-74.032]]}]}"#)
        guard case .map(let t, let pins, let route) = s.components[0] else { return XCTFail() }
        XCTAssertEqual(t, "Cafés"); XCTAssertEqual(pins.count, 2); XCTAssertEqual(pins[0].label, "bwè kafe"); XCTAssertEqual(route.count, 2)
        XCTAssertEqual(s.issues.count, 1)
    }

    func testDiagramAddsNodesNamedOnlyByEdgesAndParsesArrowStrings() throws {
        let s = try spec(#"{"components":[{"type":"diagram","nodes":[{"id":"open","label":"Open app"}],"edges":[{"from":"open","to":"login"},"login -> home",["home","done","ok"]]}]}"#)
        guard case .diagram(_, let nodes, let edges) = s.components[0] else { return XCTFail() }
        XCTAssertEqual(nodes.map(\.id), ["open", "login", "home", "done"])
        XCTAssertEqual(nodes[0].label, "Open app"); XCTAssertEqual(nodes[1].label, "login")
        XCTAssertEqual(edges.count, 3); XCTAssertEqual(edges[2].label, "ok")
    }

    func testTablePadsRaggedRowsAndReadsObjectRows() throws {
        let s = try spec(#"{"components":[{"type":"table","headers":["Name","Size"],"rows":[["loopl-2b","1.3 GB"],["loopl-4b"]]},{"type":"table","rows":[{"a":1,"b":"x"},{"a":2}]}]}"#)
        guard case .table(_, let h, let rows) = s.components[0] else { return XCTFail() }
        XCTAssertEqual(h, ["Name", "Size"]); XCTAssertEqual(rows[1], ["loopl-4b", ""])
        guard case .table(_, let h2, let rows2) = s.components[1] else { return XCTFail() }
        XCTAssertEqual(h2, ["a", "b"]); XCTAssertEqual(rows2, [["1", "x"], ["2", ""]])
    }

    func testKeyValueListProgressTextRuleImage() throws {
        let s = try spec(#"{"components":[{"type":"keyvalue","title":"Ring","data":{"Battery":"82%","Steps":7421}},{"type":"list","items":["one",{"title":"two","subtitle":"second"}]},{"type":"progress","description":"Download","total":100,"completed":40},{"type":"text","content":"hi","style":"bold"},{"type":"rule","title":"later"},{"type":"image","attachment":0,"caption":"the photo"},{"type":"markdown","content":"**ok**"}]}"#)
        XCTAssertEqual(s.components.count, 7)
        guard case .keyvalue(_, let kv) = s.components[0] else { return XCTFail() }
        XCTAssertEqual(kv.map(\.key), ["Battery", "Steps"]); XCTAssertEqual(kv[1].value, "7421")
        guard case .list(_, let items) = s.components[1] else { return XCTFail() }
        XCTAssertEqual(items[1].subtitle, "second")
        guard case .progress(let d, 100, 40) = s.components[2] else { return XCTFail() }
        XCTAssertEqual(d, "Download")
        guard case .text("hi", .strong) = s.components[3] else { return XCTFail() }
        guard case .rule("later") = s.components[4] else { return XCTFail() }
        guard case .image(nil, 0, "the photo") = s.components[5] else { return XCTFail() }
        XCTAssertTrue(s.issues.isEmpty, "\(s.issues)")
    }

    func testUnknownTypeIsNamedNotSilent() throws {
        let s = try spec(#"{"components":[{"type":"gauge","value":3}]}"#)
        guard case .unknown(let t) = s.components[0] else { return XCTFail() }
        XCTAssertEqual(t, "gauge")
        XCTAssertTrue(s.resultText.contains("unknown(gauge)"))
        XCTAssertTrue(s.issues[0].contains("known: markdown, keyvalue"))
    }

    func testMissingComponentsThrowsWithTheTypeList() {
        XCTAssertThrowsError(try spec(#"{"title":"x"}"#)) { e in
            XCTAssertTrue("\(e)".contains("components"), "\(e)")
        }
    }

    func testSingleComponentAtTopLevelIsAccepted() throws {
        let s = try spec(#"{"type":"keyvalue","data":{"a":"b"}}"#)
        XCTAssertEqual(s.components.count, 1)
    }

    func testCapsAreReported() throws {
        let rows = (0..<60).map { _ in "[\"x\"]" }.joined(separator: ",")
        let s = try spec("{\"components\":[{\"type\":\"table\",\"headers\":[\"h\"],\"rows\":[\(rows)]}]}")
        guard case .table(_, _, let r) = s.components[0] else { return XCTFail() }
        XCTAssertEqual(r.count, RenderSpec.maxRows)
        XCTAssertTrue(s.issues[0].contains("first 50 of 60 rows"))
    }

    func testToolReturnsAttachmentAsImage() async throws {
        let tool = RenderUITool()
        let img = ImageBlock(data: Data([0x89, 0x50]), mime: "image/png")
        let out = try await tool.call(["components": .array([.object(["type": "image", "attachment": 0]), .object(["type": "image", "attachment": 3])])], images: [img])
        XCTAssertEqual(out.images, [img])
        XCTAssertTrue(out.text.contains("attachment 3 does not exist"))
    }
}

extension RenderUITests {
    /// MEASURED on loopl-2b (2026-10-07): `components` arrives as a JSON string 4/9 runs, twice in the `["diagram", "nodes": …]` shape.
    func testComponentsAsJSONStringIsDecodedAndReported() throws {
        let args: [String: JSONValue] = ["components": .string(#"[{"type": "map", "pins": [{"lat": 40.7447, "lon": -74.0323, "label": "bwè kafe"}]}]"#)]
        let s = try RenderSpec(args: args)
        guard case .map(_, let pins, _) = s.components[0] else { return XCTFail("\(s.components)") }
        XCTAssertEqual(pins[0].label, "bwè kafe")
        XCTAssertEqual(s.issues, ["`components` was sent as a JSON string — send a plain array next time"])
    }

    func testCollapsedTypeShapeWithTrailingCommasIsRepaired() throws {
        let text = """
        [
          "diagram",
          "nodes": [
            {"id": "start", "label": "1. Open App"},
            {"id": "home", "label": "4. Home Screen"},
          ],
          "edges": [
            {"from": "start", "to": "home"},
          ]
        ]
        """
        let s = try RenderSpec(args: ["components": .string(text)])
        guard case .diagram(_, let nodes, let edges) = s.components[0] else { return XCTFail("\(s.components)") }
        XCTAssertEqual(nodes.map(\.id), ["start", "home"]); XCTAssertEqual(edges.count, 1)
    }

    func testUnparseableStringIsAnHonestIssue() {
        XCTAssertThrowsError(try RenderSpec(args: ["components": .string("not json at all")]))
    }
}

extension RenderUITests {
    /// ToolValidation wraps a non-array into `[value]` before the tool runs — the double-encoded string shows up as a one-element array.
    func testStringElementInsideTheArrayIsUnwrapped() throws {
        let s = try RenderSpec(args: ["components": .array([.string(#"[{"type":"map","pins":[{"lat":1,"lon":2,"label":"a"}]},{"type":"rule"}]"#)])])
        XCTAssertEqual(s.components.map(\.kindName), ["map", "rule"])
        XCTAssertEqual(s.issues.count, 1)
    }
}

extension RenderUITests {
    /// loopl-2b v3 raw calls: an extra `}` at the end, a key missing its closing quote, and `edges` beside three edge-less diagrams.
    func testExtraCloserAndDroppedQuoteAreRepaired() throws {
        let a = try RenderSpec(args: ["components": .string(#"[{"type": "diagram", "nodes": [{"id": "a"}, {"id": "b"}], "edges": [{"from": "a", "to": "b"}]}]}"#)])
        guard case .diagram(_, let n, let e) = a.components[0] else { return XCTFail("\(a.components)") }
        XCTAssertEqual(n.count, 2); XCTAssertEqual(e.count, 1)
        let b = try RenderSpec(args: ["components": .string(#"[{"type": "chart", "kind": "line", "series": [{"name": "steps", "points: [{"label": "Mon", "value": 4000}]}]}]"#)])
        guard case .chart(_, .line, let s) = b.components[0] else { return XCTFail("\(b.components)") }
        XCTAssertEqual(s[0].points.count, 1)
        XCTAssertEqual(RenderSpec.balanced(#"[{"a": [1, 2"#), #"[{"a": [1, 2]}]"#)
        XCTAssertEqual(RenderSpec.balanced(#"[{"a": 1, "b":"#), #"[{"a": 1}]"#)
    }

    func testStrayEdgesMergeSplitDiagrams() throws {
        let args: [String: JSONValue] = [
            "components": .array([.object(["type": "diagram", "nodes": .array([.object(["id": "open"]), .object(["id": "form"])])]),
                                  .object(["type": "diagram", "nodes": .array([.object(["id": "wrong"])])])]),
            "edges": .string(#"[{"from": "open", "to": "form"}, {"from": "form", "to": "wrong"}]"#)]
        let s = try RenderSpec(args: args)
        XCTAssertEqual(s.components.count, 1)
        guard case .diagram(_, let n, let e) = s.components[0] else { return XCTFail("\(s.components)") }
        XCTAssertEqual(n.map(\.id), ["open", "form", "wrong"]); XCTAssertEqual(e.count, 2)
        XCTAssertEqual(s.issues.count, 2)
    }
}
