import XCTest
import Loopl
import LooplAppleTools
#if canImport(CoreLocation)
import CoreLocation

/// STOP-LOCATION 2026-10-07 — the empirical half of hypothesis 2. CoreLocation delivers delegate callbacks on the run
/// loop of the thread that CREATED the manager; iOS 14+ calls `locationManagerDidChangeAuthorization` once right
/// after the delegate is set, which makes a cheap probe: a manager made on the main thread reports within
/// milliseconds, one made from a Swift-concurrency task (the old `CoreLocationSource.shared` path, no run loop)
/// never does. Opt-in (`LOOPL_LOCATION_PROBE=1`, simulator or device) — it measures the OS, not loopl's code.
final class CoreLocationRunLoopProbe: XCTestCase {
    final class Probe: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        let fired = XCTestExpectation(description: "didChangeAuthorization")
        var manager: CLLocationManager?
        func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { fired.fulfill() }
    }

    func testDelegateFiresOnlyWithARunLoop() async throws {
        guard ProcessInfo.processInfo.environment["LOOPL_LOCATION_PROBE"] == "1" else { throw XCTSkip("LOOPL_LOCATION_PROBE not set") }
        // Main thread (run loop): the callback comes.
        let onMain = Probe()
        await MainActor.run { let m = CLLocationManager(); m.delegate = onMain; onMain.manager = m }
        let a = await XCTWaiter().fulfillment(of: [onMain.fired], timeout: 3)
        XCTAssertEqual(a, .completed, "a manager created on the main thread must report its authorization")
        // Cooperative pool (no run loop) — how `static let shared` used to build the manager from a tool task.
        let offMain = Probe()
        await Task.detached { precondition(!Thread.isMainThread); let m = CLLocationManager(); m.delegate = offMain; offMain.manager = m }.value
        let b = await XCTWaiter().fulfillment(of: [offMain.fired], timeout: 3)
        print("[probe] main-thread manager: \(a) · cooperative-pool manager: \(b)")
        // Recorded, not asserted: the OS could change; the point is the measurement in the log.
        XCTAssertTrue(a == .completed, "main-thread manager must fire")
    }
}
#endif

#if canImport(CoreLocation)
/// The fixed `CoreLocationSource` end to end on a Simulator with a faked location and the permission granted
/// (`simctl privacy grant location technology.tiny.loopl` + `simctl location set 40.744,-74.0324`): the real `location`
/// tool call — authorization read on main, `requestLocation` on main, delegate fires, reverse geocode — returns the
/// place well inside the 10 s deadline. Opt-in like the probe above.
final class CoreLocationSourceLiveProbe: XCTestCase {
    func testRealLocationToolReturnsAPlace() async throws {
        guard ProcessInfo.processInfo.environment["LOOPL_LOCATION_PROBE"] == "1" else { throw XCTSkip("LOOPL_LOCATION_PROBE not set") }
        LocationStore.use(nil)                              // the real CoreLocationSource, not the fixture
        let t0 = Date()
        let text = try await Task.detached { try await LocationTool().call(["purpose": .string("time")]) }.value   // from a pool thread, like a tool call
        let dt = Date().timeIntervalSince(t0)
        print("[live-location] \(String(format: "%.2f", dt)) s →\n\(text)")
        XCTAssertTrue(text.hasPrefix("location: "), text)
        XCTAssertTrue(text.contains("coordinates: "), text)
        XCTAssertLessThan(dt, 10, "must answer inside the fix deadline")
    }
}
#endif
