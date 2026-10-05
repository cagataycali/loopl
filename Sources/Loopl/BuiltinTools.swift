import Foundation

public struct CurrentTimeTool: Tool {
    public init() {}
    public let name = "current_time"
    public let description = "Get the current date and time. Optional IANA timezone such as Europe/Istanbul or America/Los_Angeles; defaults to the device timezone."
    public let parameters: JSONValue = ["type": "object", "properties": ["timezone": ["type": "string", "description": "IANA timezone id"]], "required": []]
    public func call(_ args: [String: JSONValue]) async throws -> String {
        let tzName = args["timezone"]?.stringValue ?? args["location"]?.stringValue
        var tz = TimeZone.current
        if let tzName, !tzName.isEmpty {
            guard let t = TimeZone(identifier: tzName) ?? Self.lookup(tzName) else { throw ToolError("unknown timezone '\(tzName)' — use an IANA id like Europe/Istanbul") }
            tz = t
        }
        let f = DateFormatter()
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM yyyy HH:mm:ss zzz"
        return "\(f.string(from: Date())) (\(tz.identifier))"
    }
    /// "Istanbul" → Europe/Istanbul: cheap city-name matching so the model may pass a city.
    static func lookup(_ name: String) -> TimeZone? {
        let needle = name.lowercased().replacingOccurrences(of: " ", with: "_")
        return TimeZone.knownTimeZoneIdentifiers.first { $0.lowercased().hasSuffix("/" + needle) }.flatMap(TimeZone.init(identifier:))
    }
}

public struct CalculatorTool: Tool {
    public init() {}
    public let name = "calculator"
    public let description = "Evaluate an arithmetic expression exactly. Supports + - * / % ^ parentheses, sqrt abs round floor ceil sin cos tan ln log exp pow min max, pi and e."
    public let parameters: JSONValue = ["type": "object", "properties": ["expression": ["type": "string", "description": "e.g. 23*47 or sqrt(2)^2"]], "required": ["expression"]]
    public func call(_ args: [String: JSONValue]) async throws -> String {
        guard let expr = args["expression"]?.stringValue ?? args["input"]?.stringValue ?? args["query"]?.stringValue else { throw ToolError("missing 'expression'") }
        let v = try Calculator.evaluate(expr)
        return "\(expr) = \(Calculator.format(v))"
    }
}

/// Notes in UserDefaults — `remember` writes, `recall` reads (all or by key).
public struct RememberTool: Tool {
    public init() {}
    public let name = "remember"
    public let description = "Store a short note under a key so it can be recalled later in this app."
    public let parameters: JSONValue = ["type": "object", "properties": ["key": ["type": "string"], "value": ["type": "string"]], "required": ["key", "value"]]
    public func call(_ args: [String: JSONValue]) async throws -> String {
        guard let key = args["key"]?.stringValue, let value = args["value"]?.stringValue ?? args["value"].map(\.compact) else { throw ToolError("need key and value") }
        var notes = NotesStore.all()
        notes[key] = value
        NotesStore.save(notes)
        return "remembered \(key)"
    }
}

public struct RecallTool: Tool {
    public init() {}
    public let name = "recall"
    public let description = "Read notes stored with remember. Pass a key, or omit it to list everything."
    public let parameters: JSONValue = ["type": "object", "properties": ["key": ["type": "string"]], "required": []]
    public func call(_ args: [String: JSONValue]) async throws -> String {
        let notes = NotesStore.all()
        if let key = args["key"]?.stringValue, !key.isEmpty { return notes[key].map { "\(key): \($0)" } ?? "nothing stored under '\(key)'" }
        guard !notes.isEmpty else { return "no notes stored" }
        return notes.keys.sorted().map { "\($0): \(notes[$0]!)" }.joined(separator: "\n")
    }
}

public enum NotesStore {
    static let key = "loopl.notes"
    public static func all() -> [String: String] { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
    public static func save(_ n: [String: String]) { UserDefaults.standard.set(n, forKey: key) }
}

/// Network access — refused outright when the offline toggle is on, so the
/// agent proves the "no network while offline" rule through its own tools.
public struct HttpGetTool: Tool {
    public init() {}
    public let name = "http_get"
    public let description = "Fetch a URL over HTTPS and return the first 4000 characters of the body. Unavailable in offline mode."
    public let parameters: JSONValue = ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]
    public func call(_ args: [String: JSONValue]) async throws -> String {
        guard let raw = args["url"]?.stringValue, let url = URL(string: raw), url.scheme == "https" else { throw ToolError("need an https url") }
        if NetworkPolicy.isOffline { throw ToolError("offline mode is on — network refused") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("loopl/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await NetworkPolicy.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data.prefix(16_000), as: UTF8.self)
        return "HTTP \(code)\n" + String(body.prefix(4000))
    }
}

/// The single switch every network path consults. UserDefaults is
/// thread-safe, so the pure tools can read it without hopping actors.
public enum NetworkPolicy {
    public static let offlineKey = "loopl.offline"
    public static var isOffline: Bool { UserDefaults.standard.bool(forKey: offlineKey) }
    public static func setOffline(_ v: Bool) { UserDefaults.standard.set(v, forKey: offlineKey) }
    /// Shared session used by every downloader/tool so the whole app can be
    /// audited for network use in one place.
    public static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = false
        c.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: c)
    }()
}
