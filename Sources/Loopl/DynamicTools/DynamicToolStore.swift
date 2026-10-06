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
    /// Called (off the actor) after the set of live tools changed.
    private var observers: [@Sendable ([any Tool]) -> Void] = []
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
    public func onChange(_ f: @escaping @Sendable ([any Tool]) -> Void) { observers.append(f) }
    private func notify() { let t = tools; for o in observers { o(t) } }

    public func source(of name: String) -> String? {
        guard let r = records.first(where: { $0.name == name }) else { return nil }
        return try? String(contentsOf: sourceURL(r), encoding: .utf8)
    }
    public func record(named name: String) -> DynamicToolRecord? { records.first { $0.name == name } }

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
            throw CreateError(message: "a tool named \"\(existing.name)\" already exists — remove it first (manage_tools remove name=\(existing.name)) or pick another name")
        }

        var record = DynamicToolRecord(name: name, language: language, description: "", status: .saved(reason: ""))
        if language.runnableHere {
            let loaded = try await load(source: src, record: record)   // throws with the compiler's/engine's words
            record.description = loaded.description
            record.status = .active
            try persist(record: record, source: src)
            live[name] = loaded
            records.append(record)
            notify()
            let where_ = language == .swift ? "compiled and loaded" : "loaded in JavaScriptCore"
            return CreateResult(record: record, message: "✅ \(name) (\(language.rawValue)) \(where_) — call it NOW and after relaunch. Saved at \(sourceURL(record).lastPathComponent).")
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
    public func remove(name: String) throws -> String {
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
        notify()
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
        notify()
        return records
    }

    // MARK: - internals

    private func load(source: String, record: DynamicToolRecord) async throws -> any Tool {
        switch record.language {
        case .javascript:
            return try JSTool(source: source, bridge: JSToolRuntime.bridge)
        case .swift:
            #if os(macOS)
            let buildDir = buildDirectory
            let name = record.name
            // swiftc + probe are blocking subprocesses: keep them off the actor.
            return try await Task.detached(priority: .userInitiated) {
                let dylib = try SwiftToolCompiler.compile(source: source, name: name, buildDir: buildDir)
                let spec = try SwiftToolCompiler.probe(dylib: dylib, buildDir: buildDir)
                guard spec.name == name else {
                    throw CreateError(message: "the tool calls itself \"\(spec.name)\" but the file/name is \"\(name)\" — make them match")
                }
                guard DynamicToolName.isValid(spec.name), !spec.description.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw CreateError(message: "name must be 1-64 chars of letters/digits/_/- and description must not be empty")
                }
                return try SwiftToolCompiler.load(dylib: dylib, spec: spec) as any Tool
            }.value
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
