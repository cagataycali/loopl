import Foundation

/// `manage_tools` — the agent manages its OWN toolset mid-task (the shape tiny-tech's
/// `manage_tools`/`load_tools` have). Backed by a `ToolRegistry`; because the `Agent` reads the registry when it
/// builds each model request, `mount` takes effect on the very next model call of the same turn.
///
/// Actions: `list` (every known tool, mounted or not, with why one cannot run here) · `mount` / `unmount` (by name)
/// · `describe` (a tool's full description + parameters). Owner decision (2026-10-06 21:1xZ): no `create`/`remove` —
/// loopl does not load model-written code; tools are registered by the host (`ToolRegistry.register`).
///
/// The description below is MEASURED on Qwen3.5-0.8B / loopl-0.8b (ManageToolsMeasurement): short, verb-first,
/// and it names the exact phrase the model should react to ("a tool you do not have").
public struct ManageToolsTool: Tool {
    public let registry: ToolRegistry
    public init(registry: ToolRegistry) { self.registry = registry }

    public static let toolName = "manage_tools"
    public var name: String { Self.toolName }
    public var description: String {
        // v2 (measured): lead with the trigger + the exact call. v1 ("Add or remove your own tools…list first") scored 0/12
        // on loopl-0.8b — the model calls the missing tool by name and gives up on "Unknown tool"; the unknown-tool error
        // now points here, and this text says what to send.
        "Mount a tool you need but do not have. If a tool is missing from your tool list — for example http, calculator, current_time, remember, recall or a device tool — call manage_tools with {\"action\": \"mount\", \"names\": [\"<tool name>\"]}; it is usable on your very next step, so call it right after. {\"action\": \"list\"} shows every tool you can mount. unmount removes tools you no longer need; describe shows one tool's parameters."
    }
    public var parameters: JSONValue {
        ToolSchema.object([
            "action": ["type": "string", "enum": ["list", "mount", "unmount", "describe"],
                       "description": "list | mount | unmount | describe"],
            "names": ["type": "array", "items": ["type": "string"], "description": "tool names for mount / unmount / describe"],
            "name": ToolSchema.string("one tool name (same as names with one entry)"),
        ], required: ["action"])
    }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        let action = args["action"]?.stringValue?.lowercased() ?? ""
        var names = Self.names(from: args["names"])
        for one in Self.names(from: args["name"]) where !names.contains(one) { names.append(one) }

        switch action {
        case "list":
            return Self.render(list: await registry.list())
        case "mount":
            guard !names.isEmpty else { throw ToolError("mount needs names: which tools to add. Call action \"list\" to see them.") }
            let c = await registry.mount(names)
            return Self.render(change: c, verb: "mounted", mountedNow: await registry.mountedNames, known: await registry.names)
        case "unmount":
            guard !names.isEmpty else { throw ToolError("unmount needs names: which tools to remove.") }
            let c = await registry.unmount(names)
            return Self.render(change: c, verb: "unmounted", mountedNow: await registry.mountedNames, known: await registry.names)
        case "describe":
            guard !names.isEmpty else { throw ToolError("describe needs names.") }
            var out: [String] = []
            for n in names {
                guard let e = await registry.entry(n) else { out.append("\(n): unknown tool. Known: \(await registry.names.joined(separator: ", "))"); continue }
                out.append("\(e.name) [\(e.mounted ? "mounted" : "not mounted")\(e.available ? "" : " · cannot run here: \(e.reason)")]\n\(e.tool.description)\nparameters: \(e.tool.parameters.compact)")
            }
            return out.joined(separator: "\n\n")
        default:
            throw ToolError("unknown action \"\(action)\". Use list, mount, unmount or describe.")
        }
    }

    /// `names` as small models actually send it (measured on loopl-0.8b): a JSON array, one string, `"[remember]"`,
    /// `"http, calculator"` — brackets, quotes and whitespace are stripped, commas and spaces split.
    public static func names(from value: JSONValue?) -> [String] {
        guard let value else { return [] }
        let raw: [String]
        switch value {
        case .array(let a): raw = a.compactMap { $0.stringValue ?? $0.compact }
        case .string(let s): raw = [s]
        default: raw = [value.compact]
        }
        let junk = CharacterSet(charactersIn: "[]\"'` \n\t")
        return raw.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",")) }
            .map { $0.trimmingCharacters(in: junk) }
            .flatMap { $0.split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    static func render(list: [ToolRegistry.Listing]) -> String {
        guard !list.isEmpty else { return "no tools known." }
        let mounted = list.filter(\.mounted), rest = list.filter { !$0.mounted }
        var lines: [String] = ["mounted (\(mounted.count)): " + (mounted.isEmpty ? "none" : mounted.map(\.name).joined(separator: ", "))]
        if !rest.isEmpty {
            lines.append("available to mount (\(rest.filter(\.available).count)):")
            for r in rest {
                let first = r.description.split(separator: "\n").first.map(String.init) ?? r.description
                let short = first.count > 90 ? String(first.prefix(87)) + "…" : first
                lines.append(r.available ? "  \(r.name) — \(short)" : "  \(r.name) — cannot run here: \(r.reason)")
            }
        }
        lines.append("Call action \"mount\" with names to use one on your next step.")
        return lines.joined(separator: "\n")
    }

    static func render(change c: ToolRegistry.Change, verb: String, mountedNow: [String], known: [String]) -> String {
        var parts: [String] = []
        if !c.changed.isEmpty { parts.append("\(verb) \(c.changed.joined(separator: ", "))") }
        if !c.unchanged.isEmpty { parts.append("already \(verb == "mounted" ? "mounted" : "not mounted"): \(c.unchanged.joined(separator: ", "))") }
        if !c.pinned.isEmpty { parts.append("cannot unmount \(c.pinned.joined(separator: ", ")) (always on)") }
        for (n, why) in c.unavailable { parts.append("\(n) cannot run on this device: \(why)") }
        if !c.unknown.isEmpty { parts.append("unknown: \(c.unknown.joined(separator: ", ")). Known tools: \(known.joined(separator: ", "))") }
        parts.append("mounted now: " + (mountedNow.isEmpty ? "none" : mountedNow.joined(separator: ", ")))
        if !c.changed.isEmpty, verb == "mounted" { parts.append("You can call \(c.changed.joined(separator: ", ")) now.") }
        return parts.joined(separator: "\n")
    }
}
