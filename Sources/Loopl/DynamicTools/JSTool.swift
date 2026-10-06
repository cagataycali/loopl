import Foundation
import JavaScriptCore

/// An agent-written JavaScript tool, run in JavaScriptCore — the one way to execute agent-written code on an
/// iPhone (App Store Review 2.5.2: scripts may run only in JavaScriptCore/WebKit). Shape: `DynamicToolShape.javascript`
/// — the script defines a global `tool` object with `name`, `description`, `inputSchema` and `call(args)`.
///
/// The bridge the script gets, and nothing else that reaches outside the VM:
///   `loopl.call(toolName, args)` → runs another mounted tool (the host decides which), returns its text
///   `loopl.http(url, {method, headers, body})` → `{status, body}` (https only, 20 s)
///   `loopl.log(text)` → attached to the result for the model to read
/// `eval` is removed from the global object: fetched text is data, never code (no eval of remote code).
///
/// Each call gets a FRESH context from the source (no state leaks between calls, a runaway call cannot poison
/// the next one) on a background thread; the host waits up to `timeout` and reports a timeout as the result —
/// like tiny-tech's `wrapHandler`, the deadline stops the TURN waiting, nothing in JSC can stop the script.
public struct JSTool: Tool {
    public static let defaultTimeout: TimeInterval = 30
    public static let outputMax = 20_000

    public let name: String
    public let description: String
    public let parameters: JSONValue
    public let source: String
    public let timeout: TimeInterval

    /// Validate `source` by running it once and reading `tool`. Throws `JSToolError` with the engine's own words.
    public init(source: String, timeout: TimeInterval = JSTool.defaultTimeout, bridge: JSToolBridge = .none) throws {
        let spec = try JSToolRuntime.spec(of: source, bridge: bridge)
        self.name = spec.name; self.description = spec.description; self.parameters = spec.inputSchema
        self.source = source; self.timeout = timeout
    }

    public func call(_ args: [String: JSONValue]) async throws -> String {
        try await call(args, bridge: JSToolRuntime.bridge)
    }

    public func call(_ args: [String: JSONValue], bridge: JSToolBridge) async throws -> String {
        let source = self.source, timeout = self.timeout
        let text: Result<String, JSToolError> = await withCheckedContinuation { cont in
            let done = Locked(false)
            let thread = Thread {
                let r = Result { try JSToolRuntime.invoke(source: source, args: args, bridge: bridge, deadline: Date().addingTimeInterval(timeout)) }
                    .mapError { $0 as? JSToolError ?? JSToolError("\($0)") }
                if done.swap(true) == false { cont.resume(returning: r) }
            }
            thread.name = "loopl.jstool.\(name)"; thread.stackSize = 4 << 20
            thread.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 0.5) {
                if done.swap(true) == false { cont.resume(returning: .failure(JSToolError("tool \"\(name)\" timed out after \(Int(timeout)) s"))) }
            }
        }
        switch text {
        case .success(let s): return s
        case .failure(let e): throw ToolError(e.message)
        }
    }
}

public struct JSToolError: LocalizedError, Sendable, Hashable {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// What `loopl.call` / `loopl.http` do — the host (ToolRegistry / Engine) supplies the real one.
public struct JSToolBridge: Sendable {
    /// Run a mounted tool by name, synchronously from the script's thread. Return the tool's text or throw.
    public var call: @Sendable (_ tool: String, _ args: [String: JSONValue]) throws -> String
    /// `nil` → `loopl.http` uses `HttpTool` (https only, approvals included).
    public var http: (@Sendable (_ url: String, _ options: [String: JSONValue]) throws -> JSONValue)?
    public init(call: @escaping @Sendable (String, [String: JSONValue]) throws -> String,
                http: (@Sendable (String, [String: JSONValue]) throws -> JSONValue)? = nil) {
        self.call = call; self.http = http
    }
    /// No other tools reachable (validation, tests).
    public static let none = JSToolBridge(call: { name, _ in throw JSToolError("loopl.call: no tool named \"\(name)\" is reachable from here") })
}

public enum JSToolRuntime {
    /// The bridge live tools use; the app sets it once (Engine) to reach its mounted tools.
    nonisolated(unsafe) private static var _bridge = JSToolBridge.none
    private static let lock = NSLock()
    public static var bridge: JSToolBridge {
        get { lock.lock(); defer { lock.unlock() }; return _bridge }
        set { lock.lock(); _bridge = newValue; lock.unlock() }
    }

    public struct Spec: Sendable, Hashable { public var name: String; public var description: String; public var inputSchema: JSONValue }

