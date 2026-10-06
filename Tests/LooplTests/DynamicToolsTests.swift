import XCTest
@testable import Loopl

/// Agent-written tools (Phase 6 lane D): JavaScript in JavaScriptCore everywhere, Swift compiled + dlopen'd on macOS,
/// both persisted and reloaded by `DynamicToolStore`, both driven through `manage_tools create/remove/list`.
final class DynamicToolsTests: XCTestCase {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dyntools-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    static let reverseJS = """
    var tool = {
      name: "reverse_string",
      description: "Reverses the given text.",
      inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
      call(args) { if (typeof args.text !== "string") throw new Error("text is required"); return args.text.split("").reverse().join(""); }
    };
    """

    // MARK: JavaScript

    func testJSToolRunsAndReportsErrorsVerbatim() async throws {
        let t = try JSTool(source: Self.reverseJS)
        XCTAssertEqual(t.name, "reverse_string")
        XCTAssertEqual(t.parameters["required"]?.arrayValue?.first?.stringValue, "text")
        let out1 = try await t.call(["text": "loopl"]); XCTAssertEqual(out1, "lpool")
        do { _ = try await t.call([:]); XCTFail("should throw") }
        catch { XCTAssertTrue("\(error)".contains("text is required"), "\(error)") }
    }

    func testJSShapeErrorsNameTheProblem() {
        XCTAssertThrowsError(try JSTool(source: "var x = 1;")) { XCTAssertTrue("\($0)".contains("global `tool` object"), "\($0)") }
        XCTAssertThrowsError(try JSTool(source: "var tool = { name: 'bad name!', description: 'x', call() {} };")) { XCTAssertTrue("\($0)".contains("tool.name"), "\($0)") }
        XCTAssertThrowsError(try JSTool(source: "var tool = { name: 'ok', description: 'x' };")) { XCTAssertTrue("\($0)".contains("call(args)"), "\($0)") }
        XCTAssertThrowsError(try JSTool(source: "var tool = { name: 'ok', description: 'x', call() {} ")) { XCTAssertTrue("\($0).lowercased()".contains("syntaxerror") || "\($0)".contains("Unexpected"), "\($0)") }
    }

    func testJSPromiseConsoleAndBridge() async throws {
        let src = """
        var tool = { name: "adder", description: "adds via the calculator tool",
          async call(args) { console.log("asking"); const r = loopl.call("calculator", { expression: args.a + "+" + args.b }); return "sum=" + r; } };
        """
        let bridge = JSToolBridge(call: { name, args in
            XCTAssertEqual(name, "calculator"); return args["expression"]?.stringValue == "2+3" ? "5" : "?"
        })
        let t = try JSTool(source: src, bridge: bridge)
        let out = try await t.call(["a": "2", "b": "3"], bridge: bridge)
        XCTAssertTrue(out.hasPrefix("sum=5"), out)
        XCTAssertTrue(out.contains("[log] asking"), out)
    }

    func testJSNoEvalAndTimeout() async throws {
        let ev = try JSTool(source: "var tool = { name: 'e', description: 'x', call() { return typeof eval; } };")
        let evOut = try await ev.call([:]); XCTAssertEqual(evOut, "undefined")
        let spin = try JSTool(source: "var tool = { name: 'spin', description: 'x', call() { while (true) {} } };", timeout: 0.5)
        do { _ = try await spin.call([:]); XCTFail("should time out") }
        catch { XCTAssertTrue("\(error)".contains("timed out"), "\(error)") }
    }

    func testLanguageInference() {
        XCTAssertEqual(DynamicToolLanguage.infer(from: Self.reverseJS), .javascript)
        XCTAssertEqual(DynamicToolLanguage.infer(from: DynamicToolShape.swift), .swift)
        XCTAssertNil(DynamicToolLanguage.infer(from: "hello"))
    }

    // MARK: Store + manage_tools

