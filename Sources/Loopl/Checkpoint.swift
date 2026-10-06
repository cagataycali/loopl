import Foundation

// Checkpoints — session managers (`session/`) reduced to the one thing
// an on-device agent needs: a snapshot it can write to disk and come back to.
// Everything in here is `Codable` and versioned; nothing depends on anything
// beyond Foundation, and nothing in the event loop had to change to support it.
//
// A snapshot taken while a tool call is suspended for human approval (HITL)
// carries the pending requests, so a relaunched app can show the same cards.

/// A versioned snapshot of an agent: the conversation, the system prompt, the
/// accumulated metrics, which model was loaded, and whatever the run was
/// waiting for when it was taken.
///
///     let snapshot = await agent.checkpoint(label: "before the long tool call")
///     try FileCheckpointStore().save(snapshot, id: "chat-1")
///     …
///     await agent.restore(try FileCheckpointStore().load("chat-1"))
public struct AgentCheckpoint: Codable, Sendable, Hashable, Identifiable {
    /// Bumped whenever the shape changes in a way an older build cannot read.
    public static let currentVersion = 1

    public var version: Int
    public var id: String
    public var createdAt: Date
    /// Free-text note from whoever took the snapshot.
    public var label: String?
    public var systemPrompt: String?
    public var messages: [Message]
    public var metrics: EventLoopMetrics
    /// Which runtime + weights produced this conversation (`mlx`, `gguf`, `appleFM`).
    public var runtime: String?
    public var modelId: String?
    /// Tool calls suspended for human approval when the snapshot was taken (HITL).
    public var pendingApprovals: [ApprovalRequest]
    /// Anything else the run was suspended on. Additive and generic on purpose:
    /// the event loop's interrupt type is being generalised in a parallel lane,
    /// and this field is where its snapshot lands without a format change.
    public var interrupt: InterruptSnapshot?
    /// Host-owned extras (which chat this is, a title, a draft) — never read by the SDK.
    public var userInfo: [String: JSONValue]

    public init(id: String = UUID().uuidString,
                createdAt: Date = Date(),
                label: String? = nil,
                systemPrompt: String? = nil,
                messages: [Message] = [],
                metrics: EventLoopMetrics = EventLoopMetrics(),
                runtime: String? = nil,
                modelId: String? = nil,
                pendingApprovals: [ApprovalRequest] = [],
                interrupt: InterruptSnapshot? = nil,
                userInfo: [String: JSONValue] = [:]) {
        self.version = Self.currentVersion
        // millisecond precision: a snapshot then round trips through JSON exactly
        self.id = id; self.createdAt = createdAt.looplMilliseconds; self.label = label
        self.systemPrompt = systemPrompt; self.messages = messages; self.metrics = metrics
        self.runtime = runtime; self.modelId = modelId
        self.pendingApprovals = pendingApprovals; self.interrupt = interrupt; self.userInfo = userInfo
    }

    /// True when a human (or a resolver) still owes this run an answer.
    public var isSuspended: Bool { !pendingApprovals.isEmpty || interrupt != nil }

    /// Tolerant decoding: every field added after v1 is optional, so a newer
    /// file still loads in an older build as long as the version matches.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.currentVersion else {
            throw CheckpointError.unsupportedVersion(found: version, supported: Self.currentVersion)
        }
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        label = try c.decodeIfPresent(String.self, forKey: .label)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        metrics = try c.decodeIfPresent(EventLoopMetrics.self, forKey: .metrics) ?? EventLoopMetrics()
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId)
        pendingApprovals = try c.decodeIfPresent([ApprovalRequest].self, forKey: .pendingApprovals) ?? []
        interrupt = try c.decodeIfPresent(InterruptSnapshot.self, forKey: .interrupt)
        userInfo = try c.decodeIfPresent([String: JSONValue].self, forKey: .userInfo) ?? [:]
    }
}

extension Date {
    /// Truncated to whole milliseconds — the precision a checkpoint file carries.
    var looplMilliseconds: Date { Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000) }
}

/// What a suspended run was waiting for. `kind` names the mechanism
/// (`"approval"`, and whatever the interrupt generalisation calls its cases),
/// `payload` carries its own state verbatim.
public struct InterruptSnapshot: Codable, Sendable, Hashable {
    public var kind: String
    public var toolUseId: String?
    public var createdAt: Date
    public var payload: JSONValue
    public init(kind: String, toolUseId: String? = nil, createdAt: Date = Date(), payload: JSONValue = .object([:])) {
        self.kind = kind; self.toolUseId = toolUseId; self.createdAt = createdAt.looplMilliseconds; self.payload = payload
    }
}

/// Why a checkpoint could not be restored.
public enum CheckpointError: LocalizedError, Sendable, Equatable {
    case unsupportedVersion(found: Int, supported: Int)
    case notFound(String)
    case corrupt(String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let found, let supported):
            return "this checkpoint was written by a newer loopl (format v\(found), this build reads v\(supported))"
        case .notFound(let id): return "no checkpoint named \"\(id)\""
        case .corrupt(let id, let reason): return "checkpoint \"\(id)\" could not be read: \(reason)"
        }
    }
}

// MARK: - JSON