    /// Evaluate the script and read `tool` — the shape check, with the engine's error verbatim when it does not parse.
    public static func spec(of source: String, bridge: JSToolBridge) throws -> Spec {
        let (ctx, tool) = try load(source: source, bridge: bridge, deadline: Date().addingTimeInterval(10), logs: Locked([]))
        _ = ctx
        guard let name = tool.forProperty("name")?.toString(), tool.forProperty("name")?.isString == true, DynamicToolName.isValid(name) else {
            throw JSToolError("tool.name must be 1-64 chars of letters, digits, _ or - (got \(tool.forProperty("name")?.toString() ?? "undefined"))")
        }
        guard let desc = tool.forProperty("description"), desc.isString, let d = desc.toString(), !d.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw JSToolError("tool.description is required — it is how the model knows when to use the tool")
        }
        guard let fn = tool.forProperty("call"), fn.isObject, isFunction(fn) else {
            throw JSToolError("tool.call(args) must be a function")
        }
        var schema = ToolSchema.object([:])
        if let s = tool.forProperty("inputSchema"), !s.isUndefined, !s.isNull {
            guard s.isObject, let any = s.toObject(), let v = Optional(JSONValue(any: any)), v.objectValue != nil else {
                throw JSToolError("tool.inputSchema must be a JSON Schema object")
            }
            schema = v
        }
        return Spec(name: name, description: d, inputSchema: schema)
    }

    /// Fresh context → run → `tool.call(args)` → resolve a Promise if one came back → string.
    static func invoke(source: String, args: [String: JSONValue], bridge: JSToolBridge, deadline: Date) throws -> String {
        let logs = Locked<[String]>([])
        let (ctx, tool) = try load(source: source, bridge: bridge, deadline: deadline, logs: logs)
        guard let fn = tool.forProperty("call"), isFunction(fn) else { throw JSToolError("tool.call is not a function") }
        let argObj = JSValue(object: JSONValue.object(args).anyValue, in: ctx)!
        guard var result = tool.invokeMethod("call", withArguments: [argObj]) else {
            throw JSToolError("tool.call returned nothing")
        }
        if let exc = ctx.exception { ctx.exception = nil; throw JSToolError(describe(exception: exc)) }
        if isThenable(result) { result = try settle(promise: result, in: ctx, deadline: deadline) }
        var text = stringify(result)
        let logged = logs.value
        if !logged.isEmpty { text += "\n[log] " + logged.joined(separator: "\n[log] ") }
        if text.count > JSTool.outputMax { text = String(text.prefix(JSTool.outputMax)) + "\n… [output truncated at \(JSTool.outputMax) chars]" }
        return text
    }

    // MARK: - internals

    private static func load(source: String, bridge: JSToolBridge, deadline: Date, logs: Locked<[String]>) throws -> (JSContext, JSValue) {
        guard let ctx = JSContext() else { throw JSToolError("JavaScriptCore unavailable") }
        ctx.name = "loopl tool"
        let firstError = Locked<String?>(nil)
        // A custom handler REPLACES the default, which stored the exception on the context — keep doing that, or
        // `throw` inside tool.call() is silently swallowed and the model gets "(no output)".
        ctx.exceptionHandler = { c, exc in c?.exception = exc; if firstError.value == nil { firstError.value = exc.map(describe(exception:)) } }
        install(bridge: bridge, in: ctx, deadline: deadline, logs: logs)
        ctx.evaluateScript(source, withSourceURL: URL(string: "loopl://tool.js"))
        if let e = firstError.value { throw JSToolError(e) }
        guard let tool = ctx.objectForKeyedSubscript("tool"), tool.isObject, !tool.isUndefined else {
            throw JSToolError("the script must define a global `tool` object. Write exactly this shape:\n\(DynamicToolShape.javascript)")
        }
        return (ctx, tool)
    }

