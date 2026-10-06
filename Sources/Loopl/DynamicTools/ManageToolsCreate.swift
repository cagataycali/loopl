import Foundation

/// `manage_tools` — the model grows its own toolset: `create` (write Swift on a Mac, JavaScript on an iPhone/iPad, load it,
/// use it on the very next call), `remove`, `list`. FALLBACK until P6-A's registry-backed `ManageToolsTool` (mount/unmount/
/// describe/create/remove) is on main — then the Engine offers that one and `DynamicToolStore` plugs in as its `ToolCreator`
/// (see `DynamicToolStore.create(name:source:language:)`); this struct is only used when no other `manage_tools` is offered.
public struct ManageToolsFallbackTool: Tool {
    public let name = "manage_tools"
    public let store: DynamicToolStore
    /// The language the description steers the model to — the device's by default; a harness can force the iPhone path on a Mac.
    public let language: DynamicToolLanguage
    public init(store: DynamicToolStore = .shared, language: DynamicToolLanguage = .preferredHere) { self.store = store; self.language = language }

    public var description: String { ManageToolsCreate.description(for: language) }
    public var parameters: JSONValue { ManageToolsCreate.parameters }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        try await ManageToolsCreate.handle(args, store: store)
    }
}

public enum ManageToolsCreate {
    public static let actions = ["list", "create", "remove"]

    /// The description tells the model which language THIS device runs — the directive lives here, not only in the system prompt.
    public static func description(for language: DynamicToolLanguage) -> String {
        let lang = language == .swift ? "Swift" : "JavaScript"
        let here = language == .swift ? "a Mac" : "an iPhone or iPad"
        return """
        Manage your own tools at runtime. When no tool does what the user needs, WRITE ONE: `create` with `source` = the tool's code \
        and it is live on your very next call (and after relaunch). This device is \(here): write \(lang). Shape:
        \(DynamicToolShape.text(for: language))
        `list` shows the tools you created. `remove` deletes one by name. Compile/evaluation errors come back verbatim — fix the code and create again.
        """
    }

    public static let parameters: JSONValue = ["type": "object", "properties": [
        "action": ["type": "string", "enum": .array(actions.map(JSONValue.string)), "description": "list | create | remove"],
        "name": ["type": "string", "description": "tool name (create: must equal the name in the code; remove: which tool)"],
        "source": ["type": "string", "description": "create: the full tool source code (Swift on a Mac, JavaScript on iPhone/iPad)"],
        "language": ["type": "string", "enum": ["swift", "javascript"], "description": "create: which language `source` is (inferred when omitted)"],
    ], "required": ["action"]]

    public static func handle(_ args: [String: JSONValue], store: DynamicToolStore) async throws -> String {
        let action = args["action"]?.stringValue?.lowercased() ?? ""
        switch action {
        case "create":
            let source = (args["source"] ?? args["code"])?.stringValue ?? ""
            let language = args["language"]?.stringValue.flatMap { DynamicToolLanguage(rawValue: $0.lowercased()) }
            do {
                return try await store.create(name: args["name"]?.stringValue, source: source, language: language).message
            } catch let e as DynamicToolStore.CreateError {
                throw ToolError("create rejected — \(e.message)")
            } catch let e as JSToolError {
                throw ToolError("create rejected — JavaScript: \(e.message)")
            } catch {
                #if os(macOS)
                if let e = error as? SwiftToolCompiler.Failure { throw ToolError("create rejected — Swift \(e.stage.rawValue) error:\n\(e.message)") }
                #endif
                throw error
            }
        case "remove":
            guard let name = args["name"]?.stringValue, !name.isEmpty else { throw ToolError("remove needs `name`") }
            do { return try await store.remove(name: name) as String } catch let e as DynamicToolStore.CreateError { throw ToolError(e.message) }
        case "list", "":
            let records = await store.records
            if records.isEmpty { return "no agent-written tools yet — `create` one (\(DynamicToolLanguage.preferredHere.rawValue) on this device)" }
            let lines = records.map { r -> String in
                let status: String
                switch r.status {
                case .active: status = "active"
                case .saved(let why): status = "saved, not running here — \(why)"
                case .failed(let err): status = "failed to load — \(err.split(separator: "\n").first ?? "")"
                }
                return "  \(r.name) [\(r.language.rawValue), \(status)] — \(r.description.split(separator: "\n").first ?? "")"
            }
            return "\(records.count) agent-written tool\(records.count == 1 ? "" : "s"):\n" + lines.joined(separator: "\n")
        default:
            throw ToolError("unknown action \"\(action)\" — use list, create or remove")
        }
    }
}
