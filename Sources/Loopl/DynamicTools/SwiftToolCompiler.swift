import Foundation

#if os(macOS)
/// Compiles agent-written Swift into a dylib and loads it as a `Tool` — macOS only (a toolchain is needed).
///
/// The source must follow `DynamicToolShape.swift`: ONE `struct X: Tool` with `name`, `description`,
/// `inputSchema: [String: Any]` and `func call(_ args: [String: Any]) async throws -> String`. The `Tool`
/// protocol the source sees is the shim's (below), not the SDK's — the dylib never links against Loopl, so
/// the only contract between the two is three C symbols (`loopl_tool_abi`, `loopl_tool_spec`, `loopl_tool_call`)
/// with JSON strings across them. That is what keeps a tool built today loadable by next month's app.
///
/// Mirrors tiny-tech `manage-tools.ts`: NOTHING is dlopen'd into this process before it has passed a
/// sandbox — a separate probe process loads the dylib, prints its spec, and must exit cleanly inside a
/// timeout. A dylib that crashes, hangs or exports no tool costs a subprocess, not the app.
public enum SwiftToolCompiler {
    public static let abiVersion = 1
    public static let compileTimeout: TimeInterval = 90
    public static let probeTimeout: TimeInterval = 15

    public struct Failure: LocalizedError, Sendable, Hashable {
        public enum Stage: String, Sendable { case shape, toolchain, compile, probe, load }
        public let stage: Stage
        /// The compiler's (or probe's) own words, verbatim — the model fixes its code from these.
        public let message: String
        public var errorDescription: String? { "\(stage.rawValue): \(message)" }
    }

