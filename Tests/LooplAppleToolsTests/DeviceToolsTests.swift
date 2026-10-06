import XCTest
import Loopl
@testable import LooplAppleTools

/// flashlight / vibrate / open_app — schema, input validation and (for open_app) URL
/// building with percent-encoded params + the HITL approval request. Hardware calls are
/// device-only; here only the pure parts run.
final class DeviceToolsTests: XCTestCase {
    // MARK: flashlight

    func testFlashlightParse() throws {
        XCTAssertEqual(try FlashlightTool.parse(["state": .string("on")]), .init(state: "on", level: 1))
        XCTAssertEqual(try FlashlightTool.parse(["state": .string("ON"), "level": .number(0.4)]), .init(state: "on", level: 0.4))
        XCTAssertEqual(try FlashlightTool.parse(["state": .string("toggle"), "level": .number(0)]).level, 0.01)
        XCTAssertThrowsError(try FlashlightTool.parse([:]))
        XCTAssertThrowsError(try FlashlightTool.parse(["state": .string("on"), "level": .number(1.5)]))
        XCTAssertThrowsError(try FlashlightTool.parse(["state": .string("on"), "level": .number(-1)]))
        XCTAssertThrowsError(try FlashlightTool.parse(["state": .string("dim")]))
    }

    func testFlashlightSchemaEnumMatchesStates() throws {
        guard case .object(let s) = FlashlightTool().parameters, case .object(let props)? = s["properties"],
              case .object(let state)? = props["state"], case .array(let e)? = state["enum"] else { return XCTFail("schema") }
        XCTAssertEqual(e.compactMap(\.stringValue), FlashlightTool.states)
    }

    func testFlashlightUnavailableHereIsHonest() async {
        // macOS / Simulator: no torch — the call must fail with the availability reason, never crash.
        let a = FlashlightTool.availability()
        if !a.available {
            do { _ = try await FlashlightTool().call(["state": .string("on")]); XCTFail("should throw") }
            catch { XCTAssertTrue("\(error)".contains(a.reason), "\(error)") }
        }
    }

    // MARK: vibrate

    func testVibrateParse() throws {
        XCTAssertEqual(try VibrateTool.parse(["pattern": .string("tap")]), .init(pattern: "tap", intensity: 1))
        XCTAssertEqual(try VibrateTool.parse(["pattern": .string("Heartbeat"), "intensity": .number(0.5)]), .init(pattern: "heartbeat", intensity: 0.5))
        XCTAssertEqual(try VibrateTool.parse(["pattern": .string("long"), "intensity": .number(0)]).intensity, 0.05)
        XCTAssertThrowsError(try VibrateTool.parse([:]))
        XCTAssertThrowsError(try VibrateTool.parse(["pattern": .string("tap"), "intensity": .number(2)]))
        for p in VibrateTool.patterns { XCTAssertGreaterThan(VibrateTool.duration(of: p), 0, p) }
    }

    func testVibrateSchemaEnumMatchesPatterns() throws {
        guard case .object(let s) = VibrateTool().parameters, case .object(let props)? = s["properties"],
              case .object(let pattern)? = props["pattern"], case .array(let e)? = pattern["enum"] else { return XCTFail("schema") }
        XCTAssertEqual(e.compactMap(\.stringValue), VibrateTool.patterns)
    }

    func testVibrateUnavailableHereIsHonest() async {
        let a = VibrateTool.availability()
        if !a.available {
            do { _ = try await VibrateTool().call(["pattern": .string("tap")]); XCTFail("should throw") }
            catch { XCTAssertTrue("\(error)".contains(a.reason), "\(error)") }
        }
    }

    // MARK: open_app — URL building

    func testOpenAppPlainURLs() throws {
        XCTAssertEqual(try OpenAppTool.parse(["url": .string("https://loopl.dev")]).url.absoluteString, "https://loopl.dev")
        XCTAssertEqual(try OpenAppTool.parse(["url": .string(" maps://?q=Istanbul ")]).url.absoluteString, "maps://?q=Istanbul")
        XCTAssertEqual(try OpenAppTool.parse(["url": .string("tel:+905551112233")]).url.absoluteString, "tel:+905551112233")
        XCTAssertEqual(try OpenAppTool.parse(["url": .string("mailto:hi@loopl.dev")]).scheme, "mailto")
        XCTAssertEqual(try OpenAppTool.parse(["url": .string("x-callback-url://x")]).scheme, "x-callback-url")
    }

    func testOpenAppRejectsBadURLs() {
        XCTAssertThrowsError(try OpenAppTool.parse([:]))
        XCTAssertThrowsError(try OpenAppTool.parse(["url": .string("")]))
        XCTAssertThrowsError(try OpenAppTool.parse(["url": .string("loopl.dev")]))            // no scheme
        XCTAssertThrowsError(try OpenAppTool.parse(["url": .string("file:///etc/passwd")]))
        XCTAssertThrowsError(try OpenAppTool.parse(["url": .string("javascript:alert(1)")]))
        XCTAssertThrowsError(try OpenAppTool.parse(["url": .string("https://ok.dev"), "fallback_url": .string("not a url")]))
    }

