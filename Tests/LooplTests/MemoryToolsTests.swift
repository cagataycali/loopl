import XCTest
@testable import Loopl

/// `remember` / `recall` as small models actually call them (MemoryToolsAuditTests measured the shapes): the fact alone,
/// a guessed label that misses, a key with no value, Turkish, "everything".
final class MemoryToolsTests: XCTestCase {
    override func setUp() { NotesStore.save([:]) }
    override func tearDown() { NotesStore.save([:]) }

    func testRememberNeedsOnlyTheFactAndLabelsIt() async throws {
        let r = try await RememberTool().call(["value": "my name is Çağatay"])
        XCTAssertTrue(r.hasPrefix("remembered name-cagatay: my name is Çağatay"), r)
        XCTAssertEqual(NotesStore.all(), ["name-cagatay": "my name is Çağatay"])
    }

    func testRememberKeepsAnExplicitKeyAndMakesLabelsUnique() async throws {
        _ = try await RememberTool().call(["key": "name", "value": "Ada"])
        _ = try await RememberTool().call(["value": "coffee black"])
        _ = try await RememberTool().call(["value": "coffee black"])
        XCTAssertEqual(Set(NotesStore.all().keys), ["name", "coffee-black", "coffee-black-2"])
    }

    func testRememberAcceptsTheShapesSmallModelsEmit() async throws {
        _ = try await RememberTool().call(["note": "I live in Istanbul"])                 // value under another name
        _ = try await RememberTool().call(["key": "favourite colour is teal"])             // only a key, carrying the fact
        let n = NotesStore.all()
        XCTAssertEqual(n.count, 2)
        XCTAssertTrue(n.values.contains("I live in Istanbul")); XCTAssertTrue(n.values.contains("favourite colour is teal"))
        do { _ = try await RememberTool().call([:]); XCTFail("no fact → error") } catch { XCTAssertTrue("\(error)".contains("missing"), "\(error)") }
    }

    func testRecallEmptyAndEverything() async throws {
        do { let v = try await RecallTool().call([:]); XCTAssertEqual(v, "no notes stored yet — nothing has been remembered in this app") }
        NotesStore.save(["city": "Istanbul", "colour": "teal"])
        do { let v = try await RecallTool().call([:]); XCTAssertEqual(v, "city: Istanbul\ncolour: teal") }
        do { let v = try await RecallTool().call(["key": "all"]); XCTAssertEqual(v, "city: Istanbul\ncolour: teal") }
        do { let v = try await RecallTool().call(["key": "city"]); XCTAssertEqual(v, "city: Istanbul") }
    }

    func testRecallWithAGuessedKeyNeverHidesTheNotes() async throws {
        NotesStore.save(["colour": "my favourite colour is teal", "name-cagatay": "my name is Çağatay"])
        // the model guesses a label: loose match on key or value
        do { let v = try await RecallTool().call(["key": "favorite_color"]); XCTAssertEqual(v, "colour: my favourite colour is teal", "color ~ colour: a 2-letter tail difference still finds the note") }
        do { let v = try await RecallTool().call(["key": "name"]); XCTAssertEqual(v, "name-cagatay: my name is Çağatay") }
        do { let v = try await RecallTool().call(["key": "Cagatay"]); XCTAssertEqual(v, "name-cagatay: my name is Çağatay", "diacritics folded") }
        // nothing near → everything, labelled as a miss
        let miss = try await RecallTool().call(["key": "birthday"])
        XCTAssertTrue(miss.hasPrefix("no note labelled 'birthday'. Everything stored:\n"), miss)
        XCTAssertTrue(miss.contains("teal") && miss.contains("Çağatay"))
    }

    func testDescriptionsTellTheModelWhen() {
        XCTAssertTrue(RememberTool().description.contains("'remember'"))
        XCTAssertTrue(RecallTool().description.contains("you have no other memory"))
        XCTAssertEqual(RememberTool().parameters["required"], ["value"])
        XCTAssertEqual(RecallTool().parameters["required"], [])
    }
}
