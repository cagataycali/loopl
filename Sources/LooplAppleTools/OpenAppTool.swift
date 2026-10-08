import Foundation
import Loopl
#if canImport(UIKit)
import UIKit
#endif

/// `open_app` — hand off to another app through a URL: a custom scheme
/// (`shortcuts://run-shortcut?name=…`, `maps://?q=…`, `tinyapp://…`), `tel:` / `sms:` /
/// `mailto:`, or a universal link. Context travels as `params`: a JSON object the tool
/// merges into the query string, percent-encoded, so the other app receives it as plain
/// query parameters (nested values are serialised as compact JSON).
///
/// It LEAVES loopl, so every call asks the human first through the SDK's HITL
/// (`requiresApproval`) unless the user has put the scheme on the allowlist in Settings.
public struct OpenAppTool: AppleTool {
    public init() {}
    public let name = "open_app"
    public let description = "Open another app or a link on this iPhone through a URL / deeplink (shortcuts://run-shortcut?name=…, maps://?q=…, tel:, sms:, mailto:, music://, tinyapp://, https://…). Pass context to the other app as params — a JSON object merged into the query string. Use only when the user asks to open, launch, call, text, navigate to or hand something to another app. Returns whether it opened and the final URL."
    public let parameters: JSONValue = ToolSchema.object([
        "url": ToolSchema.string("The URL or deeplink to open, e.g. shortcuts://run-shortcut?name=Log%20Water or https://loopl.dev"),
        "params": ["type": "object", "description": "Optional context for the other app: merged into the query string as key=value (strings as-is, numbers/booleans as text, nested objects as compact JSON), percent-encoded"],
        "fallback_url": ToolSchema.string("Opened instead when the first URL cannot be opened (e.g. the app is not installed) — typically an https:// link"),
    ], required: ["url"])
    public static let onDeviceCopy = "Opens another app — Maps, Mail, a website. Asks you first, unless you have allowed that kind of link."

    /// Schemes the app declares in `LSApplicationQueriesSchemes`, so `canOpenURL` can answer truthfully for them.
    public static let knownSchemes = ["shortcuts", "maps", "tel", "sms", "mailto", "music", "tinyapp", "x-callback-url", "https", "http", "facetime", "comgooglemaps", "spotify"]
    static let blockedSchemes: Set<String> = ["file", "javascript", "data", "blob", "about"]

    // MARK: allowlist (Settings › On-device Apple tools › open_app › Open without asking)

    /// UserDefaults key: schemes the user opens without an approval card. Thread-safe like `NetworkPolicy`.
    public static let allowedSchemesKey = "loopl.openApp.allowedSchemes"
    public static var allowedSchemes: [String] {
        get { (UserDefaults.standard.array(forKey: allowedSchemesKey) as? [String] ?? []).map { $0.lowercased() } }
        set { UserDefaults.standard.set(Array(Set(newValue.map { $0.lowercased() })).sorted(), forKey: allowedSchemesKey) }
    }
    public static func isAllowed(scheme: String) -> Bool { allowedSchemes.contains(scheme.lowercased()) }

    // MARK: URL building

    public struct Request: Sendable, Hashable {
        public var url: URL
        public var fallback: URL?
        public var paramCount: Int
        public var scheme: String { url.scheme?.lowercased() ?? "" }
    }

    /// Validates `url`, merges `params` into its query (percent-encoded, existing items kept) and validates `fallback_url`.
    public static func parse(_ args: [String: JSONValue]) throws -> Request {
        guard let raw = args.string("url")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { throw ToolError("need a url") }
        var params: [(String, String)] = []
        if case .object(let o)? = args["params"] {
            for k in o.keys.sorted() { params.append((k, queryText(o[k]!))) }
        }
        let url = try build(raw, params: params)
        var fallback: URL?
        if let f = args.string("fallback_url")?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty {
            fallback = try build(f, params: [])
        }
        return Request(url: url, fallback: fallback, paramCount: params.count)
    }