    /// Where the toolchain is. `nil` when `xcrun swiftc` is not available — then Swift tools are saved, not run.
    public static func toolchain() -> URL? {
        guard let out = try? run("/usr/bin/xcrun", ["--find", "swiftc"], timeout: 20), out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// `struct ReverseString: Tool` → "ReverseString". Fails with the documented shape when there is none / several.
    public static func toolTypeName(in source: String) throws -> String {
        let re = try NSRegularExpression(pattern: #"(?:struct|final\s+class|class)\s+(\w+)\s*:\s*(?:[\w\.]+\s*,\s*)*Tool\b"#)
        let ns = source as NSString
        let names = re.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        guard let first = names.first else {
            throw Failure(stage: .shape, message: "no `struct <Name>: Tool` found. Write exactly this shape:\n\(DynamicToolShape.swift)")
        }
        guard names.count == 1 else { throw Failure(stage: .shape, message: "one tool per file — found \(names.joined(separator: ", "))") }
        return first
    }

    /// The source the model wrote plus the shim, compiled to `<buildDir>/<name>.dylib`.
    /// `name` is only used for file/module names; the tool's real name comes from the probe.
    public static func compile(source: String, name: String, buildDir: URL) throws -> URL {
        let typeName = try toolTypeName(in: source)
        guard let swiftc = toolchain() else {
            throw Failure(stage: .toolchain, message: "no Swift toolchain here (`xcrun --find swiftc` failed) — install Xcode or the Command Line Tools")
        }
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let work = buildDir.appendingPathComponent("\(name).build", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let userFile = work.appendingPathComponent("\(name).swift")
        let shimFile = work.appendingPathComponent("loopl_shim.swift")
        var user = source
        if user.range(of: #"(?m)^\s*import\s+Foundation\b"#, options: .regularExpression) == nil { user = "import Foundation\n" + user }
        try user.write(to: userFile, atomically: true, encoding: .utf8)
        try shim.replacingOccurrences(of: "LOOPL_TOOL_TYPE", with: typeName).write(to: shimFile, atomically: true, encoding: .utf8)
        let out = buildDir.appendingPathComponent("\(name).dylib")
        try? FileManager.default.removeItem(at: out)
        let module = "looplTool_" + name.replacingOccurrences(of: "-", with: "_")
        let r = try run(swiftc.path, ["-swift-version", "5", "-O", "-emit-library", "-module-name", module, "-o", out.path, shimFile.path, userFile.path],
                        timeout: compileTimeout)
        guard r.status == 0, FileManager.default.fileExists(atPath: out.path) else {
            // Line numbers refer to the model's file: strip the work dir so the error reads `reverse_string.swift:6:12: error: …`.
            let text = (r.stderr.isEmpty ? r.stdout : r.stderr).replacingOccurrences(of: work.path + "/", with: "")
            throw Failure(stage: .compile, message: text.isEmpty ? "swiftc exited \(r.status)" : String(text.prefix(4000)))
        }
        return out
    }

    public struct ProbeResult: Sendable, Hashable {
        public var name: String
        public var description: String
        public var inputSchema: JSONValue
    }

    /// Load the dylib in a SEPARATE process and read its spec. Compiles the probe executable once per build dir.
    public static func probe(dylib: URL, buildDir: URL) throws -> ProbeResult {
        let probeBin = try probeExecutable(in: buildDir)
        let r: RunResult
        do { r = try run(probeBin.path, [dylib.path], timeout: probeTimeout) }
        catch let e as Failure { throw e }
        catch { throw Failure(stage: .probe, message: "\(error)") }
        guard let line = r.stdout.split(separator: "\n").first(where: { $0.hasPrefix("LOOPL_PROBE ") }),
              let json = JSONValue.parse(String(line.dropFirst("LOOPL_PROBE ".count))) else {
            let why = r.status == -1 ? "the tool's dylib hung for \(Int(probeTimeout)) s while loading"
                : "the tool's dylib crashed while loading (exit \(r.status)): \(r.stderr.prefix(800))"
            throw Failure(stage: .probe, message: why)
        }
        guard json["ok"]?.boolValue == true else { throw Failure(stage: .probe, message: json["error"]?.stringValue ?? "probe failed") }
        guard let abi = json["abi"]?.doubleValue, Int(abi) == abiVersion else {
            throw Failure(stage: .probe, message: "tool was built for ABI \(json["abi"]?.compact ?? "?"), this app speaks \(abiVersion) — recompile from source")
        }
        guard let spec = json["spec"], let name = spec["name"]?.stringValue, let desc = spec["description"]?.stringValue else {
            throw Failure(stage: .probe, message: "spec missing name/description")
        }
        return ProbeResult(name: name, description: desc, inputSchema: spec["inputSchema"] ?? ToolSchema.object([:]))
    }

    /// dlopen into THIS process — only after `probe` passed.
    public static func load(dylib: URL, spec: ProbeResult) throws -> CompiledSwiftTool {
        guard let handle = dlopen(dylib.path, RTLD_NOW | RTLD_LOCAL) else {
            throw Failure(stage: .load, message: String(cString: dlerror()))
        }
        guard let sym = dlsym(handle, "loopl_tool_call") else {
            dlclose(handle); throw Failure(stage: .load, message: "loopl_tool_call missing")
        }
        return CompiledSwiftTool(name: spec.name, description: spec.description, parameters: spec.inputSchema,
                                 handle: UncheckedHandle(handle), callFn: unsafeBitCast(sym, to: CompiledSwiftTool.CallFn.self))
    }

    // MARK: - internals

    struct RunResult { var status: Int32; var stdout: String; var stderr: String }

    /// Run a process with a timeout. `status == -1` means it was killed on the timeout.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) throws -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LOOPL_SANDBOX"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        // Drain pipes while waiting (a chatty compiler fills the pipe and deadlocks otherwise).
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data(), errData = Data()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        var status = p.terminationStatus
        if p.isRunning { p.terminate(); Thread.sleep(forTimeInterval: 0.2); if p.isRunning { kill(p.processIdentifier, SIGKILL) }; status = -1 }
        p.waitUntilExit()
        if status != -1 { status = p.terminationStatus }
        group.wait()
        return RunResult(status: status, stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self))
    }

    /// The probe is itself compiled once (≈0.3 s) into `buildDir/.probe-v<abi>`; rebuilt when the toolchain changes.
    static func probeExecutable(in buildDir: URL) throws -> URL {
        guard let swiftc = toolchain() else { throw Failure(stage: .toolchain, message: "no Swift toolchain (`xcrun --find swiftc` failed)") }
        let stamp = (try? swiftc.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970).map { Int($0) } ?? 0
        let bin = buildDir.appendingPathComponent(".probe-v\(abiVersion)-\(stamp)")
        if FileManager.default.isExecutableFile(atPath: bin.path) { return bin }
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let src = buildDir.appendingPathComponent(".probe.swift")
        try probeSource.write(to: src, atomically: true, encoding: .utf8)
        let r = try run(swiftc.path, ["-O", "-o", bin.path, src.path], timeout: compileTimeout)
        guard r.status == 0 else { throw Failure(stage: .toolchain, message: "could not build the probe: \(r.stderr.prefix(800))") }
        return bin
    }

    /// Appended to the model's file. `LOOPL_TOOL_TYPE` is replaced by the struct name found in the source.
    static let shim = """
    import Foundation
    /// The shape an agent-written tool conforms to (see DynamicToolShape.swift). Not the SDK's `Tool`: the dylib
    /// never links Loopl — the host reads it through three C symbols and JSON.
    public protocol Tool {
        var name: String { get }
        var description: String { get }
        var inputSchema: [String: Any] { get }
        init()
        func call(_ args: [String: Any]) async throws -> String
    }
    public struct ToolError: Error, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }
    private func looplMakeTool() -> any Tool { LOOPL_TOOL_TYPE() }
    private func looplJSON(_ obj: Any) -> UnsafeMutablePointer<CChar> {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed, .sortedKeys])) ?? Data("{}".utf8)
        return strdup(String(decoding: data, as: UTF8.self))
    }
    @_cdecl("loopl_tool_abi") public func loopl_tool_abi() -> Int32 { \(abiVersion) }
    @_cdecl("loopl_tool_spec") public func loopl_tool_spec() -> UnsafeMutablePointer<CChar> {
        let t = looplMakeTool()
        return looplJSON(["name": t.name, "description": t.description, "inputSchema": t.inputSchema])
    }
    /// argsJSON → {"ok":true,"text":…} or {"ok":false,"error":…}. The caller frees the result.
    @_cdecl("loopl_tool_call") public func loopl_tool_call(_ argsJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
        let data = Data(String(cString: argsJSON).utf8)
        let args = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var result: [String: Any] = [:] }
        let box = Box()
        Task.detached {
            do { box.result = ["ok": true, "text": try await looplMakeTool().call(args)] }
            catch { box.result = ["ok": false, "error": "\\(error)"] }
            sem.signal()
        }
        sem.wait()
        return looplJSON(box.result)
    }
    """

    static let probeSource = """
    import Foundation
    typealias AbiFn = @convention(c) () -> Int32
    typealias SpecFn = @convention(c) () -> UnsafeMutablePointer<CChar>
    func fail(_ why: String) -> Never {
        let data = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": why])
        print("LOOPL_PROBE " + String(decoding: data, as: UTF8.self)); exit(0)
    }
    guard CommandLine.arguments.count > 1 else { fail("usage: probe <dylib>") }
    guard let h = dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_LOCAL) else { fail(String(cString: dlerror())) }
    guard let a = dlsym(h, "loopl_tool_abi"), let s = dlsym(h, "loopl_tool_spec"), dlsym(h, "loopl_tool_call") != nil else {
        fail("the dylib exports no loopl tool (missing loopl_tool_abi/spec/call)")
    }
    let abi = unsafeBitCast(a, to: AbiFn.self)()
    let spec = String(cString: unsafeBitCast(s, to: SpecFn.self)())
    print("LOOPL_PROBE {\\"ok\\":true,\\"abi\\":\\(abi),\\"spec\\":\\(spec)}")
    """
}

/// An agent-written Swift tool, loaded from its dylib. Calls cross the C ABI as JSON.
public struct CompiledSwiftTool: Tool {
    typealias CallFn = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>
    public let name: String
    public let description: String
    public let parameters: JSONValue
    let handle: UncheckedHandle
    let callFn: CallFn

    public func call(_ args: [String: JSONValue]) async throws -> String {
        let payload = JSONValue.object(args).compact
        let fn = callFn
        // The dylib blocks its own thread on the tool's async work; keep that off the cooperative pool.
        let text: String = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let ptr = payload.withCString { fn($0) }
                let s = String(cString: ptr); free(ptr)
                cont.resume(returning: s)
            }
        }
        guard let out = JSONValue.parse(text) else { throw ToolError("tool returned unreadable output: \(text.prefix(300))") }
        if out["ok"]?.boolValue == true { return out["text"]?.stringValue ?? "" }
        throw ToolError(out["error"]?.stringValue ?? "tool failed")
    }
}

/// A dlopen handle is just a pointer; it lives as long as the process (we never dlclose a live tool).
struct UncheckedHandle: @unchecked Sendable { let raw: UnsafeMutableRawPointer; init(_ raw: UnsafeMutableRawPointer) { self.raw = raw } }
#endif
