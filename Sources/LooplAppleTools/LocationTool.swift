import Foundation
import Loopl
#if canImport(CoreLocation)
import CoreLocation
#endif

// `location` — where the user is, for the model's own follow-ups (weather through `http` + open-meteo, the time
// zone, "what's near me"). Lane TOOLS-EXPAND, 2026-10-06. OFF by default; when-in-use permission asked just in time
// (`NSLocationWhenInUseUsageDescription`). COARSE unless the USER says otherwise: the model gets the place name and
// coordinates rounded to ~1 km (two decimals); Settings › location › "Exact position" (`LocationTool.preciseKey`)
// switches to the best fix iOS allows. MEASURED 2026-10-06: with a `precise: true` parameter in the schema,
// Qwen3.5-0.8B set it true 9 of 9 times ("Where am I?" included) — a model-controlled privacy knob is no knob, so the
// tool takes no parameters and the person decides. Reads only, no card.
//
// `LocationSource` is the seam: `CoreLocationSource` on a device/Simulator, `FixtureLocationSource` for tests and the
// real-model harness (the Simulator can also fake a location: Features › Location).

/// A fix as the tool reports it.
public struct Place: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double
    /// Metres; `nil` when unknown.
    public var accuracy: Double?
    public var name: String?        // "Hoboken, New Jersey, United States"
    public var timeZone: String?    // "America/New_York"
    public var altitude: Double?
    public init(latitude: Double, longitude: Double, accuracy: Double? = nil, name: String? = nil, timeZone: String? = nil, altitude: Double? = nil) {
        self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy; self.name = name; self.timeZone = timeZone; self.altitude = altitude
    }
}

public protocol LocationSource: Sendable {
    /// One fix. `precise` asks for the best accuracy the user allows; otherwise a kilometre is enough.
    func current(precise: Bool) async throws -> Place
}

public final class FixtureLocationSource: LocationSource, @unchecked Sendable {
    public var place: Place
    public private(set) var requests: [Bool] = []
    public init(_ place: Place = Place(latitude: 40.7440, longitude: -74.0324, accuracy: 35, name: "Hoboken, New Jersey, United States", timeZone: "America/New_York", altitude: 6)) { self.place = place }
    public func current(precise: Bool) async throws -> Place { requests.append(precise); return place }
}

public enum LocationStore {
    nonisolated(unsafe) private static var override: (any LocationSource)?
    private static let lock = NSLock()
    public static func use(_ source: (any LocationSource)?) { lock.lock(); override = source; lock.unlock() }
    public static var isFixture: Bool { lock.lock(); defer { lock.unlock() }; return override != nil }
    static var current: any LocationSource {
        lock.lock(); defer { lock.unlock() }
        if let o = override { return o }
        #if canImport(CoreLocation)
        return CoreLocationSource.shared
        #else
        return FixtureLocationSource()
        #endif
    }

    /// Two decimals ≈ 1.1 km; four ≈ 11 m.
    static func round(_ v: Double, decimals: Int) -> Double { let p = pow(10.0, Double(decimals)); return (v * p).rounded() / p }
}

#if canImport(CoreLocation)
/// `CLLocationManager` wrapped for one fix at a time; reverse geocoding gives the place name. Access is requested on first use.
final class CoreLocationSource: NSObject, LocationSource, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = CoreLocationSource()
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<CLLocation, any Error>] = []
    private var authWaiters: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private override init() { super.init(); manager.delegate = self }

    func current(precise: Bool) async throws -> Place {
        let status = await ensureAuthorised()
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: break
        case .denied: throw ToolError("location access is off — the user can allow it in Settings › Privacy › Location Services › loopl")
        case .restricted: throw ToolError("location is restricted on this device")
        default: throw ToolError("the user did not allow location access")
        }
        manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyKilometer
        let loc: CLLocation = try await withCheckedThrowingContinuation { c in
            lock.withLock { waiters.append(c) }
            DispatchQueue.main.async { self.manager.requestLocation() }
        }
        var place = Place(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
                          altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil)
        if let pm = try? await CLGeocoder().reverseGeocodeLocation(loc).first {
            place.name = [pm.locality ?? pm.subLocality ?? pm.name, pm.administrativeArea, pm.country].compactMap { $0 }.joined(separator: ", ")
            place.timeZone = pm.timeZone?.identifier
        }
        if place.timeZone == nil { place.timeZone = TimeZone.current.identifier }
        return place
    }

    private func ensureAuthorised() async -> CLAuthorizationStatus {
        let s = manager.authorizationStatus
        if s != .notDetermined { return s }
        return await withCheckedContinuation { c in
            lock.withLock { authWaiters.append(c) }
            DispatchQueue.main.async { self.manager.requestWhenInUseAuthorization() }
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        guard s != .notDetermined else { return }
        let ws = lock.withLock { let w = authWaiters; authWaiters = []; return w }
        ws.forEach { $0.resume(returning: s) }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let ws = lock.withLock { let w = waiters; waiters = []; return w }
        ws.forEach { $0.resume(returning: l) }
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: any Error) {
        let ws = lock.withLock { let w = waiters; waiters = []; return w }
        ws.forEach { $0.resume(throwing: ToolError("could not get a location fix: \(error.localizedDescription)")) }
    }
}
#endif

public struct LocationTool: AppleTool {
    public init() {}
    public let name = "location"
    public let description = "Where the user is right now: place name (city, region, country), coordinates and time zone. Use when the user asks about their location, what is nearby, the local weather (then call http with the coordinates) or the local time."
    public let parameters: JSONValue = ToolSchema.object([:])
    public static let onDeviceCopy = "Tells the model your city and rough coordinates (about 1 km) when it asks. Asks for location access the first time."
    public static var defaultOn: Bool { false }

    /// UserDefaults: the person's choice between ~1 km (default) and the best fix iOS allows. Never the model's.
    public static let preciseKey = "loopl.location.precise"
    public static var precise: Bool {
        get { UserDefaults.standard.bool(forKey: preciseKey) }
        set { UserDefaults.standard.set(newValue, forKey: preciseKey) }
    }

    public static func availability() -> ToolAvailability {
        if LocationStore.isFixture { return .ok }
        #if canImport(CoreLocation) && (os(iOS) || os(macOS) || os(watchOS))
        return CLLocationManager.locationServicesEnabled() ? .ok : .no("Location Services are off in Settings › Privacy")
        #else
        return .no("Needs Location Services")
        #endif
    }

    /// The text the model reads. Coarse: 2 decimals (~1 km) and no altitude; precise: 5 decimals + accuracy.
    public static func render(_ p: Place, precise: Bool) -> String {
        let d = precise ? 5 : 2
        var lines = ["location: \(p.name ?? "unknown place")"]
        lines.append("coordinates: \(LocationStore.round(p.latitude, decimals: d)), \(LocationStore.round(p.longitude, decimals: d))\(precise ? "" : " (about 1 km)")")
        if precise, let a = p.accuracy { lines.append("accuracy: ±\(Int(a)) m") }
        if precise, let alt = p.altitude { lines.append("altitude: \(Int(alt)) m") }
        if let tz = p.timeZone { lines.append("time zone: \(tz)") }
        return lines.joined(separator: "\n")
    }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        let precise = Self.precise
        let a = Self.availability(); guard a.available else { throw ToolError("location is not available here: \(a.reason)") }
        let p = try await LocationStore.current.current(precise: precise)
        return Self.render(p, precise: precise)
    }
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput { ToolOutput(text: try await call(args)) }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}