public extension AgentCheckpoint {
    /// ISO-8601 with fractional seconds, sorted keys: a checkpoint round trips
    /// byte-for-byte and diffs cleanly in a repo.
    static var jsonEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .formatted(iso8601)
        return e
    }
    static var jsonDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .formatted(iso8601)
        return d
    }
    private static var iso8601: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }

    func jsonData() throws -> Data { try Self.jsonEncoder.encode(self) }
    init(jsonData: Data) throws { self = try Self.jsonDecoder.decode(AgentCheckpoint.self, from: jsonData) }
}

// MARK: - Agent integration

public extension Agent {
    /// Snapshot everything needed to come back to this conversation.
    func checkpoint(id: String = UUID().uuidString,
                    label: String? = nil,
                    userInfo: [String: JSONValue] = [:]) async -> AgentCheckpoint {
        AgentCheckpoint(id: id,
                        label: label,
                        systemPrompt: systemPrompt,
                        messages: messages,
                        metrics: eventLoopMetrics,
                        runtime: model.kind.rawValue,
                        modelId: await model.loadedModelId,
                        pendingApprovals: pendingApprovals,
                        interrupt: Self.interruptSnapshot(for: pendingApprovals),
                        userInfo: userInfo)
    }

    /// Pending approvals are also summarised in `interrupt`, so a host has one
    /// field to check whatever suspended the run.
    internal static func interruptSnapshot(for approvals: [ApprovalRequest]) -> InterruptSnapshot? {
        guard let first = approvals.first else { return nil }
        return InterruptSnapshot(kind: "approval",
                                 toolUseId: first.id,
                                 payload: .object(["toolUseIds": .array(approvals.map { .string($0.id) }),
                                                   "toolNames": .array(approvals.map { .string($0.toolName) })]))
    }

    /// Put the conversation, the system prompt and the metrics back. Tools, the
    /// model and the hooks belong to the host — rebuild the agent with the same
    /// ones and the run continues where it stopped.
    ///
    /// Suspended work is NOT resumed: a restored checkpoint whose
    /// `pendingApprovals` are non-empty means "ask the human again" — call the
    /// agent once more and the tool call is re-made (the model's tool-use
    /// message is still the last message, which the loop picks up by design).
    func restore(_ checkpoint: AgentCheckpoint, restoreSystemPrompt: Bool = true) {
        setMessages(checkpoint.messages)
        if restoreSystemPrompt { setSystemPrompt(checkpoint.systemPrompt) }
        setEventLoopMetrics(checkpoint.metrics)
    }
}

// MARK: - Storage

/// Where checkpoints live. The SDK ships a file store; a host with its own
/// database conforms this to it.
public protocol CheckpointStore: Sendable {
    func save(_ checkpoint: AgentCheckpoint, id: String?) throws
    func load(_ id: String) throws -> AgentCheckpoint
    func list() throws -> [CheckpointSummary]
    func delete(_ id: String) throws
}

/// One line per stored checkpoint, cheap enough for a history list.
public struct CheckpointSummary: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var createdAt: Date
    public var label: String?
    public var messageCount: Int
    public var isSuspended: Bool
    public var modelId: String?
    public init(id: String, createdAt: Date, label: String?, messageCount: Int, isSuspended: Bool, modelId: String?) {
        self.id = id; self.createdAt = createdAt; self.label = label
        self.messageCount = messageCount; self.isSuspended = isSuspended; self.modelId = modelId
    }
}

/// One JSON file per checkpoint, written atomically. Default directory:
/// `…/Application Support/loopl/checkpoints` (or the app group the host passes).
public struct FileCheckpointStore: CheckpointStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("loopl/checkpoints", isDirectory: true)
        }
    }


    private func url(_ id: String) -> URL {
        directory.appendingPathComponent(Self.safe(id) + ".json")
    }
    /// A file name that survives any id a host invents.
    static func safe(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = String(id.map { allowed.contains($0) ? $0 : "-" })
        return mapped.isEmpty ? "checkpoint" : String(mapped.prefix(120))
    }

    public func save(_ checkpoint: AgentCheckpoint, id: String? = nil) throws {
        var snapshot = checkpoint
        if let id { snapshot.id = id }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try snapshot.jsonData()
        try data.write(to: url(snapshot.id), options: .atomic)
    }

    public func load(_ id: String) throws -> AgentCheckpoint {
        let file = url(id)
        guard let data = FileManager.default.contents(atPath: file.path) else { throw CheckpointError.notFound(id) }
        do {
            return try AgentCheckpoint(jsonData: data)
        } catch let error as CheckpointError {
            throw error
        } catch {
            throw CheckpointError.corrupt(id, reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    public func list() throws -> [CheckpointSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = FileManager.default.contents(atPath: file.path),
                  let c = try? AgentCheckpoint(jsonData: data) else { return nil }
            return CheckpointSummary(id: c.id, createdAt: c.createdAt, label: c.label,
                                     messageCount: c.messages.count, isSuspended: c.isSuspended, modelId: c.modelId)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ id: String) throws {
        try? FileManager.default.removeItem(at: url(id))
    }
}

public extension CheckpointStore {
    func save(_ checkpoint: AgentCheckpoint) throws { try save(checkpoint, id: nil) }
}
