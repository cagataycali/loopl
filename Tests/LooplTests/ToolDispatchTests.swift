import XCTest
@testable import Loopl

/// `call(_:images:)` / `callOutput(_:)` must dispatch DYNAMICALLY through `any Tool` — the Agent holds tools as existentials.
/// Before they were protocol requirements, a tool's own implementation was shadowed by the extension default: describe_image
/// got no images, generate_image's picture was dropped (found by ToolsE2ETests with a real model, 2026-10-06).
final class ToolDispatchTests: XCTestCase {
    struct Sees: Tool {
        let name = "sees"; let description = "x"; let parameters: JSONValue = ["type": "object"]
        func call(_ args: [String: JSONValue]) async throws -> String { "no images" }
        func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { ToolOutput(text: "saw \(images.count)") }
    }
    struct Draws: Tool {
        let name = "draws"; let description = "x"; let parameters: JSONValue = ["type": "object"]
        func call(_ args: [String: JSONValue]) async throws -> String { "drew" }
        func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput { ToolOutput(text: "drew", images: [ImageBlock(data: Data([1]), mime: "image/png", width: 1, height: 1, alt: nil)]) }
    }
    struct Plain: Tool {
        let name = "plain"; let description = "x"; let parameters: JSONValue = ["type": "object"]
        func call(_ args: [String: JSONValue]) async throws -> String { "plain" }
    }

    func testImageConsumerGetsTheImagesThroughAnExistential() async throws {
        let tool: any Tool = Sees()
        let out = try await tool.call([:], images: [ImageBlock(data: Data([1]), mime: "image/png", width: 1, height: 1, alt: nil)])
        XCTAssertEqual(out.text, "saw 1")
    }

    func testImageProducerKeepsItsPictureThroughAnExistential() async throws {
        let tool: any Tool = Draws()
        let out = try await tool.call([:], images: [])
        XCTAssertEqual(out.text, "drew"); XCTAssertEqual(out.images.count, 1)
    }

    func testPlainToolStillWorks() async throws {
        let tool: any Tool = Plain()
        let out = try await tool.call([:], images: [ImageBlock(data: Data([1]), mime: "image/png", width: 1, height: 1, alt: nil)])
        XCTAssertEqual(out.text, "plain"); XCTAssertTrue(out.images.isEmpty)
    }
}
