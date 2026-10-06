import XCTest
import Loopl
@testable import LooplAppleTools

/// `location` against the fixture source: coarse by default (~1 km, no altitude), precise on request, no approval card, off by default.
final class LocationToolTests: XCTestCase {
    var src: FixtureLocationSource!
    override func setUp() { src = FixtureLocationSource(); LocationStore.use(src); LocationTool.precise = false }
    override func tearDown() { LocationStore.use(nil); LocationTool.precise = false }

    func testCoarseByDefault() async throws {
        let out = try await LocationTool().call([:])
        XCTAssertEqual(out, "location: Hoboken, New Jersey, United States\ncoordinates: 40.74, -74.03 (about 1 km)\ntime zone: America/New_York")
        XCTAssertEqual(src.requests, [false])
        XCTAssertFalse(out.contains("altitude")); XCTAssertFalse(out.contains("accuracy"))
    }

    func testPreciseIsTheUsersSettingNotTheModels() async throws {
        // Measured: a 0.8B passed precise:true 9/9 — so the argument is ignored and Settings decides.
        var out = try await LocationTool().call(["precise": .bool(true)])
        XCTAssertTrue(out.contains("(about 1 km)"), out); XCTAssertEqual(src.requests, [false])
        LocationTool.precise = true
        out = try await LocationTool().call([:])
        XCTAssertTrue(out.contains("coordinates: 40.744, -74.0324\n"), out)
        XCTAssertTrue(out.contains("accuracy: ±35 m")); XCTAssertTrue(out.contains("altitude: 6 m"))
        XCTAssertEqual(src.requests, [false, true])
        guard case .object(let s) = LocationTool().parameters, case .object(let props)? = s["properties"] else { return XCTFail("schema") }
        XCTAssertNil(props["precise"], "precision is never the model's argument")
        XCTAssertEqual(Array(props.keys), ["purpose"])
    }

    func testUnknownPlaceStillGivesCoordinates() {
        let out = LocationTool.render(Place(latitude: 41.0082, longitude: 28.9784), precise: false)
        XCTAssertEqual(out, "location: unknown place\ncoordinates: 41.01, 28.98 (about 1 km)")
    }

    func testPurposeWeatherAndTime() async throws {
        let w = try await LocationTool().call(["purpose": .string("weather")])
        XCTAssertTrue(w.hasSuffix("weather: call http GET https://api.open-meteo.com/v1/forecast?latitude=40.74&longitude=-74.03&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m&timezone=auto"), w)
        let t = LocationTool.render(FixtureLocationSource().place, precise: false, purpose: "time", now: Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertTrue(t.contains("local time: 2026-10-03 00:00 (Saturday)"), t)
        XCTAssertEqual(LocationTool.parse(["purpose": .string("WEATHER")]), "weather")
        XCTAssertEqual(LocationTool.parse(["purpose": .string("nearby")]), "place", "unknown purpose → plain fix, never an error")
        XCTAssertEqual(LocationTool.parse([:]), "place")
    }

    func testRounding() {
        XCTAssertEqual(LocationStore.round(-74.0324, decimals: 2), -74.03)
        XCTAssertEqual(LocationStore.round(40.744012, decimals: 5), 40.74401)
    }

    func testReadOnlyNoCardOffByDefaultRegistered() {
        XCTAssertNil(LocationTool().requiresApproval(for: [:]))
        XCTAssertTrue(AppleTools.names.contains("location"))
        XCTAssertFalse(AppleTools.isDefaultOn("location"))
        XCTAssertTrue(LocationTool.availability().available, "fixture counts as available")
    }
}
