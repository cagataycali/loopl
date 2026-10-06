import XCTest
import Loopl
@testable import LooplAppleTools

final class AppleToolsTests: XCTestCase {
    func testEveryToolHasAnObjectSchemaWithDescribedProperties() throws {
        for tool in AppleTools.all {
            guard case .object(let schema) = tool.parameters else { return XCTFail("\(tool.name): parameters must be an object") }
            XCTAssertEqual(schema["type"], .string("object"), tool.name)
            guard case .object(let props)? = schema["properties"] else { return XCTFail("\(tool.name): no properties") }
            for (k, v) in props {
                guard case .object(let p) = v else { return XCTFail("\(tool.name).\(k): property must be an object") }
                XCTAssertNotNil(p["type"], "\(tool.name).\(k) has no type")
                XCTAssertNotNil(p["description"], "\(tool.name).\(k) has no description")
            }
            if case .array(let req)? = schema["required"] {
                for r in req { if case .string(let s) = r { XCTAssertNotNil(props[s], "\(tool.name): required \(s) not in properties") } }
            }
            XCTAssertFalse(tool.description.isEmpty, tool.name)
            XCTAssertFalse(type(of: tool).onDeviceCopy.isEmpty, tool.name)
        }
    }

    func testNamesAreUniqueSnakeCaseAndStable() {
        let names = AppleTools.names
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names, ["generate_image", "generate_voice", "read_text", "describe_image", "translate", "transcribe", "detect_language", "flashlight", "vibrate", "open_app"])
        for n in names { XCTAssertTrue(n.allSatisfy { $0.isLowercase || $0 == "_" }, n) }
    }

    func testOpenAIFunctionSpecRoundTripsThroughJSON() throws {
        for tool in AppleTools.all {
            let data = try JSONEncoder().encode(tool.toolSpec.openAIFunction)
            let back = try JSONDecoder().decode(JSONValue.self, from: data)
            XCTAssertEqual(back, tool.toolSpec.openAIFunction, tool.name)
        }
    }

    func testAvailabilityReasonIsNonEmptyWhenUnavailable() {
        for tool in AppleTools.all {
            let a = type(of: tool).availability()
            if !a.available { XCTAssertFalse(a.reason.isEmpty, "\(tool.name) unavailable without a reason") }
            else { XCTAssertEqual(a.reason, "", tool.name) }
            XCTAssertEqual(AppleTools.availability(of: tool.name), a)
        }
        XCTAssertFalse(AppleTools.availability(of: "nope").available)
        // These never need a permission or Apple Intelligence: available wherever the frameworks exist (this Mac included).
        XCTAssertTrue(ReadTextTool.availability().available)
        #if !targetEnvironment(simulator)
        XCTAssertTrue(DescribeImageTool.availability().available)
        #endif
        XCTAssertTrue(DetectLanguageTool.availability().available)
        XCTAssertTrue(GenerateVoiceTool.availability().available)
    }

    func testArgumentValidationBeforeAnyFrameworkCall() async {
        await assertThrows(GenerateImageTool(), [:], contains: "prompt")
        await assertThrows(GenerateImageTool(), ["prompt": .string("x"), "style": .string("oil")], contains: "style")
        await assertThrows(GenerateVoiceTool(), [:], contains: "text")
        await assertThrows(GenerateVoiceTool(), ["text": .string(String(repeating: "a", count: 1001))], contains: "1000")
        await assertThrows(TranslateTool(), ["text": .string("hi")], contains: "to")
        await assertThrows(TranscribeTool(), ["path": .string("/nope/none.caf")], contains: "no file")
        await assertThrows(FlashlightTool(), ["state": .string("blink")], contains: "state")
        await assertThrows(VibrateTool(), ["pattern": .string("morse")], contains: "pattern")
        await assertThrows(OpenAppTool(), [:], contains: "url")
        await assertThrows(DetectLanguageTool(), [:], contains: "text")
        await assertThrows(ReadTextTool(), [:], contains: "no image")
        await assertThrows(DescribeImageTool(), [:], contains: "no image")
    }

    func testDetectLanguage() async throws {
        let out = try await DetectLanguageTool().call(["text": .string("Merhaba, bugün hava çok güzel ve yarın İstanbul'a gidiyoruz.")])
        XCTAssertTrue(out.hasPrefix("language: tr"), out)
        let en = try await DetectLanguageTool().call(["text": .string("The quick brown fox jumps over the lazy dog near the river bank.")])
        XCTAssertTrue(en.hasPrefix("language: en"), en)
    }

    func testPickImageOrdersMostRecentFirst() throws {
        let a = ImageBlock(data: Data([1]), mime: "image/png", alt: "a"), b = ImageBlock(data: Data([2]), mime: "image/png", alt: "b")
        XCTAssertEqual(try pickImage([a, b], args: [:]).alt, "b")
        XCTAssertEqual(try pickImage([a, b], args: ["image_index": .number(1)]).alt, "a")
        XCTAssertThrowsError(try pickImage([a, b], args: ["image_index": .number(2)]))
        XCTAssertThrowsError(try pickImage([], args: [:]))
    }

    func testImageCodecDownscalesToJPEGWithMetadata() throws {
        let cg = try XCTUnwrap(ImageCodec.testImage(width: 2048, height: 1024))
        let block = try ImageCodec.jpeg(cg, maxSide: 1024, alt: "fixture")
        XCTAssertEqual(block.mime, "image/jpeg"); XCTAssertEqual(block.format, "jpeg")
        XCTAssertEqual(block.width, 1024); XCTAssertEqual(block.height, 512)
        XCTAssertEqual(block.alt, "fixture")
        XCTAssertEqual(ImageBlock.detectMime(block.data), "image/jpeg")
        XCTAssertGreaterThan(block.byteCount, 500)
        // Decodes back
        let round = try ImageCodec.cgImage(block)
        XCTAssertEqual(round.width, 1024)
    }

    func testToolOutputDefaultsWrapCall() async throws {
        let t = ClosureTool(name: "echo", description: "d") { _ in "hi" }
        let out = try await t.callOutput([:])
        XCTAssertEqual(out, ToolOutput(text: "hi"))
        let withImages = try await t.call([:], images: [ImageBlock(data: Data([1]), mime: "image/png")])
        XCTAssertEqual(withImages.text, "hi"); XCTAssertTrue(withImages.images.isEmpty)
    }

    func testDescribeImageOnFixtureReturnsLabelsAndFaceCount() async throws {
        try XCTSkipUnless(DescribeImageTool.availability().available, "ClassifyImageRequest has no CoreML backing on the Simulator")
        let cg = try XCTUnwrap(ImageCodec.testImage())
        let block = try ImageCodec.jpeg(cg)
        let out = try await DescribeImageTool().call([:], images: [block])
        XCTAssertTrue(out.text.contains("picture: 256×160 jpeg"), out.text)
        XCTAssertTrue(out.text.contains("labels:"), out.text)
        XCTAssertTrue(out.text.contains("faces: 0"), out.text)
    }

    func testReadTextOnBlankFixtureSaysNoText() async throws {
        let cg = try XCTUnwrap(ImageCodec.testImage())
        let out = try await ReadTextTool().call([:], images: [try ImageCodec.jpeg(cg)])
        XCTAssertTrue(out.text.hasPrefix("no text found"), out.text)
    }

    private func assertThrows(_ tool: any Tool, _ args: [String: JSONValue], contains: String, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await tool.call(args); XCTFail("\(tool.name) should throw", file: file, line: line) }
        catch { XCTAssertTrue("\(error)".localizedCaseInsensitiveContains(contains), "\(tool.name): \(error)", file: file, line: line) }
    }
}

/// Not an assertion — a report. Prints every tool's availability on whatever runs the
/// tests (Mac, Simulator, iPhone) so the proof log says what the device can do.
final class AppleToolsAvailabilityReport: XCTestCase {
    func testPrintAvailability() {
        var lines = ["APPLE-TOOLS availability on \(ProcessInfo.processInfo.operatingSystemVersionString):"]
        for tool in AppleTools.all {
            let a = type(of: tool).availability()
            lines.append("  \(tool.name): \(a.available ? "available" : "unavailable — \(a.reason)")")
        }
        print(lines.joined(separator: "\n"))
        XCTAssertFalse(AppleTools.all.isEmpty)
    }
}