    func testOpenAppParamsAreMergedAndPercentEncoded() throws {
        let r = try OpenAppTool.parse([
            "url": .string("shortcuts://run-shortcut?name=Log%20Water"),
            "params": .object(["input": .string("text"), "text": .string("500 ml & lemon = good?"), "count": .number(2), "ok": .bool(true),
                               "ctx": .object(["from": .string("loopl"), "n": .number(1)])]),
        ])
        XCTAssertEqual(r.scheme, "shortcuts"); XCTAssertEqual(r.paramCount, 5)
        let s = r.url.absoluteString
        XCTAssertTrue(s.hasPrefix("shortcuts://run-shortcut?name=Log%20Water&"), s)   // the existing query item is kept, first
        XCTAssertTrue(s.contains("count=2"), s)
        XCTAssertTrue(s.contains("ok=true"), s)
        XCTAssertTrue(s.contains("text=500%20ml%20%26%20lemon%20%3D%20good%3F"), s)
        XCTAssertTrue(s.contains("ctx=%7B%22from%22%3A%22loopl%22%2C%22n%22%3A1%7D"), s)   // nested → compact JSON, encoded
        XCTAssertFalse(s.contains(" ")); XCTAssertEqual(s.filter { $0 == "?" }.count, 1)
        // Round-trips through URLComponents as 5 + 1 items with the original values.
        let items = try XCTUnwrap(URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.first { $0.name == "text" }?.value, "500 ml & lemon = good?")
        XCTAssertEqual(items.first { $0.name == "ctx" }?.value, "{\"from\":\"loopl\",\"n\":1}")
    }

    func testOpenAppParamsOnSchemeWithoutQuery() throws {
        let r = try OpenAppTool.parse(["url": .string("tinyapp://chat"), "params": .object(["prompt": .string("héllo wörld")])])
        XCTAssertEqual(r.url.absoluteString, "tinyapp://chat?prompt=h%C3%A9llo%20w%C3%B6rld")
        let f = try OpenAppTool.parse(["url": .string("spotify://search"), "fallback_url": .string("https://open.spotify.com")])
        XCTAssertEqual(f.fallback?.absoluteString, "https://open.spotify.com")
    }

    func testOpenAppEncodeIsStrict() {
        XCTAssertEqual(OpenAppTool.encode("a b&c=d+e/f?g#h"), "a%20b%26c%3Dd%2Be%2Ff%3Fg%23h")
        XCTAssertEqual(OpenAppTool.encode("safe-._~09Az"), "safe-._~09Az")
    }

    // MARK: open_app — HITL

    func testOpenAppAsksForApprovalUnlessSchemeAllowed() throws {
        let saved = OpenAppTool.allowedSchemes
        defer { OpenAppTool.allowedSchemes = saved }
        OpenAppTool.allowedSchemes = []
        let tool = OpenAppTool()
        let req = try XCTUnwrap(tool.requiresApproval(for: ["url": .string("maps://?q=Kadikoy"), "params": .object(["z": .number(12)])]))
        XCTAssertEqual(req.toolName, "open_app"); XCTAssertEqual(req.risk, .medium); XCTAssertEqual(req.method, "OPEN")
        XCTAssertTrue(req.title.hasPrefix("Open Maps"), req.title)
        XCTAssertEqual(req.url, "maps://?q=Kadikoy&z=12")
        XCTAssertTrue(req.detail?.contains("1 parameter") == true, req.detail ?? "")
        XCTAssertEqual(req.input["url"], .string("maps://?q=Kadikoy"))
        // https shows the host; the card can lead with it.
        let web = try XCTUnwrap(tool.requiresApproval(for: ["url": .string("https://loopl.dev/start/")]))
        XCTAssertEqual(web.title, "Open Safari · loopl.dev"); XCTAssertEqual(web.host, "loopl.dev")
        // Allowlisted scheme → no card.
        OpenAppTool.allowedSchemes = ["Maps"]
        XCTAssertTrue(OpenAppTool.isAllowed(scheme: "maps"))
        XCTAssertNil(tool.requiresApproval(for: ["url": .string("maps://?q=Kadikoy")]))
        XCTAssertNotNil(tool.requiresApproval(for: ["url": .string("https://loopl.dev")]))
        // Invalid input: no card — `call` reports the error instead.
        XCTAssertNil(tool.requiresApproval(for: ["url": .string("nope")]))
    }

    func testOpenAppAppNames() {
        XCTAssertEqual(OpenAppTool.appName(for: "shortcuts"), "Shortcuts")
        XCTAssertEqual(OpenAppTool.appName(for: "tel"), "Phone")
        XCTAssertEqual(OpenAppTool.appName(for: "tinyapp"), "tiny")
        XCTAssertEqual(OpenAppTool.appName(for: "zzz"), "zzz://")
        XCTAssertEqual(OpenAppTool.appName(for: "comgooglemaps"), "Google Maps")
        XCTAssertEqual(OpenAppTool.schemeLabel("tel"), "tel:"); XCTAssertEqual(OpenAppTool.schemeLabel("maps"), "maps://")
        XCTAssertTrue(OpenAppTool.knownSchemes.contains("shortcuts")); XCTAssertTrue(OpenAppTool.knownSchemes.contains("x-callback-url"))
    }

    func testNoneOfTheDeviceToolsAreCalledAppleIntelligence() {
        XCTAssertFalse(AppleTools.names.contains("apple_intelligence"))
        XCTAssertEqual(Array(AppleTools.names.filter { ["flashlight", "vibrate", "open_app"].contains($0) }), ["flashlight", "vibrate", "open_app"])
        // flashlight / vibrate never need approval; open_app does by default.
        XCTAssertNil(FlashlightTool().requiresApproval(for: ["state": .string("on")]))
        XCTAssertNil(VibrateTool().requiresApproval(for: ["pattern": .string("tap")]))
    }
}