    static func build(_ raw: String, params: [(String, String)]) throws -> URL {
        guard var c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), isValidScheme(scheme) else {
            throw ToolError("url must start with a scheme like shortcuts://, maps://, tel:, mailto: or https://")
        }
        guard !blockedSchemes.contains(scheme) else { throw ToolError("\(scheme): URLs are not allowed") }
        if !params.isEmpty {
            var q = c.percentEncodedQuery.map { $0.isEmpty ? [] : [$0] } ?? []
            q += params.map { encode($0.0) + "=" + encode($0.1) }
            c.percentEncodedQuery = q.joined(separator: "&")
        }
        guard let url = c.url else { throw ToolError("could not build a valid url from \(raw)") }
        return url
    }

    static func isValidScheme(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    /// Strict RFC 3986 unreserved set — `&`, `=`, `+`, `/`, `?` and spaces are all escaped, so a value never splits the query.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// How a JSON value travels in a query string: strings verbatim, scalars as text, containers as compact JSON.
    static func queryText(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): s
        case .null: ""
        default: v.compact
        }
    }

    /// A readable app name for the card ("Open Shortcuts"), by scheme.
    public static func appName(for scheme: String) -> String {
        switch scheme.lowercased() {
        case "shortcuts": "Shortcuts"
        case "maps": "Maps"
        case "comgooglemaps": "Google Maps"
        case "x-callback-url": "x-callback-url"
        case "tel": "Phone"
        case "facetime": "FaceTime"
        case "sms": "Messages"
        case "mailto": "Mail"
        case "music": "Music"
        case "spotify": "Spotify"
        case "tinyapp": "tiny"
        case "https", "http": "Safari"
        default: scheme + "://"
        }
    }

    /// How a scheme is written: `tel:` / `sms:` / `mailto:` / `facetime:` take no authority, everything else `scheme://`.
    public static func schemeLabel(_ scheme: String) -> String {
        ["tel", "sms", "mailto", "facetime"].contains(scheme.lowercased()) ? "\(scheme):" : "\(scheme)://"
    }

    // MARK: availability + HITL

    public static func availability() -> ToolAvailability {
        #if canImport(UIKit) && !os(watchOS)
        return .ok
        #else
        return .no(Unavailable.noUIKit)
        #endif
    }

    /// Leaving the app is a medium-risk action: `ApprovalPolicy.mutating` (the default) asks; an allowlisted scheme does not.
    public func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
        guard let r = try? Self.parse(input) else { return nil }   // invalid input fails in `call` instead
        if Self.isAllowed(scheme: r.scheme) { return nil }
        let app = Self.appName(for: r.scheme)
        var detail = "Leaves loopl and opens \(app)"
        if r.paramCount > 0 { detail += " with \(r.paramCount) parameter\(r.paramCount == 1 ? "" : "s")" }
        if let f = r.fallback { detail += " · falls back to \(f.host ?? f.absoluteString)" }
        let target = r.url.host ?? (r.url.path.isEmpty ? r.url.absoluteString : r.url.path)
        return ApprovalRequest(toolName: name, title: "Open \(app) · \(target)", method: "OPEN", url: r.url.absoluteString,
                               detail: detail, risk: .medium, input: input)
    }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        let r = try Self.parse(args)
        let a = Self.availability()
        guard a.available else { throw ToolError("open_app is not available here: \(a.reason)") }
        #if canImport(UIKit) && !os(watchOS)
        if await Self.open(r.url) { return "opened: true\nurl: \(r.url.absoluteString)" }
        if let f = r.fallback, await Self.open(f) { return "opened: true (fallback — \(Self.appName(for: r.scheme)) could not open the first url)\nurl: \(f.absoluteString)" }
        return "opened: false — no app on this iPhone handles \(r.scheme):// (or it refused the url)\nurl: \(r.url.absoluteString)"
        #else
        throw ToolError(Unavailable.noUIKit)
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    /// `UIApplication.open` reports truthfully whether something took the URL — more honest than
    /// `canOpenURL`, which is false for any scheme missing from `LSApplicationQueriesSchemes`.
    @MainActor
    static func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { cont in
            UIApplication.shared.open(url, options: [:]) { ok in cont.resume(returning: ok) }
        }
    }
    #endif
}
