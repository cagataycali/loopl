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
        XCTAssertTrue(props.isEmpty, "no parameters — nothing for a small model to fill in wrongly")
    }

    func testUnknownPlaceStillGivesCoordinates() {
        let out = LocationTool.render(Place(latitude: 41.0082, longitude: 28.9784), precise: false)
        XCTAssertEqual(out, "location: unknown place\ncoordinates: 41.01, 28.98 (about 1 km)")
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
