import XCTest
import Loopl
@testable import LooplAppleTools

/// `music` against the fixture player: one `action` tool, forgiving parser, no card, on by default.
final class MusicToolTests: XCTestCase {
    var src: FixtureMusicSource!
    override func setUp() { src = FixtureMusicSource(); MusicStore.use(src) }
    override func tearDown() { MusicStore.use(nil) }

    func testSchemaAndDefaults() {
        XCTAssertTrue(MusicTool.defaultOn, "the owner asked for it explicitly")
        XCTAssertTrue(AppleTools.defaultOnNames.contains("music"))
        XCTAssertTrue(AppleTools.names.contains("music"))
        guard case .object(let s) = MusicTool().parameters, case .object(let props)? = s["properties"] else { return XCTFail("schema") }
        XCTAssertEqual(Set(props.keys), ["action", "level"])
        guard case .object(let a)? = props["action"], case .array(let e)? = a["enum"] else { return XCTFail("enum") }
        XCTAssertEqual(e.compactMap { if case .string(let s) = $0 { return s }; return nil }, MusicTool.actions)
        XCTAssertTrue(MusicTool.availability().available, "fixture → available on macOS too")
    }

    func testParseAcceptsWhatSmallModelsEmit() throws {
        XCTAssertEqual(try MusicTool.parse(["action": .string("pause")]).action, "pause")
        XCTAssertEqual(try MusicTool.parse(["action": .string("skip")]).action, "next")
        XCTAssertEqual(try MusicTool.parse(["command": .string("resume")]).action, "play")
        XCTAssertEqual(try MusicTool.parse(["action": .string("back")]).action, "previous")
        XCTAssertEqual(try MusicTool.parse(["action": .string("status")]).action, "now_playing")
        XCTAssertEqual(try MusicTool.parse([:]).action, "now_playing", "no action at all → tell what is playing")
        let v = try MusicTool.parse(["action": .string("volume"), "level": .number(40)])
        XCTAssertEqual(v.level, 40)
        XCTAssertEqual(try MusicTool.parse(["action": .string("volume"), "level": .string("65%")]).level, 65)
        XCTAssertEqual(try MusicTool.parse(["action": .string("volume"), "volume": .number(0.3)]).level, 30, "fractions mean percent")
        XCTAssertEqual(try MusicTool.parse(["action": .string("volume"), "level": .number(250)]).level, 100, "clamped")
        XCTAssertEqual(try MusicTool.parse(["action": .string("volume_up")]), MusicTool.Request(action: "volume", level: nil, delta: 15))
        XCTAssertEqual(try MusicTool.parse(["action": .string("quieter")]).delta, -15)
        XCTAssertEqual(try MusicTool.parse(["action": .string("volume"), "level": .string("up")]).delta, 15)
        XCTAssertEqual(try MusicTool.parse(["action": .string("volume"), "level": .string("down")]).delta, -15)
        XCTAssertEqual(try MusicTool.parse(["action": .string("volume"), "level": .string("-10")]).delta, -10)
        XCTAssertEqual(try MusicTool.parse(["action": .string("volume"), "_": .string("20")]).level, 20, "a loose value next to action is the level")
        XCTAssertEqual(try MusicTool.parse(["action": .string("volume"), "level": .string("max")]).level, 100)
        XCTAssertEqual(try MusicTool.parse(["level": .number(20)]).action, "volume", "a bare level is a volume request")
        XCTAssertThrowsError(try MusicTool.parse(["action": .string("volume")]))
        XCTAssertThrowsError(try MusicTool.parse(["action": .string("dance")]))
    }

    func testActionsDriveThePlayerAndReport() async throws {
        let t = MusicTool()
        var out = try await t.call(["action": .string("pause")])
        XCTAssertEqual(out, "music: paused\nnow playing: Blue in Green — Miles Davis (Kind of Blue)\nvolume: 40%")
        out = try await t.call(["action": .string("next")])
        XCTAssertTrue(out.hasPrefix("music: skipped to the next song\nnow playing: So What — Miles Davis"), out)
        out = try await t.call(["action": .string("volume"), "level": .number(70)])
        XCTAssertEqual(out, "music: volume set to 70%\nnow playing: So What — Miles Davis (Kind of Blue)")
        XCTAssertEqual(src.volume, 70)
        out = try await t.call(["action": .string("previous")])
        XCTAssertTrue(out.hasPrefix("music: went back\nnow playing: Blue in Green"), out)
        out = try await t.call(["action": .string("play")])
        XCTAssertTrue(out.hasPrefix("music: playing\n"), out)
        out = try await t.call(["action": .string("now_playing")])
        XCTAssertEqual(out, "music: playing\nnow playing: Blue in Green — Miles Davis (Kind of Blue)\nvolume: 70%")
        XCTAssertEqual(src.log, ["pause", "now_playing", "next", "now_playing", "volume 70", "now_playing", "previous", "now_playing", "play", "now_playing", "now_playing"])
        out = try await t.call(["action": .string("volume"), "level": .string("up")])
        XCTAssertEqual(out, "music: volume set to 85%\nnow playing: Blue in Green — Miles Davis (Kind of Blue)"); XCTAssertEqual(src.volume, 85)
        _ = try await t.call(["action": .string("louder")]); XCTAssertEqual(src.volume, 100, "clamped")
        out = try await t.call(["action": .string("volume"), "level": .string("down")])
        XCTAssertTrue(out.hasPrefix("music: volume set to 85%"), out)
    }

    func testNoTitleIsHonest() {
        XCTAssertEqual(MusicTool.render(NowPlaying(state: .stopped, volume: 25), after: "now_playing"),
                       "music: stopped\nnothing is queued — the user can start a song in the Music app\nvolume: 25%")
        XCTAssertEqual(MusicTool.render(NowPlaying(state: .playing), after: "now_playing"),
                       "music: playing\ntitle unavailable (the user has not allowed access to the music library)")
        XCTAssertEqual(MusicTool.render(NowPlaying(state: .paused), after: "pause"), "music: paused")
    }

    func testNoApprovalCard() {
        // Every music action is low-risk and reversible from the Lock Screen: the tool declares no approval hook.
        XCTAssertNil(MusicTool().requiresApproval(for: ["action": .string("volume"), "level": .number(100)]))
        XCTAssertNil(MusicTool().requiresApproval(for: ["action": .string("next")]))
    }
}
