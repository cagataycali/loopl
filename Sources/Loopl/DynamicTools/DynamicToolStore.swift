import Foundation

/// Where agent-written tools live and how they come back: `<dir>/<name>.swift|js` + `<dir>/<name>.json`.
/// Default dir: Application Support/loopl/tools (iOS: inside the app container; macOS: ~/Library/Application Support/loopl/tools).
///
/// The store is the SEAM other lanes plug into: `tools` is what the Engine appends to the model's tool list, `onChange`
/// fires after every create/remove/reload so the live Agent can `setTools` before its next model call (P6-A's
/// ToolRegistry replaces this with `register(tool, source: .agent)` — same calls, one place).
public actor DynamicToolStore {
    public static let shared = DynamicToolStore()

    public struct CreateResult: Sendable, Hashable {
        public var record: DynamicToolRecord
        /// One paragraph for the model: what happened and what it can do now.
        public var message: String
        public var live: Bool { record.status.isActive }
    }

    public struct CreateError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public let directory: URL
    public private(set) var records: [DynamicToolRecord] = []
    private var live: [String: any Tool] = [:]
    /// AWAITED after the set of live tools changed — `create` does not return (so the tool result does not reach the model)
    /// until the host has handed the running Agent its new tool list. MEASURED with loopl-2b: a fire-and-forget Task here
    /// lost the race with the agent's next request in 4/4 runs — the model created `reverse_string`, was never offered it, and
    /// reached for `calculator("loopl".reversed())` instead.
    private var observers: [@Sendable ([any Tool]) async -> Void] = []
    /// Builtin names the agent may not shadow — the host sets this (Engine: every tool it offers).
    public private(set) var reserved: Set<String> = []

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("loopl/tools", isDirectory: true)
    }
    var buildDirectory: URL { directory.appendingPathComponent(".build", isDirectory: true) }

    /// The tools that run here right now, in creation order.
    public var tools: [any Tool] { records.filter(\.status.isActive).compactMap { live[$0.name] } }

    public func setReserved(_ names: [String]) { reserved = Set(names.map(DynamicToolName.key)) }
    public func onChange(_ f: @escaping @Sendable ([any Tool]) async -> Void) { observers.append(f) }
    private func notify() async { let t = tools; for o in observers { await o(t) } }

    public func source(of name: String) -> String? {
        guard let r = records.first(where: { $0.name == name }) else { return nil }
        return try? String(contentsOf: sourceURL(r), encoding: .utf8)
    }
    public func record(named name: String) -> DynamicToolRecord? { records.first { $0.name == name } }

    // MARK: - P6-A `ToolCreator` shape (string languages) — `extension DynamicToolStore: ToolCreator {}` once A's registry is on main.

    /// Languages this device can load — `["swift", "javascript"]` on a Mac, `["javascript"]` on iPhone/iPad.
    public nonisolated var languages: [String] { DynamicToolLanguage.runnableHere.map(\.rawValue) }

    /// Validate + build + persist; returns the live tool for the registry to register. Throws `ToolError` with the
    /// compiler's/validator's words. A language this device cannot run throws too — the registry refuses earlier,
    /// `manage_tools create` (fallback) saves it honestly instead.
    public func create(name: String, source: String, language: String) async throws -> any Tool {
        guard let lang = DynamicToolLanguage(rawValue: language.lowercased()) else { throw ToolError("language must be swift or javascript") }
        let result: CreateResult
        do { result = try await create(name: name.isEmpty ? nil : name, source: source, language: lang) }
        catch let e as CreateError { throw ToolError(e.message) }
        catch let e as JSToolError { throw ToolError("JavaScript: \(e.message)") }
        catch {
            #if os(macOS)
            if let e = error as? SwiftToolCompiler.Failure { throw ToolError("Swift \(e.stage.rawValue) error:\n\(e.message)") }
            #endif
            throw error
        }
        guard result.live, let tool = live[result.record.name] else { throw ToolError(result.message) }
        return tool
    }

    /// `ToolCreator.remove`: delete the persisted source (the registry unregisters first).
    public func remove(name: String) async throws { _ = try await remove(name: name) as String }

    /// Created tools saved on this device, restored at launch by the host.
    public func saved() async -> [(name: String, language: String)] { records.map { ($0.name, $0.language.rawValue) } }

    // MARK: - create / remove / reload

    /// `manage_tools create`. Validates, saves, loads (when this device can), tells the model what happened.
    public func create(name requested: String?, source: String, language requestedLanguage: DynamicToolLanguage?) async throws -> CreateResult {
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else { throw CreateError(message: "create needs `source` — the tool's code. On this device write \(DynamicToolLanguage.preferredHere == .swift ? "Swift" : "JavaScript"):\n\(DynamicToolShape.text(for: .preferredHere))") }
        guard let language = requestedLanguage ?? DynamicToolLanguage.infer(from: src) else {
            throw CreateError(message: "could not tell whether this is Swift or JavaScript — pass `language` and use one of the two shapes.\nSwift (Mac):\n\(DynamicToolShape.swift)\nJavaScript (iPhone/iPad/Mac):\n\(DynamicToolShape.javascript)")
        }
        if let requested, !DynamicToolName.isValid(requested) { throw CreateError(message: "invalid tool name \"\(requested)\" — 1-64 chars, letters/digits/_/-") }

        // Shape-check the source enough to know its NAME even when we cannot run it here (Swift on iPhone).
        let staticName = try staticName(in: src, language: language)
        let name = requested ?? staticName
        if let requested, let staticName, requested != staticName {
            throw CreateError(message: "the code defines \"\(staticName)\" but name=\"\(requested)\" was requested — they must match (the file is named after the tool)")
        }
        guard let name, DynamicToolName.isValid(name) else {
            throw CreateError(message: "could not find the tool's name in the code — set `name` to 1-64 chars of letters/digits/_/- (and pass it as the `name` argument)")
        }
        if reserved.contains(DynamicToolName.key(name)) { throw CreateError(message: "\"\(name)\" is a built-in tool name — pick another") }
        if let existing = records.first(where: { DynamicToolName.key($0.name) == DynamicToolName.key(name) }) {
            let hint = existing.status.isActive ? "and is LIVE in your tool list — call `\(existing.name)` directly instead of creating it again" : "— remove it first (manage_tools remove name=\(existing.name)) or pick another name"
            throw CreateError(message: "a tool named \"\(existing.name)\" already exists \(hint)")
        }

        var record = DynamicToolRecord(name: name, language: language, description: "", status: .saved(reason: ""))
        if language.runnableHere {
            let loaded = try await load(source: src, record: record)   // throws with the compiler's/engine's words
            record.description = loaded.description
            record.status = .active
            try persist(record: record, source: lastBuiltSource ?? src)
            live[name] = loaded
            records.append(record)
            await notify()
            let where_ = language == .swift ? "compiled and loaded" : "loaded in JavaScriptCore"
            let repaired = lastRepairNotes.isEmpty ? "" : " (I \(lastRepairNotes.joined(separator: "; ")) before compiling — saved that way.)"
            // Action-oriented on purpose (MEASURED: after "✅ … call it NOW" loopl-2b called `create` three more times): say the next step.
            return CreateResult(record: record, message: "✅ \(name) (\(language.rawValue)) \(where_) and is in your tool list.\(repaired) NEXT STEP: call `\(name)` itself with its arguments — do not call manage_tools create again. It stays available after relaunch.")
        } else {
            // Honest result, never a silent drop: Swift source written on an iPhone/iPad is kept for a Mac.
            let reason = "Swift cannot be compiled on \(Self.deviceWord) — saved; it runs on your Mac (same loopl account) or in a build that bundles it. Rewrite it in JavaScript to use it here now."
            record.description = (try? SwiftToolSourceScan.description(in: src)) ?? ""
            record.status = .saved(reason: reason)
            try persist(record: record, source: src)
            records.append(record)
            return CreateResult(record: record, message: "💾 \(name) saved, NOT loaded: \(reason)\nJavaScript shape:\n\(DynamicToolShape.javascript)")
        }
    }

    /// `manage_tools remove`. Deletes the source and metadata; the tool leaves the model's list on the next call.
    public func remove(name: String) async throws -> String {
        guard let idx = records.firstIndex(where: { DynamicToolName.key($0.name) == DynamicToolName.key(name) }) else {
            throw CreateError(message: "no agent-written tool named \"\(name)\"\(records.isEmpty ? "" : " — have: \(records.map(\.name).joined(separator: ", "))")")
        }
        let r = records.remove(at: idx)
        live[r.name] = nil
        try? FileManager.default.removeItem(at: sourceURL(r))
        try? FileManager.default.removeItem(at: metaURL(r))
        #if os(macOS)
        try? FileManager.default.removeItem(at: buildDirectory.appendingPathComponent("\(r.name).dylib"))
        try? FileManager.default.removeItem(at: buildDirectory.appendingPathComponent("\(r.name).build"))
        #endif
        await notify()
        return "🗑 removed \"\(r.name)\" (\(r.language.rawValue)) — source deleted; it is gone from the tool list from the next call on"
    }

    /// Re-read the folder at launch (and on demand): every saved tool is loaded again from its source.
    /// A file that fails to load keeps its record with `.failed(error)` — the person sees why in Settings, the other tools still load.
    @discardableResult
    public func reload() async -> [DynamicToolRecord] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var out: [DynamicToolRecord] = []
        var newLive: [String: any Tool] = [:]
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !file.lastPathComponent.hasPrefix(".") {
            guard let language = DynamicToolLanguage.allCases.first(where: { $0.fileExtension == file.pathExtension }) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            guard DynamicToolName.isValid(name), let src = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var record = (try? JSONDecoder().decode(DynamicToolRecord.self, from: Data(contentsOf: metaURL(name: name))))
                ?? DynamicToolRecord(name: name, language: language, description: "", author: "file", status: .saved(reason: ""))
            record.language = language
            if reserved.contains(DynamicToolName.key(name)) {
                record.status = .failed(error: "\"\(name)\" is a built-in tool name — the built-in wins")
            } else if language.runnableHere {
                do {
                    let tool = try await load(source: src, record: record)
                    newLive[name] = tool; record.description = tool.description; record.status = .active
                } catch {
                    record.status = .failed(error: "\(error)".prefix(2000).description)
                }
            } else if case .saved = record.status {} else {
                record.status = .saved(reason: "Swift tools run on a Mac; this one is kept for it")
            }
            try? persist(record: record, source: nil)
            out.append(record)
        }
        records = out.sorted { $0.createdAt < $1.createdAt }
        live = newLive
        await notify()
        return records
    }

    // MARK: - internals

    /// What the Swift compiler step changed in the last successful `load` (empty when compiled as written).
    private var lastRepairNotes: [String] = []
    /// The source that actually compiled (repaired when `lastRepairNotes` is non-empty) — what gets persisted.
    private var lastBuiltSource: String?

    private func load(source: String, record: DynamicToolRecord) async throws -> any Tool {
        lastRepairNotes = []; lastBuiltSource = nil
        switch record.language {
        case .javascript:
            return try JSTool(source: source, bridge: JSToolRuntime.bridge)
        case .swift:
            #if os(macOS)
            let buildDir = buildDirectory
            let name = record.name
            let repairNotes = Locked<[String]>([]); let builtSource = Locked<String>(source)
            // swiftc + probe are blocking subprocesses: keep them off the actor.
            let tool: any Tool = try await Task.detached(priority: .userInitiated) {
                let (dylib, repairs, built) = try SwiftToolCompiler.compileRepairing(source: source, name: name, buildDir: buildDir)
                let spec = try SwiftToolCompiler.probe(dylib: dylib, buildDir: buildDir)
                repairNotes.value = repairs.map(\.note); builtSource.value = built
                guard spec.name == name else {
                    throw CreateError(message: "the tool calls itself \"\(spec.name)\" but the file/name is \"\(name)\" — make them match")
                }
                guard DynamicToolName.isValid(spec.name), !spec.description.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw CreateError(message: "name must be 1-64 chars of letters/digits/_/- and description must not be empty")
                }
                return try SwiftToolCompiler.load(dylib: dylib, spec: spec) as any Tool
            }.value
            lastRepairNotes = repairNotes.value; lastBuiltSource = builtSource.value
            return tool
            #else
            throw CreateError(message: "Swift tools cannot run on \(Self.deviceWord)")
            #endif
        }
    }

    /// The name the code declares, read WITHOUT running it (so Swift on iPhone still gets filed under the right name).
    private func staticName(in source: String, language: DynamicToolLanguage) throws -> String? {
        switch language {
        case .swift:
            #if os(macOS)
            _ = try SwiftToolCompiler.toolTypeName(in: source)   // the shape error, early and verbatim
            #else
            _ = try SwiftToolSourceScan.toolTypeName(in: source)
            #endif
            return SwiftToolSourceScan.name(in: source)
        case .javascript:
            return try JSToolRuntime.spec(of: source, bridge: .none).name
        }
    }

    private func sourceURL(_ r: DynamicToolRecord) -> URL { directory.appendingPathComponent("\(r.name).\(r.language.fileExtension)") }
    private func metaURL(_ r: DynamicToolRecord) -> URL { metaURL(name: r.name) }
    private func metaURL(name: String) -> URL { directory.appendingPathComponent("\(name).json") }

    private func persist(record: DynamicToolRecord, source: String?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let source { try source.write(to: sourceURL(record), atomically: true, encoding: .utf8) }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(record).write(to: metaURL(record), options: .atomic)
    }

    static var deviceWord: String {
        #if os(iOS)
        return "an iPhone or iPad"
        #else
        return "this device"
        #endif
    }
}

/// Reads a Swift tool's `name`/`description` literals and type name without compiling — all an iPhone can do with Swift.
public enum SwiftToolSourceScan {
    public static func toolTypeName(in source: String) throws -> String {
        let re = try NSRegularExpression(pattern: #"(?:struct|final\s+class|class)\s+(\w+)\s*:\s*(?:[\w\.]+\s*,\s*)*Tool\b"#)
        let ns = source as NSString
        guard let m = re.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else {
            throw DynamicToolStore.CreateError(message: "no `struct <Name>: Tool` found. Swift shape:\n\(DynamicToolShape.swift)")
        }
        return ns.substring(with: m.range(at: 1))
    }
    public static func name(in source: String) -> String? { literal("name", in: source) }
    public static func description(in source: String) throws -> String { literal("description", in: source) ?? "" }
    static func literal(_ field: String, in source: String) -> String? {
        let re = try? NSRegularExpression(pattern: #"(?:let|var)\s+"# + field + #"\s*(?::\s*String)?\s*=\s*"((?:[^"\\]|\\.)*)""#)
        let ns = source as NSString
        guard let m = re?.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
