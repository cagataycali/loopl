import Foundation

// Agent-written tools (Phase 6, lane D). The model writes the code, `manage_tools create` validates it,
// the tool is live on the NEXT model call and comes back after a relaunch. Two languages:
//
//   - Swift — compiled with `swiftc -emit-library` against a tiny C-ABI shim, probed in a subprocess,
//     then dlopen'd. Needs a toolchain → macOS only. (`SwiftToolCompiler.swift`)
//   - JavaScript — run in JavaScriptCore with a small `loopl` bridge. Works on iPhone, iPad and Mac;
//     App Store Review 2.5.2 permits exactly this (scripts in JavaScriptCore), and nothing else that
//     executes code. (`JSTool.swift`)
//
// HARD FACT the design rests on: iOS cannot compile or dlopen code at runtime — no toolchain ships,
// and the kernel refuses unsigned pages. Swift written on an iPhone is therefore SAVED and answered
// honestly ("saved; runs on your Mac / next build"), never silently dropped.

/// The language of an agent-written tool.
public enum DynamicToolLanguage: String, Sendable, Codable, CaseIterable {
    case swift, javascript

    public var fileExtension: String { self == .swift ? "swift" : "js" }

    /// Which language this device can RUN right now.
    public static var runnableHere: [DynamicToolLanguage] {
        #if os(macOS)
        return [.swift, .javascript]
        #else
        return [.javascript]
        #endif
    }
    /// The language the system prompt should steer the model to on this device.
    public static var preferredHere: DynamicToolLanguage { runnableHere.first ?? .javascript }
    public var runnableHere: Bool { Self.runnableHere.contains(self) }

    /// Guess from the source when the model forgot `language`. `nil` when it is neither shape.
    public static func infer(from source: String) -> DynamicToolLanguage? {
        let s = source
        if s.range(of: #"(struct|final\s+class|class|enum)\s+\w+\s*:\s*Tool\b"#, options: .regularExpression) != nil { return .swift }
        if s.range(of: #"(?m)^\s*(var|let|const)\s+tool\s*="#, options: .regularExpression) != nil { return .javascript }
        if s.contains("func call(") { return .swift }
        if s.range(of: #"\bcall\s*\(\s*\w*\s*\)\s*\{"#, options: .regularExpression) != nil || s.contains("=>") { return .javascript }
        return nil
    }
}

/// Where an agent-written tool stands: live, or saved for a device that can run it.
public enum DynamicToolStatus: Sendable, Hashable, Codable {
    /// Compiled/evaluated here and registered.
    case active
    /// Source kept, not runnable on this device (Swift on iPhone). The text is what the model was told.
    case saved(reason: String)
    /// Source kept, but it failed to load at relaunch (toolchain gone, syntax error after an edit…).
    case failed(error: String)

    public var isActive: Bool { self == .active }
    public var label: String {
        switch self {
        case .active: return "active"
        case .saved: return "saved"
        case .failed: return "failed"
        }
    }
}

/// One agent-written tool on disk: `<dir>/<name>.<swift|js>` holds the source, `<dir>/<name>.json` holds this.
public struct DynamicToolRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var language: DynamicToolLanguage
    public var description: String
    public var createdAt: Date
    /// Who wrote it — "agent" for `manage_tools create`; a person can drop a file in the folder too.
    public var author: String
    public var status: DynamicToolStatus

    public init(name: String, language: DynamicToolLanguage, description: String, createdAt: Date = Date(), author: String = "agent", status: DynamicToolStatus) {
        self.name = name; self.language = language; self.description = description; self.createdAt = createdAt; self.author = author; self.status = status
    }
}

/// Name rule shared with the SDK's registry (and tiny-tech's `isValidLocalToolName`): 1–64 chars of letters, digits, `_`, `-`.
public enum DynamicToolName {
    public static func isValid(_ name: String) -> Bool {
        (1...64).contains(name.count) && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
    }
    /// `my-tool` and `my_tool` collide, like the registry says they do.
    public static func key(_ name: String) -> String { name.replacingOccurrences(of: "-", with: "_").lowercased() }
}

/// The two documented shapes, word for word what the model is shown (tool description + rejection messages).
public enum DynamicToolShape {
    public static let swift = """
    import Foundation
    struct ReverseString: Tool {                       // struct <AnyName>: Tool, init with no arguments
        let name = "reverse_string"                     // 1-64 chars: letters, digits, _ -
        let description = "Reverses the given text."    // tells the model when to use it
        let inputSchema: [String: Any] = ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
        func call(_ args: [String: Any]) async throws -> String {
            guard let text = args["text"] as? String else { throw ToolError("text is required") }
            return String(text.reversed())
        }
    }
    """

    public static let javascript = """
    var tool = {
      name: "reverse_string",                        // 1-64 chars: letters, digits, _ -
      description: "Reverses the given text.",       // tells the model when to use it
      inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
      call(args) {                                   // may return a string, an object, or a Promise
        if (typeof args.text !== "string") throw new Error("text is required");
        return args.text.split("").reverse().join("");
      }
    };
    // Bridge: loopl.call("calculator", {expression: "2+2"}) runs another mounted tool (returns its text);
    // loopl.http(url, {method, headers, body}) → {status, body}; loopl.log("…"). No eval of fetched code.
    """

    public static func text(for language: DynamicToolLanguage) -> String { language == .swift ? swift : javascript }
}
