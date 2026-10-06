import XCTest
@testable import Loopl
#if canImport(LooplApp)
@testable import LooplApp

/// Share to Hugging Face used to drop every picture: `SavedConversation.exportThread()` mapped `.user(s, images)` to a
/// text-only message, so a "kept" redaction still pushed a text-only dataset (TRAIN-E2E-VISION, 112 rows / 0 images).
/// Runs in the Xcode-hosted LooplTests; `swift test` compiles this file empty.
final class HistoryExportImagesTests: XCTestCase {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP4z8DAwMDAxMDAwMDAAAANHQEDasKb6QAAAABJRU5ErkJggg==")!

    private func saved(images: [ImageBlock]?) -> SavedConversation {
        SavedConversation(id: UUID(), title: "picture", updated: Date(), modelName: "m",
                          items: [.user("What do you see?", images: images), .assistant("A red square.")])
    }

    func testPicturesReachTheShard() throws {
        let c = saved(images: [ImageBlock(data: Self.png, mime: "image/png", width: 2, height: 2)])
        let r = try ConversationExport.record(c.exportThread(), options: .init())
        XCTAssertEqual(r.images.count, 1, "the user's picture must be exported as images/<sha>.png")
        let parts = r.json["messages"]?.arrayValue?.first { $0["role"]?.stringValue == "user" }?["content"]?.arrayValue ?? []
        XCTAssertEqual(parts.first?["type"]?.stringValue, "image")
    }

    func testRemovePicturesStillStrips() throws {
        let c = saved(images: [ImageBlock(data: Self.png, mime: "image/png", width: 2, height: 2)])
        var o = ConversationExport.Options(); o.redaction.stripImages = true
        XCTAssertEqual(try ConversationExport.record(c.exportThread(), options: o).images.count, 0)
    }

    func testTextOnlyThreadUnchanged() throws {
        XCTAssertEqual(try ConversationExport.record(saved(images: nil).exportThread(), options: .init()).images.count, 0)
        XCTAssertEqual(try ConversationExport.record(saved(images: []).exportThread(), options: .init()).images.count, 0)
    }
}
#endif
