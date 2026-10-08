import Foundation

// Human-in-the-loop. Without a dedicated approval step the closest primitive is a
// `BeforeToolCallEvent` hook that cancels the tool. loopl keeps that hook as
// the policy surface and adds the missing half: the event loop can SUSPEND one
// tool call inside the actor until a human answers, while the other tools of
// the same message keep running.

/// What a tool wants a human to see before it runs. `id` is the `toolUseId`,
/// so a UI can pin the card to the tool row and the agent can resume the
/// right call. Headers arrive already redacted (see `ApprovalRequest.redact`).
public struct ApprovalRequest: Sendable, Hashable, Codable, Identifiable {
    /// How much a call could change outside the device; the approval card shows it.
    public enum Risk: String, Sendable, Codable, Hashable, Comparable {
        case low, medium, high
        public static func < (a: Risk, b: Risk) -> Bool { a.rank < b.rank }
        private var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
    }
    public var id: String
    public var toolName: String
    /// One line a card can lead with — "POST api.example.com".
    public var title: String
    public var method: String?
    public var url: String?
    public var headers: [String: String]
    public var bodyPreview: String?
    /// One sentence of context ("sends 240 bytes of JSON").
    public var detail: String?
    public var risk: Risk
    /// The input the tool would run with — editable by the human (`.approveEdited`).
    public var input: [String: JSONValue]

    public init(id: String = "", toolName: String, title: String, method: String? = nil, url: String? = nil,
                headers: [String: String] = [:], bodyPreview: String? = nil, detail: String? = nil,
                risk: Risk = .medium, input: [String: JSONValue] = [:]) {
        self.id = id; self.toolName = toolName; self.title = title; self.method = method; self.url = url
        self.headers = headers; self.bodyPreview = bodyPreview; self.detail = detail; self.risk = risk; self.input = input
    }

    /// The URL's host, for allowlists and cards.
    public var host: String? { url.flatMap(URL.init(string:))?.host }

    /// Secrets never reach a card: any header whose name smells like a credential is replaced by `•••`.
    public static func redact(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in headers {
            let key = k.lowercased()
            let secret = ["authorization", "cookie", "token", "key", "secret", "password", "session"].contains { key.contains($0) }
            out[k] = secret ? "•••" : v
        }
        return out
    }
}

/// The human's answer. `approveEdited` runs the tool with the edited input instead.
public enum ApprovalDecision: Sendable, Hashable, Codable {
    case approve
    case deny(reason: String?)
    case approveEdited([String: JSONValue])

    public var isApproved: Bool { if case .deny = self { return false }; return true }
    /// The input to run with (`nil` when denied).
    public func input(default original: [String: JSONValue]) -> [String: JSONValue]? {
        switch self {
        case .approve: original
        case .approveEdited(let edited): edited
        case .deny: nil
        }
    }
}

/// Default: tools do not need approval. A tool opts in by returning a request
/// for the inputs it considers sensitive (the `http` tool does for every call,
/// with the risk graded by method; `ApprovalPolicy` then decides which ask).
public extension Tool {
    func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? { nil }
}

/// A `BeforeToolCall` hook that turns a tool's approval request into a policy:
/// auto-approve low-risk calls (`.mutating`, the default — reads pass, writes
/// ask), ask for everything (`.always`), or never ask (`.never`). Calls to a
/// trusted host are auto-approved whatever the mode. `modeProvider` is read on
/// every call, so a settings toggle takes effect without rebuilding the agent.
public struct ApprovalPolicy: HookProvider, Sendable {
    /// When the policy stops a flagged call for a human decision.
    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// Ask before every call the tool flags.
        case always
        /// Ask only for medium/high risk (POST, PUT, PATCH, DELETE); reads run.
        case mutating
        /// Never ask — every call runs.
        case never
    }
    public let modeProvider: @Sendable () -> Mode
    public let trustedHostsProvider: @Sendable () -> [String]

    public init(mode: Mode = .mutating, trustedHosts: [String] = []) {
        self.init(modeProvider: { mode }, trustedHosts: { trustedHosts })
    }
    public init(modeProvider: @escaping @Sendable () -> Mode, trustedHosts: @escaping @Sendable () -> [String] = { [] }) {
        self.modeProvider = modeProvider; self.trustedHostsProvider = trustedHosts
    }

    public func registerHooks(_ registry: HookRegistry) {
        let mode = modeProvider, hosts = trustedHostsProvider
        registry.addCallback(BeforeToolCallEvent.self) { e in
            guard let req = e.approval else { return }
            switch mode() {
            case .never: e.approval = nil
            case .mutating: if req.risk == .low { e.approval = nil }
            case .always: break
            }
            if e.approval != nil, let host = req.host?.lowercased(),
               hosts().contains(where: { let h = $0.lowercased(); return host == h || host.hasSuffix("." + h) }) {
                e.approval = nil
            }
        }
    }
}

// MARK: - Approval as an interrupt

// An approval IS an interrupt (`Interrupt.name == "approval"`, scoped to the toolUseId):
// one suspend mechanism, one resume path, one place where a human answer arrives.
// `reason` carries the request, `response` carries the decision — both as `JSONValue`
// so interrupt state stays `Codable` for session restore.

extension ApprovalRequest {
    /// The request as an interrupt `reason`.
    public var interruptReason: JSONValue {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8),
              let value = JSONValue.parse(text) else {
            return .object(["id": .string(id), "toolName": .string(toolName), "title": .string(title)])
        }
        return value
    }

    /// Rebuild a request from an interrupt `reason` (a UI restoring pending cards).
    public init?(interruptReason: JSONValue) {
        guard let data = interruptReason.compact.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ApprovalRequest.self, from: data) else { return nil }
        self = decoded
    }

    /// `"tool:<toolUseId>:approval"` → `<toolUseId>`.
    public static func toolUseId(fromInterruptId id: String) -> String {
        let parts = id.split(separator: ":")
        guard parts.count >= 3, parts.first == "tool" else { return id }
        return parts.dropFirst().dropLast().joined(separator: ":")
    }
}

extension ApprovalDecision {
    /// The decision as an interrupt `response`.
    public var interruptResponse: JSONValue {
        switch self {
        case .approve: .object(["decision": .string("approve")])
        case .deny(let reason): .object(["decision": .string("deny"), "reason": reason.map(JSONValue.string) ?? .null])
        case .approveEdited(let input): .object(["decision": .string("approveEdited"), "input": .object(input)])
        }
    }

    /// Read a decision back out of an interrupt response.
    public init?(interruptResponse: JSONValue) {
        guard case .object(let o) = interruptResponse, case .string(let kind)? = o["decision"] else { return nil }
        switch kind {
        case "approve": self = .approve
        case "deny":
            if case .string(let r)? = o["reason"] { self = .deny(reason: r) } else { self = .deny(reason: nil) }
        case "approveEdited":
            guard case .object(let input)? = o["input"] else { return nil }
            self = .approveEdited(input)
        default: return nil
        }
    }
}
