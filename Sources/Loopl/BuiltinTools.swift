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

/// `http` — the one network tool: GET/HEAD/POST/PUT/PATCH/DELETE with headers,
/// a body and a timeout. Every call is flagged for human approval, graded by
/// method (reads low, writes medium, DELETE high); `ApprovalPolicy` decides
/// which actually ask. Refused outright while offline mode is on. Responses are
/// capped (`maxBytes` read, `maxChars` returned) so one page cannot flood the
/// context. Redirects are followed by the system; only https (or http to the
/// loopback host, for tests) is allowed.
public struct HttpTool: Tool {
    public let maxBytes: Int
    public let maxChars: Int
    public let maxTimeout: TimeInterval
    public init(maxBytes: Int = 256_000, maxChars: Int = 8000, maxTimeout: TimeInterval = 60) {
        self.maxBytes = maxBytes; self.maxChars = maxChars; self.maxTimeout = maxTimeout
    }
    public let name = "http"
    public let description = "Make an HTTPS request. `url` is required — pass the full https URL as the `url` argument, e.g. {\"url\": \"https://example.com\"}. Optional: method GET/HEAD/POST/PUT/PATCH/DELETE (default GET), headers object, body (string or JSON object), timeout seconds. Returns status, content-type and the body text (truncated). Writes may ask the user for approval. Unavailable in offline mode."
    public let parameters: JSONValue = [
        "type": "object",
        "properties": [
            "method": ["type": "string", "enum": ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"], "description": "HTTP method, default GET"],
            "url": ["type": "string", "description": "full https URL, required", "examples": ["https://example.com"]],
            "headers": ["type": "object", "description": "request headers, e.g. {\"Accept\": \"application/json\"}"],
            "body": ["type": "string", "description": "request body — a string, or a JSON object which is sent as application/json"],
            "timeout": ["type": "number", "description": "seconds, default 20, max 60"],
        ],
        "required": ["url"],
    ]

    public static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    /// Parsed, validated arguments — shared by `call` and `requiresApproval` so the card shows exactly what will run.
    public struct Request: Sendable, Hashable {
        public var method: String
        public var url: URL
        public var headers: [String: String]
        public var body: Data?
        public var timeout: TimeInterval
        public var bodyText: String? { body.map { String(decoding: $0.prefix(2000), as: UTF8.self) } }
        public var isMutating: Bool { method != "GET" && method != "HEAD" }
        public var risk: ApprovalRequest.Risk { method == "DELETE" ? .high : isMutating ? .medium : .low }
    }

    public static func parse(_ args: [String: JSONValue], maxTimeout: TimeInterval = 60) throws -> Request {
        guard var raw = args["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw ToolError("need a url — pass it as the `url` argument, e.g. {\"url\": \"https://example.com\"}")
        }
        // `httpbin.org/delete` (Qwen3-0.6B, 2026-10-06): a host without a scheme means https.
        if !raw.contains("://"), let first = raw.first, first.isLetter || first.isNumber, raw.split(separator: "/").first?.contains(".") == true {
            raw = "https://" + raw
        }
        guard let url = URL(string: raw), let host = url.host else {
            throw ToolError("need a valid url, got \(raw) — e.g. {\"url\": \"https://example.com\"}")
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard url.scheme == "https" || (url.scheme == "http" && loopback) else { throw ToolError("only https urls are allowed") }
        let method = (args["method"]?.stringValue ?? "GET").uppercased()
        guard methods.contains(method) else { throw ToolError("unsupported method \(method) — use GET, HEAD, POST, PUT, PATCH or DELETE") }
        var headers: [String: String] = [:]
        if case .object(let h)? = args["headers"] { for (k, v) in h { headers[k] = v.stringValue ?? v.compact } }
        var body: Data?
        var jsonBody = false
        switch args["body"] {
        case .string(let s)?: body = s.data(using: .utf8)
        case .object(let o)?: body = JSONValue.object(o).compact.data(using: .utf8); jsonBody = true
        case .array(let a)?: body = JSONValue.array(a).compact.data(using: .utf8); jsonBody = true
        case nil, .null?: body = nil
        case let other?: body = other.compact.data(using: .utf8)
        }
        if jsonBody, !headers.keys.contains(where: { $0.lowercased() == "content-type" }) { headers["Content-Type"] = "application/json" }
        if body != nil, !["POST", "PUT", "PATCH", "DELETE"].contains(method) { body = nil }
        let timeout = min(max(args["timeout"]?.doubleValue ?? 20, 1), maxTimeout)
        return Request(method: method, url: url, headers: headers, body: body, timeout: timeout)
    }

    public func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
        guard let r = try? Self.parse(input, maxTimeout: maxTimeout) else { return nil }   // invalid input fails in `call` instead
        let host = r.url.host ?? r.url.absoluteString
        var detail = r.isMutating ? "Sends a \(r.method) request" : "Reads"
        if let b = r.body { detail += " · \(ByteCountFormatter.string(fromByteCount: Int64(b.count), countStyle: .file)) body" }
        if !r.headers.isEmpty { detail += " · \(r.headers.count) header\(r.headers.count == 1 ? "" : "s")" }
        return ApprovalRequest(toolName: name, title: "\(r.method) \(host)", method: r.method, url: r.url.absoluteString,
                               headers: ApprovalRequest.redact(r.headers), bodyPreview: r.bodyText, detail: detail, risk: r.risk, input: input)
    }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        let r = try Self.parse(args, maxTimeout: maxTimeout)
        if NetworkPolicy.isOffline { throw ToolError("offline mode is on — network refused") }
        var req = URLRequest(url: r.url, timeoutInterval: r.timeout)
        req.httpMethod = r.method
        req.setValue("loopl/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = r.body
        let (data, resp) = try await NetworkPolicy.session.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first.map(String.init) ?? ""
        if code >= 400 {
            // A 4xx/5xx is a FAILED request as far as the model is concerned. Measured on Qwen3.5-0.8B: a 405
            // rendered as a success result ("HTTP 405 text/html\n<!DOCTYPE HTML…") was re-issued verbatim 7 times;
            // the model needs the failure named first and the fix spelled out. The body still travels (capped).
            var line = "HTTP \(code) \(HTTPURLResponse.localizedString(forStatusCode: code)) for \(r.method) \(r.url.absoluteString)."
            switch code {
            case 404: line += " The path does not exist on this server — check the URL."
            case 405: line += " The server does not allow \(r.method) here — use GET (or the method the API documents)."
            case 401, 403: line += " The server refused access — this URL needs credentials the tool does not have."
            case 429: line += " Rate limited — do not retry immediately."
            case 500...: line += " Server-side failure — retrying the same request is unlikely to help."
            default: break
            }
            let body = String(decoding: data.prefix(2_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { line += " Response body: " + String(body.prefix(600)) + (body.count > 600 ? "…" : "") }
            throw ToolError(line)
        }
        var head = "HTTP \(code)"
        if !type.isEmpty { head += " \(type)" }
        if let loc = http?.value(forHTTPHeaderField: "Location") { head += "\nLocation: \(loc)" }
        if r.method == "HEAD" || data.isEmpty { return head + "\n(\(data.count) bytes)" }
        let capped = data.prefix(maxBytes)
        var body = String(decoding: capped, as: UTF8.self)
        var truncated = data.count > maxBytes
        if body.count > maxChars { body = String(body.prefix(maxChars)); truncated = true }
        if truncated { body += "\n… [truncated: \(data.count) bytes total]" }
        return head + "\n" + body
    }
}

/// 0.1 tool. Kept one release as an alias of `http` with method GET; use `HttpTool`.
@available(*, deprecated, message: "use HttpTool (`http`) — http_get is kept one release as an alias")
public struct HttpGetTool: Tool {
    public init() {}
    public let name = "http_get"
    public let description = "Deprecated alias of http: fetch a URL with GET and return the body text. Unavailable in offline mode."
    public let parameters: JSONValue = ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]
    public func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
        HttpTool(maxChars: 4000).requiresApproval(for: ["url": input["url"] ?? .null, "method": "GET"])
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        try await HttpTool(maxChars: 4000).call(["url": args["url"] ?? .null, "method": "GET"])
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
