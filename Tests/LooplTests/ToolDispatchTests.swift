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

    func testToolReturnedPicturesAreVisibleToTheNextTool() {
        // photos_recent → describe_image: the newest photo is image_index 0 (most recent last in the list).
        func img(_ b: UInt8) -> ImageBlock { ImageBlock(data: Data([b]), mime: "image/jpeg", width: 1, height: 1, alt: nil) }
        let messages: [Message] = [
            .user("old", images: [img(9)]), .assistant("…"),
            .user("what's in my last photo?", images: [img(1)]),
            .assistant(text: "", toolUses: [ToolUse(toolUseId: "t1", name: "photos_recent", input: [:])]),
            .toolResults([ToolResult(toolUseId: "t1", name: "photos_recent", status: .success, content: "photos: 2", durationMs: 1, images: [img(2), img(3)])]),
        ]
        XCTAssertEqual(Agent.visibleImages(messages).map { $0.data.first! }, [1, 2, 3], "user's picture first, then the tool's, most recent last")
        XCTAssertEqual(Agent.visibleImages([.user("hi")]), [])
        XCTAssertEqual(Agent.visibleImages([]), [])
    }
}
