import XCTest
import Loopl
@testable import LooplAppleTools

/// Phase 7 CONTROLS: the on-device tools attach a typed control to their results — the TOOL decides, never the model.
final class ToolControlsTests: XCTestCase {
    override func tearDown() { TorchStore.use(nil); MusicStore.use(nil); LocationStore.use(nil) }

    func testFlashlightOnCarriesTurnOffAndTheTapTurnsItOff() async throws {
        let torch = FixtureTorch(); TorchStore.use(torch)
        XCTAssertTrue(FlashlightTool.availability().available, "fixture → available on macOS / Simulator")
        let tool: any Tool = FlashlightTool()
        let on = try await tool.call(["state": .string("on"), "level": .number(0.5)], images: [])
        XCTAssertEqual(on.text, "flashlight: on (level 0.50)")
        guard case .toggle(let label, let isOn, let action)? = on.control else { return XCTFail("control") }
        XCTAssertEqual(label, "Turn off"); XCTAssertTrue(isOn)
        XCTAssertEqual(action.tool, "flashlight"); XCTAssertEqual(action.args, ["state": .string("off")])
        // The tap: the control's own action through the same tool.
        let off = try await tool.call(action.args, images: [])
        XCTAssertEqual(off.text, "flashlight: off")
        guard case .toggle(let label2, let isOn2, let action2)? = off.control else { return XCTFail("control after tap") }
        XCTAssertEqual(label2, "Turn on"); XCTAssertFalse(isOn2)
        XCTAssertEqual(action2.args["state"], .string("on"))
        XCTAssertNil(action2.args["level"], "Turn on is full brightness: an LED that is off has no level to keep")
        XCTAssertEqual(torch.calls.map(\.on), [true, false])
        // toggle reads the seam's state
        let toggled = try await tool.call(["state": .string("toggle")], images: [])
        XCTAssertTrue(toggled.text.hasPrefix("flashlight: on"))
    }

    func testVibrateControlReplaysTheSamePattern() throws {
        let r = try VibrateTool.parse(["pattern": .string("heartbeat"), "intensity": .number(0.6)])
        guard case .button(let label, let action) = VibrateTool.control(r) else { return XCTFail("button") }
        XCTAssertEqual(label, "Vibrate again")
        XCTAssertEqual(action.tool, "vibrate")
        XCTAssertEqual(action.args["pattern"], .string("heartbeat"))
        XCTAssertEqual(try VibrateTool.parse(action.args), r, "the action re-parses to the identical request")
    }

    func testMusicResultsCarryThePlayer() async throws {
        let src = FixtureMusicSource(); MusicStore.use(src)
        let tool: any Tool = MusicTool()
        let next = try await tool.call(["action": .string("next")], images: [])
        guard case .player(let p)? = next.control else { return XCTFail("player") }
        XCTAssertEqual(p.title, "So What"); XCTAssertEqual(p.subtitle, "Miles Davis · Kind of Blue")
        XCTAssertTrue(p.playing); XCTAssertEqual(p.volume, 40); XCTAssertEqual(p.tool, "music")
        let paused = try await tool.call(["action": .string("pause")], images: [])
        guard case .player(let p2)? = paused.control else { return XCTFail("player") }
        XCTAssertFalse(p2.playing)
        let vol = try await tool.call(["action": .string("volume"), "level": .number(25)], images: [])
        guard case .player(let p3)? = vol.control else { return XCTFail("player") }
        XCTAssertEqual(p3.volume, 25, "the slider shows the level just set")
        // Nothing queued → an honest title, still a player (play is one tap away).
        MusicStore.use(FixtureMusicSource(queue: [], state: .stopped))
        let empty = try await tool.call(["action": .string("now_playing")], images: [])
        guard case .player(let p4)? = empty.control else { return XCTFail("player") }
        XCTAssertEqual(p4.title, "Nothing queued"); XCTAssertNil(p4.subtitle)
    }

    func testLocationResultCarriesAPinAtTheSameRounding() async throws {
        LocationStore.use(FixtureLocationSource())
        let tool: any Tool = LocationTool()
        let out = try await tool.call([:], images: [])
        guard case .mapPin(let lat, let lon, let label)? = out.control else { return XCTFail("pin") }
        XCTAssertEqual(label, "Hoboken, New Jersey, United States")
        let precise = LocationTool.precise
        XCTAssertEqual(lat, precise ? 40.744 : 40.74, accuracy: 1e-9, "the pin is as coarse as the text the model got")
        XCTAssertEqual(lon, precise ? -74.0324 : -74.03, accuracy: 1e-9)
        XCTAssertTrue(out.text.contains("\(lat), \(lon)"))
    }

    func testAgendaControlsAreOpenLinks() {
        let start = Date(timeIntervalSinceReferenceDate: 812_000_000)
        guard case .link(let label, let url) = CalendarCreateTool.control(AgendaItem(title: "x", start: start)) else { return XCTFail("link") }
        XCTAssertEqual(label, "Open in Calendar"); XCTAssertEqual(url, "calshow:812000000")
        guard case .link(let l2, let u2) = RemindersCreateTool.control(AgendaItem(title: "x")) else { return XCTFail("link") }
        XCTAssertEqual(l2, "Open in Reminders"); XCTAssertEqual(u2, "x-apple-reminderkit://")
        XCTAssertNotNil(URL(string: url)); XCTAssertNotNil(URL(string: u2))
    }
}
