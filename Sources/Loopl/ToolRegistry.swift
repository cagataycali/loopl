import Foundation

/// Every tool the agent KNOWS about — mounted or not — and which of them the model is offered right now.
///
/// Phase 6 (owner, 2026-10-06): *"when we use the tool named manage_tools, that will be immediately effective for the
/// language model call we will make"*. The registry is that one source of truth: the `Agent` holding one reads
/// `mounted` when it builds **each** model request (not once per run), so `manage_tools mount http` inside a turn puts
/// `http` into the very next request's tool specs and the model can call it in the same turn.
///
/// Mirrors tiny-tech's catalog + live registry split: a **catalog** of known tools (the app's portable tools, the
/// on-device Apple tools, anything registered later — created by the agent, lane D) and the **mounted** subset. A
/// tool this device cannot run stays in the catalog with `available == false` and a reason, so `list` tells the
/// model *why* instead of hiding it.
///
///     let registry = ToolRegistry(catalog: [CurrentTimeTool(), HttpTool()], mounted: ["current_time"])
///     let agent = Agent(model: m, registry: registry, tools: [ManageToolsTool(registry: registry)])
///     await registry.mount(["http"])          // next model call of the SAME turn offers http
///
/// Mount order is catalog order (stable across mounts), so tool specs do not reshuffle between model calls.
public actor ToolRegistry {
    /// One known tool and how it got here.
    public struct Entry: Sendable {
        public var tool: any Tool
        public var source: Source
        /// Runnable on this device right now. `false` → never mounted; `reason` explains.
        public var available: Bool
        public var reason: String
        /// `true` while the agent is offered it.
        public var mounted: Bool
        /// Always offered, never unmountable by the model (e.g. `manage_tools` itself).
        public var pinned: Bool
        public var name: String { tool.name }
        public init(tool: any Tool, source: Source = .app, available: Bool = true, reason: String = "", mounted: Bool = false, pinned: Bool = false) {
            self.tool = tool; self.source = source; self.available = available; self.reason = reason; self.mounted = mounted; self.pinned = pinned
        }
    }

    /// Where a catalog entry came from — shown in `list` and in Settings › Tools.
    public enum Source: String, Sendable, Codable, Hashable {
        /// Built into the app (portable + on-device tools).
        case app
        /// Written by the agent through `manage_tools create` (lane D) and loaded at runtime.
        case created
        /// Registered by the host for one session (tests, fixtures, a sub-agent's extras).
        case session
    }

    /// `catalog` as the model and the UI read it — no `any Tool` inside, so it crosses actors and is Hashable.
    public struct Listing: Sendable, Hashable, Identifiable, Codable {
        public var id: String { name }
        public var name: String
        public var description: String
        public var source: Source
        public var available: Bool
        public var reason: String
        public var mounted: Bool
        public var pinned: Bool
        public var asksFirst: String?
    }

    /// When the model calls a KNOWN, available, unmounted tool by name, mount it and run it instead of answering
    /// "exists but is not mounted" (the agent announces `toolsChanged` and the result says it was mounted). Off by
    /// default: a mount stays an explicit `manage_tools` call the transcript shows. Measured both ways (ManageToolsMeasurement).
    public var mountOnCall = false
    public func setMountOnCall(_ on: Bool) { mountOnCall = on }

    /// Plug point for `manage_tools create / remove` (lane D: Swift on macOS, JavaScript on iPhone). `nil` → the actions
    /// answer honestly that creating tools is not available on this device yet.
    public private(set) var creator: (any ToolCreator)?

    private var entries: [String: Entry] = [:]
    /// Catalog order — the order tools were registered; mount order follows it.
    private var order: [String] = []
    /// Bumped on every change to the mounted set; the `Agent` compares it to skip a no-op resync.
    public private(set) var version: Int = 0
    /// Observers told after every mounted-set change (the Engine updates Settings › Tools from here even when
    /// no agent run is in flight). Keyed so a host can remove its own.
    private var observers: [UUID: @Sendable ([String]) -> Void] = [:]

    /// - Parameters:
    ///   - catalog: every tool the agent may ever be offered, in catalog order.
    ///   - mounted: names offered at the start (defaults from Settings › Tools). Unknown names are ignored.
    ///   - pinned: names the model cannot unmount.
    ///   - selfManaging: also register `manage_tools` (bound to this registry) as a pinned, always-mounted app tool —
    ///     what the Engine does, so the model can mount/unmount the rest.
    public init(catalog: [any Tool] = [], mounted: [String]? = nil, pinned: Set<String> = [], selfManaging: Bool = false) {
        for t in catalog {
            let isPinned = pinned.contains(t.name)
            if entries[t.name] == nil { order.append(t.name) }
            entries[t.name] = Entry(tool: t, source: .app, mounted: isPinned || (mounted?.contains(t.name) ?? true), pinned: isPinned)
        }
        self.selfManaging = selfManaging
    }

    private let selfManaging: Bool
    private var selfToolInstalled = false
    /// `manage_tools` needs a reference to this registry, which an actor's init cannot hand out and keep touching its
    /// state — so it is installed on first access instead (every public entry point calls this first).
    private func install() {
        guard selfManaging, !selfToolInstalled else { return }
        selfToolInstalled = true
        let me = ManageToolsTool(registry: self)
        if entries[me.name] == nil { order.append(me.name) }
        entries[me.name] = Entry(tool: me, source: .app, mounted: true, pinned: true)
    }

    private func add(_ e: Entry) {
        if entries[e.name] == nil { order.append(e.name) }
        var e = e
        if !e.available { e.mounted = false }
        entries[e.name] = e
    }

    // MARK: reading

    /// The tools the agent is offered right now, in catalog order.
    public var mounted: [any Tool] { install(); return order.compactMap { entries[$0] }.filter(\.mounted).map(\.tool) }
    public var mountedNames: [String] { install(); return order.filter { entries[$0]?.mounted == true } }
    /// Every known tool, in catalog order.
    public var catalog: [Entry] { install(); return order.compactMap { entries[$0] } }
    public var names: [String] { install(); return order }
    public func entry(_ name: String) -> Entry? { install(); return entries[name] }
    public func tool(named name: String) -> (any Tool)? { install(); return entries[name]?.tool }

    /// Catalog as plain rows (for `manage_tools list`, Settings › Tools and tests).
    public func list() -> [Listing] {
        catalog.map { e in
            Listing(name: e.name, description: e.tool.description, source: e.source, available: e.available, reason: e.reason,
                    mounted: e.mounted, pinned: e.pinned, asksFirst: ToolListing.approvalNotes[e.name])
        }
    }

    // MARK: mutating

    /// Mount by name. Returns what actually changed and what could not be done, so the tool result is honest.
    @discardableResult
    public func mount(_ names: [String]) -> Change {
        install()
        var c = Change()
        for n in names {
            guard let e = entries[n] else { c.unknown.append(n); continue }
            if !e.available { c.unavailable.append((n, e.reason)); continue }
            if e.mounted { c.unchanged.append(n); continue }
            entries[n]?.mounted = true; c.changed.append(n)
        }
        if !c.changed.isEmpty { bump() }
        return c
    }

    /// Unmount by name. Pinned tools stay (reported under `pinned`).
    @discardableResult
    public func unmount(_ names: [String]) -> Change {
        install()
        var c = Change()
        for n in names {
            guard let e = entries[n] else { c.unknown.append(n); continue }
            if e.pinned { c.pinned.append(n); continue }
            if !e.mounted { c.unchanged.append(n); continue }
            entries[n]?.mounted = false; c.changed.append(n)
        }
        if !c.changed.isEmpty { bump() }
        return c
    }

    /// Replace the mounted set wholesale (the Engine applies Settings › Tools, a host restores a thread).
    /// Pinned entries stay mounted; unavailable ones stay unmounted.
    public func setMounted(_ names: Set<String>) {
        install()
        var changed = false
        for n in order {
            guard var e = entries[n] else { continue }
            let want = e.available && (names.contains(n) || e.pinned)
            if e.mounted != want { e.mounted = want; entries[n] = e; changed = true }
        }
        if changed { bump() }
    }

    /// Add (or replace) a tool in the catalog. `mounted` defaults to true for a tool registered at runtime — the
    /// point of registering one mid-task is to use it. Pass `available: false` + `reason` for a tool this device
    /// cannot run yet; it is listed, never offered.
    public func register(_ tool: any Tool, source: Source = .session, mounted: Bool = true, pinned: Bool = false,
                         available: Bool = true, reason: String = "") {
        install()
        let wasMounted = entries[tool.name]?.mounted ?? false
        add(Entry(tool: tool, source: source, available: available, reason: reason, mounted: mounted, pinned: pinned))
        if (entries[tool.name]?.mounted ?? false) != wasMounted || wasMounted { bump() }
    }

    /// Remove a tool from the catalog entirely (created tools, session extras). App tools and pinned tools refuse.
    @discardableResult
    public func unregister(_ name: String) -> Bool {
        install()
        guard let e = entries[name], e.source != .app, !e.pinned else { return false }
        entries[name] = nil; order.removeAll { $0 == name }
        if e.mounted { bump() }
        return true
    }

    /// Mark an existing entry runnable / not runnable (an Apple permission granted, a drive unplugged…).
    public func setAvailability(_ name: String, available: Bool, reason: String = "") {
        guard var e = entries[name] else { return }
        e.available = available; e.reason = reason
        if !available, e.mounted { e.mounted = false; entries[name] = e; bump() } else { entries[name] = e }
    }

    public func setCreator(_ c: (any ToolCreator)?) { creator = c }

    /// Observe mounted-set changes (called with the new mounted names, on the registry's executor).
    @discardableResult
    public func observe(_ f: @Sendable @escaping ([String]) -> Void) -> UUID {
        let id = UUID(); observers[id] = f; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }

    private func bump() {
        version += 1
        let names = mountedNames
        for f in observers.values { f(names) }
    }

    /// What one `mount` / `unmount` did.
    public struct Change: Sendable {
        public var changed: [String] = []
        public var unchanged: [String] = []
        public var unknown: [String] = []
        public var unavailable: [(String, String)] = []
        public var pinned: [String] = []
        public init() {}
        public var isEmpty: Bool { changed.isEmpty && unchanged.isEmpty && unknown.isEmpty && unavailable.isEmpty && pinned.isEmpty }
    }
}

/// Lane D's half of `manage_tools create / remove`: turn source code the model wrote into a `Tool` (Swift compiled on a
/// Mac, JavaScript in JavaScriptCore on iPhone), persist it, and hand it to the registry. The registry only knows this
/// protocol; without an implementation the actions say so.
public protocol ToolCreator: Sendable {
    /// Languages this device can load — e.g. `["swift"]` on a Mac, `["javascript"]` on iPhone.
    var languages: [String] { get }
    /// Validate + build. Throw `ToolError` with the compiler's/validator's words when the source is not loadable.
    func create(name: String, source: String, language: String) async throws -> any Tool
    /// Delete the persisted source of a created tool (the registry unregisters it first).
    func remove(name: String) async throws
    /// Created tools saved on this device (name → language), restored at launch by the host.
    func saved() async -> [(name: String, language: String)]
}