    func testStoreCreatesPersistsReloadsRemoves() async throws {
        let dir = tempDir()
        let store = DynamicToolStore(directory: dir)
        await store.setReserved(["calculator", "manage_tools"])
        let r = try await store.create(name: nil, source: Self.reverseJS, language: nil)
        XCTAssertTrue(r.live); XCTAssertEqual(r.record.name, "reverse_string")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("reverse_string.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("reverse_string.json").path))
        let names1 = await store.tools.map(\.name); XCTAssertEqual(names1, ["reverse_string"])

        // Reserved / duplicate / mismatched names are refused with a reason.
        await assertRejected(try await store.create(name: nil, source: Self.reverseJS.replacingOccurrences(of: "reverse_string", with: "calculator"), language: nil), contains: "built-in")
        await assertRejected(try await store.create(name: nil, source: Self.reverseJS, language: nil), contains: "already exists")
        await assertRejected(try await store.create(name: "other", source: Self.reverseJS, language: nil), contains: "must match")

        // A new store over the same folder brings it back.
        let again = DynamicToolStore(directory: dir)
        let records = await again.reload()
        XCTAssertEqual(records.map(\.name), ["reverse_string"]); XCTAssertEqual(records.first?.status, .active)
        let back = try await again.tools.first?.call(["text": "ab"]); XCTAssertEqual(back, "ba")
        let src = await again.source(of: "reverse_string"); XCTAssertEqual(src, Self.reverseJS.trimmingCharacters(in: .whitespacesAndNewlines))

        // Remove deletes files; a reload finds nothing.
        _ = try await again.remove(name: "reverse_string") as String
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("reverse_string.js").path))
        let left = await again.reload(); XCTAssertEqual(left.count, 0)
    }

    func testReloadKeepsBrokenFileAsFailedAndLoadsTheRest() async throws {
        let dir = tempDir()
        try Self.reverseJS.write(to: dir.appendingPathComponent("reverse_string.js"), atomically: true, encoding: .utf8)
        try "var tool = {".write(to: dir.appendingPathComponent("broken.js"), atomically: true, encoding: .utf8)
        let store = DynamicToolStore(directory: dir)
        let records = await store.reload()
        XCTAssertEqual(Set(records.map(\.name)), ["reverse_string", "broken"])
        let names2 = await store.tools.map(\.name); XCTAssertEqual(names2, ["reverse_string"])
        guard case .failed(let why)? = records.first(where: { $0.name == "broken" })?.status else { return XCTFail("broken should be .failed") }
        XCTAssertFalse(why.isEmpty)
    }

    func testManageToolsTextContract() async throws {
        let store = DynamicToolStore(directory: tempDir())
        let tool = ManageToolsFallbackTool(store: store)
        let expectedWord = DynamicToolLanguage.preferredHere == .swift ? "write Swift" : "write JavaScript"   // the DEVICE decides (iOS sim → JavaScript)
        XCTAssertTrue(tool.description.contains(expectedWord) && tool.description.contains(DynamicToolShape.text(for: .preferredHere).prefix(30)), "description should explain the tool: \(tool.description)")
        let l0 = try await tool.call(["action": "list"]); XCTAssertTrue(l0.contains("no agent-written tools"))
        let created = try await tool.call(["action": "create", "source": .string(Self.reverseJS), "language": "javascript"])
        XCTAssertTrue(created.contains("reverse_string") && created.contains("NEXT STEP"), created)
        let l1 = try await tool.call(["action": "list"]); XCTAssertTrue(l1.contains("reverse_string [javascript, active]"), l1)
        do { _ = try await tool.call(["action": "create", "source": "var tool = { name: 'x' }"]); XCTFail() }
        catch { XCTAssertTrue("\(error)".contains("create rejected"), "\(error)") }
        let rm = try await tool.call(["action": "remove", "name": "reverse_string"]); XCTAssertTrue(rm.contains("removed"))
        let box = Locked<[String]>([])
        await store.onChange { tools in box.mutate { $0 = tools.map(\.name) } }
        _ = try await tool.call(["action": "create", "source": .string(Self.reverseJS)])
        XCTAssertEqual(box.value, ["reverse_string"], "onChange must hand the live tool list to the host so the Agent can setTools before its next call")
    }

    private func assertRejected(_ body: @autoclosure () async throws -> DynamicToolStore.CreateResult, contains needle: String) async {
        do { _ = try await body(); XCTFail("expected rejection containing \(needle)") }
        catch { XCTAssertTrue("\(error)".contains(needle), "\(error)") }
    }

    // MARK: Swift (macOS only — needs swiftc)

    #if os(macOS)
    func testSwiftToolCompilesProbesLoadsAndRuns() async throws {
        try XCTSkipIf(SwiftToolCompiler.toolchain() == nil, "no swiftc")
        let dir = tempDir()
        let store = DynamicToolStore(directory: dir)
        let r = try await store.create(name: nil, source: DynamicToolShape.swift, language: nil)
        XCTAssertTrue(r.live); XCTAssertEqual(r.record.language, .swift)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("reverse_string.swift").path))
        let tools = await store.tools; let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool.name, "reverse_string")
        XCTAssertEqual(tool.parameters["required"]?.arrayValue?.first?.stringValue, "text")
        let o1 = try await tool.call(["text": "loopl"]); XCTAssertEqual(o1, "lpool")
        do { _ = try await tool.call([:]); XCTFail() } catch { XCTAssertTrue("\(error)".contains("text is required"), "\(error)") }

        // Relaunch: recompiled from source, still live.
        let again = DynamicToolStore(directory: dir)
        _ = await again.reload()
        let o2 = try await again.tools.first?.call(["text": "xy"]); XCTAssertEqual(o2, "yx")
    }

    func testSwiftMissingClosingBracketIsRepairedOnceAndReported() async throws {
        try XCTSkipIf(SwiftToolCompiler.toolchain() == nil, "no swiftc")
        // loopl-2b's most common slip (measured 3/4 runs): the `]` closing inputSchema is dropped.
        let slipped = DynamicToolShape.swift.replacingOccurrences(of: "\"required\": [\"text\"]]", with: "\"required\": [\"text\"]")
        XCTAssertNotEqual(slipped, DynamicToolShape.swift)
        let store = DynamicToolStore(directory: tempDir())
        let r = try await store.create(name: nil, source: slipped, language: .swift)
        XCTAssertTrue(r.live)
        XCTAssertTrue(r.message.contains("added 1 missing `]`") && r.message.contains("NEXT STEP: call `reverse_string`"), r.message)
        let saved = await store.source(of: "reverse_string")
        XCTAssertTrue(saved?.contains("\"required\": [\"text\"]]") == true, "the repaired source is what gets saved")
        // Pure helper: a line with balanced brackets is not touched; the error line must be named.
        XCTAssertNil(SwiftToolRepair.closeContainerLiteral(source: DynamicToolShape.swift, compilerOutput: "x.swift:1:1: error: expected ']' in container literal expression"))
    }

    func testSwiftCompileErrorsComeBackVerbatimForTheModel() async throws {
        try XCTSkipIf(SwiftToolCompiler.toolchain() == nil, "no swiftc")
        let store = DynamicToolStore(directory: tempDir())
        let bad = DynamicToolShape.swift.replacingOccurrences(of: "String(text.reversed())", with: "text.reversed()")
        do { _ = try await store.create(name: nil, source: bad, language: .swift); XCTFail("should not compile") }
        catch let e as SwiftToolCompiler.Failure {
            XCTAssertEqual(e.stage, .compile)
            XCTAssertTrue(e.message.contains("reverse_string.swift:") && e.message.contains("error:"), e.message)
        }
        await assertRejected(try await store.create(name: nil, source: "let x = 1", language: .swift), contains: "struct <Name>: Tool")
        // Through manage_tools the model reads "create rejected — Swift compile error:\n<swiftc output>".
        do { _ = try await ManageToolsFallbackTool(store: store).call(["action": "create", "source": .string(bad)]); XCTFail() }
        catch { XCTAssertTrue("\(error)".contains("Swift compile error"), "\(error)") }
    }
    #endif
}