    private static func install(bridge: JSToolBridge, in ctx: JSContext, deadline: Date, logs: Locked<[String]>) {
        // No eval of remote code: `eval` and `Function` go away before the script runs.
        ctx.evaluateScript("delete this.eval; this.Function = undefined;")
        let loopl = JSValue(newObjectIn: ctx)!
        let call: @convention(block) (String, JSValue?) -> JSValue? = { name, args in
            let a = args.flatMap { $0.isObject ? JSONValue(any: $0.toObject() as Any).objectValue : nil } ?? [:]
            do { return JSValue(object: try bridge.call(name, a), in: ctx) }
            catch { ctx.exception = JSValue(newErrorFromMessage: "loopl.call(\(name)): \(error)", in: ctx); return JSValue(undefinedIn: ctx) }
        }
        loopl.setObject(call, forKeyedSubscript: "call" as NSString)
        let http: @convention(block) (String, JSValue?) -> JSValue? = { url, opts in
            let o = opts.flatMap { $0.isObject ? JSONValue(any: $0.toObject() as Any).objectValue : nil } ?? [:]
            do {
                let v = try (bridge.http ?? defaultHTTP)(url, o)
                return JSValue(object: v.anyValue, in: ctx)
            } catch { ctx.exception = JSValue(newErrorFromMessage: "loopl.http: \(error)", in: ctx); return JSValue(undefinedIn: ctx) }
        }
        loopl.setObject(http, forKeyedSubscript: "http" as NSString)
        let log: @convention(block) (JSValue?) -> Void = { v in logs.mutate { $0.append(v.map(stringify) ?? "undefined") } }
        loopl.setObject(log, forKeyedSubscript: "log" as NSString)
        loopl.setObject(deadline.timeIntervalSince1970 * 1000, forKeyedSubscript: "deadline" as NSString)
        ctx.setObject(loopl, forKeyedSubscript: "loopl" as NSString)
        // `console.log` is what the model will write anyway.
        ctx.evaluateScript("var console = { log: function() { loopl.log(Array.prototype.slice.call(arguments).map(String).join(' ')); } };")
    }

    /// `loopl.http` without a host bridge: the SDK's HttpTool (https only, same offline rule), run inline.
    private static let defaultHTTP: @Sendable (String, [String: JSONValue]) throws -> JSONValue = { url, opts in
        var args = opts; args["url"] = .string(url)
        let sem = DispatchSemaphore(value: 0)
        let out = Locked<Result<String, Error>?>(nil)
        Task.detached {
            do { out.value = .success(try await HttpTool(maxChars: 20_000).call(args)) } catch { out.value = .failure(error) }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 25) == .success, let r = out.value else { throw JSToolError("http timed out") }
        let text = try r.get()
        let status = text.range(of: #"HTTP (\d{3})"#, options: .regularExpression).map { Int(text[$0].dropFirst(5)) ?? 0 } ?? 0
        return .object(["status": .number(Double(status)), "body": .string(text)])
    }

    private static func isFunction(_ v: JSValue) -> Bool {
        v.context.evaluateScript("(function(f){ return typeof f === 'function'; })").call(withArguments: [v]).toBool()
    }
    private static func isThenable(_ v: JSValue) -> Bool {
        v.isObject && (v.forProperty("then").map(isFunction) ?? false)
    }

    /// Wait for a Promise on the script's thread: pump the context by polling `then` results until settled or deadline.
    private static func settle(promise: JSValue, in ctx: JSContext, deadline: Date) throws -> JSValue {
        let settled = Locked<(Bool, JSValue?)>((false, nil))
        let onOK: @convention(block) (JSValue?) -> Void = { v in settled.value = (true, v) }
        let onErr: @convention(block) (JSValue?) -> Void = { v in ctx.exception = v ?? JSValue(newErrorFromMessage: "rejected", in: ctx); settled.value = (true, nil) }
        promise.invokeMethod("then", withArguments: [JSValue(object: onOK, in: ctx)!, JSValue(object: onErr, in: ctx)!])
        // JSC runs microtasks when the call stack drains; evaluating an empty script drains it.
        while !settled.value.0 {
            if Date() > deadline { throw JSToolError("tool promise never settled before the deadline") }
            ctx.evaluateScript("0")
            if !settled.value.0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        if let exc = ctx.exception { ctx.exception = nil; throw JSToolError(describe(exception: exc)) }
        return settled.value.1 ?? JSValue(undefinedIn: ctx)
    }

    private static func stringify(_ v: JSValue) -> String {
        if v.isUndefined || v.isNull { return "(no output)" }
        if v.isString { return v.toString() }
        if v.isNumber || v.isBoolean { return v.toString() }
        if let any = v.toObject() { return JSONValue(any: any).compact }
        return v.toString()
    }

    private static func describe(exception exc: JSValue) -> String {
        var s = exc.toString() ?? "error"
        if let line = exc.forProperty("line"), line.isNumber { s += " (line \(Int(line.toInt32())))" }
        if let stack = exc.forProperty("stack"), stack.isString, let st = stack.toString(), !st.isEmpty, !s.contains(st) { s += "\n" + st.split(separator: "\n").prefix(3).joined(separator: "\n") }
        return s
    }
}

/// A tiny lock box (the JS thread and the waiting task share a few flags).
final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
    @discardableResult func swap(_ new: T) -> T { lock.lock(); defer { lock.unlock() }; let old = v; v = new; return old }
}
