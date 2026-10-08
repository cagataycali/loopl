import Foundation

// `render_ui`: the model emits a small TYPED JSON spec, the app draws it with native SwiftUI.
// Nothing here executes code or loads a web view; the spec is data. Mirrors tiny-tech's `use_render`
// (src/agent/render.ts) vocabulary plus the three native kinds the owner asked for (chart, map, diagram).
//
// Shape (one `type` per component; everything else optional so a 0.8B model can emit it):
//   markdown{content} · keyvalue{title?, data{k:v}} · table{title?, headers[], rows[][]} · list{title?, items[]}
//   chart{title?, kind: bar|line|pie, series:[{name?, points:[{label, value}]}]} (or points[] directly)
//   map{title?, pins:[{lat, lon, label?}], route?:[[lat,lon]]} · diagram{title?, nodes:[{id, label?}], edges:[{from, to, label?}]}
//   progress{description?, total, completed} · image{url? | attachment?, caption?} · rule{title?} · text{content, style?}
// Unknown `type` → `.unknown` — the card SAYS so (never silent), and the tool result tells the model which types exist.

/// One drawable component. Parsing is LENIENT (numbers as strings, missing titles, a bare `points` array on a chart)
/// because the author is a small on-device model; what cannot be read lands in `RenderSpec.issues`, never in a throw.
public enum RenderComponent: Sendable, Hashable {
    case markdown(String)
    case keyvalue(title: String?, data: [KeyValue])
    case table(title: String?, headers: [String], rows: [[String]])
    case list(title: String?, items: [ListItem])
    case chart(title: String?, kind: ChartKind, series: [Series])
    case map(title: String?, pins: [Pin], route: [Coordinate])
    case diagram(title: String?, nodes: [Node], edges: [Edge])
    case progress(description: String?, total: Double, completed: Double)
    case image(url: String?, attachment: Int?, caption: String?)
    case rule(title: String?)
    case text(String, style: TextStyle)
    /// A `type` this build does not know — drawn as an honest card naming it.
    case unknown(type: String)

    public struct KeyValue: Sendable, Hashable { public var key: String; public var value: String
        public init(key: String, value: String) { self.key = key; self.value = value } }
    public struct ListItem: Sendable, Hashable { public var title: String; public var subtitle: String?; public var icon: String?
        public init(title: String, subtitle: String? = nil, icon: String? = nil) { self.title = title; self.subtitle = subtitle; self.icon = icon } }
    public enum ChartKind: String, Sendable, Hashable, CaseIterable { case bar, line, pie }
    public struct Point: Sendable, Hashable { public var label: String; public var value: Double
        public init(label: String, value: Double) { self.label = label; self.value = value } }
    public struct Series: Sendable, Hashable { public var name: String?; public var points: [Point]
        public init(name: String? = nil, points: [Point]) { self.name = name; self.points = points } }
    public struct Coordinate: Sendable, Hashable { public var lat: Double; public var lon: Double
        public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon } }
    public struct Pin: Sendable, Hashable { public var lat: Double; public var lon: Double; public var label: String?
        public init(lat: Double, lon: Double, label: String? = nil) { self.lat = lat; self.lon = lon; self.label = label } }
    public struct Node: Sendable, Hashable { public var id: String; public var label: String
        public init(id: String, label: String? = nil) { self.id = id; self.label = label ?? id } }
    public struct Edge: Sendable, Hashable { public var from: String; public var to: String; public var label: String?
        public init(from: String, to: String, label: String? = nil) { self.from = from; self.to = to; self.label = label } }
    public enum TextStyle: String, Sendable, Hashable, CaseIterable { case plain, secondary, strong, caption, mono }

    /// The `type` word the model used (or `unknown`'s payload) — for the result line and the card header.
    public var kindName: String {
        switch self {
        case .markdown: "markdown"; case .keyvalue: "keyvalue"; case .table: "table"; case .list: "list"; case .chart: "chart"
        case .map: "map"; case .diagram: "diagram"; case .progress: "progress"; case .image: "image"; case .rule: "rule"; case .text: "text"
        case .unknown(let t): "unknown(\(t))"
        }
    }
    /// The title the model gave this component, if the kind carries one.
    public var title: String? {
        switch self {
        case .keyvalue(let t, _), .table(let t, _, _), .list(let t, _), .chart(let t, _, _), .map(let t, _, _), .diagram(let t, _, _), .rule(let t): t
        case .progress(let d, _, _): d
        case .image(_, _, let c): c
        case .markdown, .text, .unknown: nil
        }
    }
    public static let knownTypes = ["markdown", "keyvalue", "table", "list", "chart", "map", "diagram", "progress", "image", "rule", "text"]
}

/// A parsed `render_ui` call: the components in order plus what had to be fixed or dropped on the way.
public struct RenderSpec: Sendable, Hashable {
    public var title: String?
    public var components: [RenderComponent]
    /// Human sentences about what was repaired or skipped ("chart 1: 2 points had no numeric value"). Shown to the
    /// model in the result so it can fix the call; the card shows a quiet line when non-empty.
    public var issues: [String]

    public init(title: String? = nil, components: [RenderComponent], issues: [String] = []) {
        self.title = title; self.components = components; self.issues = issues
    }

    // Caps — the spec is untrusted model output rendered eagerly as SwiftUI views.
    public static let maxComponents = 12, maxRows = 50, maxColumns = 8, maxItems = 60, maxPoints = 120, maxSeries = 6
    public static let maxPins = 50, maxRoute = 500, maxNodes = 40, maxEdges = 80

    /// Parse the tool's arguments. Never throws for content problems — see `issues`; throws only when `components`
    /// is missing or empty (there is nothing to draw, and the model must know that).
    public init(args: [String: JSONValue]) throws {
        var issues: [String] = []
        title = args["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        var raw = args["components"]?.arrayValue ?? []
        if raw.isEmpty, let text = args["components"]?.stringValue {
            // MEASURED (loopl-2b, 2026-10-07): the model sends `components` as a JSON *string* 4/9 times — the right
            // pins and nodes, double-encoded. Decode it (with the two repairs below) instead of drawing the string as prose.
            if let decoded = Self.decodeComponents(text) { raw = decoded; issues.append("`components` was sent as a JSON string — send a plain array next time") }
            else { issues.append("`components` was a string that is not valid JSON — send an array of {type, …} objects") }
        }
        if raw.isEmpty, args["type"]?.stringValue != nil { raw = [.object(args)] }   // a single component passed at the top level
        guard !raw.isEmpty else { throw ToolError("render_ui: `components` is required — a non-empty array of {type, …} objects. Types: \(RenderComponent.knownTypes.joined(separator: ", ")).") }
        // The agent's schema pre-check (ToolValidation) wraps a non-array `components` into a one-element array, so the
        // double-encoded string also arrives as `[ "[{…}]" ]` — unwrap any element that is itself JSON text.
        raw = raw.flatMap { item -> [JSONValue] in
            guard let s = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("[") || s.hasPrefix("{") else { return [item] }
            if let decoded = Self.decodeComponents(s) { issues.append("`components` was sent as a JSON string — send a plain array next time"); return decoded }
            issues.append("a component was a string that is not valid JSON — send {type, …} objects"); return []
        }
        // Stray top-level keys (`edges`, `pins`, `series`, …) — the model split one component across the call (loopl-2b
        // put three edge-less `diagram`s in `components` and `edges` beside them). Attach each to the first component
        // that takes it; edge-less diagrams are merged into one so the edges have their nodes.
        let strayKeys: [String: [String]] = ["edges": ["diagram"], "nodes": ["diagram"], "pins": ["map"], "route": ["map"], "series": ["chart"], "points": ["chart"],
                                             "rows": ["table"], "headers": ["table"], "data": ["keyvalue", "chart"], "items": ["list"]]
        let strays = args.filter { strayKeys[$0.key] != nil }
        if !strays.isEmpty {
            var objs = raw.map { $0.objectValue ?? [:] }
            if strays["edges"] != nil {
                let diagrams = objs.indices.filter { (objs[$0]["type"]?.stringValue ?? "") == "diagram" && objs[$0]["edges"] == nil }
                if diagrams.count > 1 {
                    var merged = objs[diagrams[0]]
                    merged["nodes"] = .array(diagrams.flatMap { objs[$0]["nodes"]?.arrayValue ?? [] })
                    for i in diagrams.dropFirst().reversed() { objs.remove(at: i) }
                    objs[diagrams[0]] = merged
                    issues.append("\(diagrams.count) diagram components had no edges and `edges` was outside — merged into one diagram")
                }
            }
            for (key, value) in strays {
                let v: JSONValue = value.stringValue.flatMap { Self.decodeComponents($0).map(JSONValue.array) } ?? value
                if let i = objs.indices.first(where: { strayKeys[key]!.contains(objs[$0]["type"]?.stringValue ?? "") && objs[$0][key] == nil }) {
                    objs[i][key] = v
                    issues.append("`\(key)` was outside its component — put it inside the \(objs[i]["type"]?.stringValue ?? "") object")
                }
            }
            raw = objs.map(JSONValue.object)
        }
        guard !raw.isEmpty else { throw ToolError("render_ui: `components` must be a non-empty array of {type, …} objects" + (issues.isEmpty ? "" : " — " + issues.joined(separator: "; ")) + ". Types: \(RenderComponent.knownTypes.joined(separator: ", ")).") }
        if raw.count > Self.maxComponents { issues.append("only the first \(Self.maxComponents) of \(raw.count) components were drawn"); raw = Array(raw.prefix(Self.maxComponents)) }
        var out: [RenderComponent] = []
        for (i, item) in raw.enumerated() {
            let n = i + 1
            guard let o = item.objectValue else {
                if let s = item.stringValue { out.append(.markdown(s)); continue }   // a bare string is prose
                issues.append("component \(n) is not an object — skipped"); continue
            }
            out.append(Self.component(o, index: n, issues: &issues))
        }
        components = out
        self.issues = issues
    }

    /// A `components` value that arrived as text. Tries the text as-is, then with trailing commas removed, then with the
    /// shape loopl-2b produced 2/3 times for a diagram — `["diagram", "nodes": […], "edges": […]]` (the opening `{"type":`
    /// collapsed into a bare string) — rewritten to `[{"type": "diagram", …}]`.
    static func decodeComponents(_ text: String) -> [JSONValue]? {
        func parse(_ t: String) -> [JSONValue]? {
            guard let data = t.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            if let a = v.arrayValue { return a }
            if let o = v.objectValue { return o["components"]?.arrayValue ?? [.object(o)] }
            return nil
        }
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = parse(t) { return a }
        // Trailing commas before a closing bracket/brace are the most common model slip.
        t = t.replacingOccurrences(of: #",\s*([\]}])"#, with: "$1", options: .regularExpression)
        // `"points: [` — a key whose closing quote was dropped (loopl-2b, chart run).
        t = t.replacingOccurrences(of: #""([a-z_]+): "#, with: "\"$1\": ", options: .regularExpression)
        if let a = parse(t) { return a }
        // Unbalanced closers: `…]}]}` (one `}` too many) or a truncated tail — rebalance with a bracket stack.
        if let a = parse(balanced(t)) { return a }
        // `[ "kind", "field": …, … ]` → `[{"type": "kind", "field": …, …}]`
        if let r = t.range(of: #"^\[\s*"([a-z_]+)"\s*,"#, options: .regularExpression) {
            let kind = String(t[r]).replacingOccurrences(of: #"[\[\s",]"#, with: "", options: .regularExpression)
            var body = String(t[r.upperBound...])
            if body.hasSuffix("]") { body.removeLast() }
            let fixed = "[{\"type\": \"\(kind)\", " + body + "}]"
            if let a = parse(fixed) { return a }
        }
        return nil
    }

    /// Rebalance `[]`/`{}` outside string literals: drop closers that have no opener, append the closers a truncated
    /// tail is missing. A dangling `"key":` or `,` before the appended closers is removed.
    static func balanced(_ text: String) -> String {
        var out = "", stack: [Character] = [], inString = false, escaped = false
        for ch in text {
            if inString {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true; out.append(ch)
            case "[", "{": stack.append(ch); out.append(ch)
            case "]": if stack.last == "[" { stack.removeLast(); out.append(ch) }     // else: an extra closer — dropped
            case "}": if stack.last == "{" { stack.removeLast(); out.append(ch) }
            default: out.append(ch)
            }
        }
        if inString { out.append("\"") }
        while true {
            let trimmed = out.replacingOccurrences(of: #"(,|"[^"]*"\s*:)\s*$"#, with: "", options: .regularExpression)
            if trimmed == out { break }
            out = trimmed
        }
        for open in stack.reversed() { out.append(open == "[" ? "]" : "}") }
        return out
    }

    // MARK: per-kind parsing

    /// `type` when the model did not say it: loopl-0.8b wrote `{"kind": "map", "pins": …}` 3/3 (a "map"-named kind),
    /// `{"chart": {…}}` and `{"text": "…"}` (the type as the key). Inferred from `kind`, from a type-named key, then from
    /// the fields present — and reported, so the model learns the word is `type`.
    static func inferType(_ o: inout [String: JSONValue], index n: Int, issues: inout [String]) {
        if let t = o["type"]?.stringValue, !t.isEmpty { return }
        func set(_ t: String, _ why: String) { o["type"] = .string(t); issues.append("component \(n): no `type` — read as \(t) (\(why)); say \"type\": \"\(t)\"") }
        if let k = o["kind"]?.stringValue?.lowercased() {
            if RenderComponent.knownTypes.contains(k) { set(k, "from kind"); return }
            if ["bar", "line", "pie"].contains(k) { set("chart", "kind \(k)"); return }
        }
        for key in RenderComponent.knownTypes where o[key] != nil {
            if let inner = o[key]?.objectValue { for (ik, iv) in inner where o[ik] == nil { o[ik] = iv } }
            else if let text = o[key]?.stringValue { if o["content"] == nil { o["content"] = .string(text) } }
            o.removeValue(forKey: key); set(key, "from the key \(key)"); return
        }
        let byFields: [(String, [String])] = [("map", ["pins", "markers", "route"]), ("diagram", ["nodes", "edges"]), ("chart", ["series", "points"]),
                                              ("table", ["rows", "headers", "columns"]), ("progress", ["completed", "total"]), ("list", ["items"]),
                                              ("keyvalue", ["data"]), ("image", ["url", "attachment"]), ("markdown", ["content", "text"])]
        for (t, keys) in byFields where keys.contains(where: { o[$0] != nil }) { set(t, "from its fields"); return }
    }

    private static func component(_ o: [String: JSONValue], index n: Int, issues: inout [String]) -> RenderComponent {
        var o = o
        inferType(&o, index: n, issues: &issues)
        let type = (o["type"]?.stringValue ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let title = str(o["title"]) ?? str(o["label"])
        switch type {
        case "markdown", "md", "panel":
            return .markdown(str(o["content"]) ?? str(o["text"]) ?? str(o["markdown"]) ?? "")
        case "text":
            let style = TextStyleParse.parse(o["style"]?.stringValue)
            return .text(str(o["content"]) ?? str(o["text"]) ?? "", style: style)
        case "rule", "divider", "separator":
            return .rule(title: title)
        case "keyvalue", "kv", "key_value", "keyvalues":
            var data: [RenderComponent.KeyValue] = []
            if let d = o["data"]?.objectValue ?? o["items"]?.objectValue {
                for k in d.keys.sorted() { data.append(.init(key: k, value: scalar(d[k]!))) }
            } else if let arr = o["data"]?.arrayValue ?? o["items"]?.arrayValue {   // [{key,value}] / [{label,value}]
                for e in arr { if let eo = e.objectValue, let k = str(eo["key"]) ?? str(eo["label"]) ?? str(eo["name"]) { data.append(.init(key: k, value: scalar(eo["value"] ?? .null))) } }
            }
            if data.isEmpty { issues.append("keyvalue \(n): `data` {key: value} is empty") }
            return .keyvalue(title: title, data: Array(data.prefix(maxItems)))
        case "table":
            var headers = (o["headers"]?.arrayValue ?? o["columns"]?.arrayValue ?? []).map(scalar)
            var rows: [[String]] = []
            for r in o["rows"]?.arrayValue ?? [] {
                if let cells = r.arrayValue { rows.append(cells.map(scalar)) }
                else if let ro = r.objectValue {                                     // object rows keyed by header
                    if headers.isEmpty { headers = ro.keys.sorted() }
                    rows.append(headers.map { scalar(ro[$0] ?? .null) })
                } else { rows.append([scalar(r)]) }
            }
            let cols = max(headers.count, rows.map(\.count).max() ?? 0)
            if cols > maxColumns { issues.append("table \(n): only the first \(maxColumns) of \(cols) columns were drawn") }
            if rows.count > maxRows { issues.append("table \(n): only the first \(maxRows) of \(rows.count) rows were drawn"); rows = Array(rows.prefix(maxRows)) }
            let width = min(cols, maxColumns)
            headers = Array(headers.prefix(width))
            rows = rows.map { r in (0..<width).map { $0 < r.count ? r[$0] : "" } }   // ragged rows pad, never shift
            if rows.isEmpty, headers.isEmpty { issues.append("table \(n): no `headers` and no `rows`") }
            return .table(title: title, headers: headers, rows: rows)
        case "list", "bullets", "tree":
            var items: [RenderComponent.ListItem] = []
            for e in o["items"]?.arrayValue ?? [] {
                if let eo = e.objectValue {
                    guard let t = str(eo["title"]) ?? str(eo["label"]) ?? str(eo["name"]) ?? str(eo["text"]) else { continue }
                    items.append(.init(title: t, subtitle: str(eo["subtitle"]) ?? str(eo["detail"]) ?? str(eo["value"]) ?? str(eo["description"]), icon: str(eo["icon"])))
                } else { let s = scalar(e); if !s.isEmpty { items.append(.init(title: s)) } }
            }
            if items.isEmpty { issues.append("list \(n): `items` is empty") }
            if items.count > maxItems { issues.append("list \(n): only the first \(maxItems) of \(items.count) items were drawn"); items = Array(items.prefix(maxItems)) }
            return .list(title: title, items: items)
        case "chart", "graph", "bar", "line", "pie":
            var kind = RenderComponent.ChartKind(rawValue: (o["kind"]?.stringValue ?? o["chart"]?.stringValue ?? type).lowercased()) ?? .bar
            if type == "chart" || type == "graph", o["kind"] == nil, o["chart"] == nil { kind = .bar }
            var series: [RenderComponent.Series] = []
            var dropped = 0
            func points(_ v: JSONValue?) -> [RenderComponent.Point] {
                var pts: [RenderComponent.Point] = []
                if let arr = v?.arrayValue {
                    for (i, p) in arr.enumerated() {
                        if let po = p.objectValue {
                            let label = str(po["label"]) ?? str(po["x"]) ?? str(po["name"]) ?? str(po["day"]) ?? String(i + 1)
                            guard let val = num(po["value"] ?? po["y"] ?? po["count"] ?? .null) else { dropped += 1; continue }
                            pts.append(.init(label: label, value: val))
                        } else if let val = num(p) { pts.append(.init(label: String(i + 1), value: val)) }
                        else { dropped += 1 }
                    }
                } else if let d = v?.objectValue {                                   // {Mon: 4000, Tue: 6200}
                    for k in d.keys.sorted() { if let val = num(d[k]!) { pts.append(.init(label: k, value: val)) } else { dropped += 1 } }
                }
                return Array(pts.prefix(maxPoints))
            }
            if let s = o["series"]?.arrayValue {
                for e in s.prefix(maxSeries) {
                    if let eo = e.objectValue { series.append(.init(name: str(eo["name"]) ?? str(eo["label"]), points: points(eo["points"] ?? eo["data"] ?? eo["values"]))) }
                }
            } else if let s = o["series"]?.objectValue {
                series.append(.init(name: str(s["name"]), points: points(s["points"] ?? s["data"])))
            }
            if series.isEmpty, let direct = o["points"] ?? o["data"] ?? o["values"] { series.append(.init(name: nil, points: points(direct))) }
            series.removeAll { $0.points.isEmpty }
            if dropped > 0 { issues.append("chart \(n): \(dropped) point\(dropped == 1 ? "" : "s") had no numeric `value` and were skipped") }
            if series.isEmpty { issues.append("chart \(n): no points — give series:[{points:[{label, value}]}]") }
            return .chart(title: title, kind: kind, series: series)
        case "map":
            var pins: [RenderComponent.Pin] = []
            var bad = 0
            for p in o["pins"]?.arrayValue ?? o["markers"]?.arrayValue ?? o["points"]?.arrayValue ?? [] {
                guard let c = coord(p) else { bad += 1; continue }
                pins.append(.init(lat: c.lat, lon: c.lon, label: p.objectValue.flatMap { str($0["label"]) ?? str($0["name"]) ?? str($0["title"]) }))
            }
            var route: [RenderComponent.Coordinate] = []
            for p in o["route"]?.arrayValue ?? o["path"]?.arrayValue ?? [] { if let c = coord(p) { route.append(c) } else { bad += 1 } }
            if bad > 0 { issues.append("map \(n): \(bad) coordinate\(bad == 1 ? "" : "s") were not {lat, lon} within range and were skipped") }
            if pins.isEmpty, route.isEmpty { issues.append("map \(n): no pins — give pins:[{lat, lon, label}]") }
            return .map(title: title, pins: Array(pins.prefix(maxPins)), route: Array(route.prefix(maxRoute)))
        case "diagram", "flow", "flowchart", "graphviz":
            var nodes: [RenderComponent.Node] = []
            var ids = Set<String>()
            for e in o["nodes"]?.arrayValue ?? [] {
                if let eo = e.objectValue, let id = str(eo["id"]) ?? str(eo["label"]) ?? str(eo["name"]) {
                    if ids.insert(id).inserted { nodes.append(.init(id: id, label: str(eo["label"]) ?? str(eo["title"]) ?? id)) }
                } else { let s = scalar(e); if !s.isEmpty, ids.insert(s).inserted { nodes.append(.init(id: s)) } }
            }
            var edges: [RenderComponent.Edge] = []
            for e in o["edges"]?.arrayValue ?? o["links"]?.arrayValue ?? [] {
                if let eo = e.objectValue, let f = str(eo["from"]) ?? str(eo["source"]), let t = str(eo["to"]) ?? str(eo["target"]) {
                    edges.append(.init(from: f, to: t, label: str(eo["label"])))
                } else if let pair = e.arrayValue, pair.count >= 2 { edges.append(.init(from: scalar(pair[0]), to: scalar(pair[1]), label: pair.count > 2 ? scalar(pair[2]) : nil)) }
                else if let s = e.stringValue, let arrow = s.range(of: "->") {   // "login -> verify"
                    edges.append(.init(from: s[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces), to: s[arrow.upperBound...].trimmingCharacters(in: .whitespaces)))
                }
            }
            // Edges may name nodes the list forgot — add them so the drawing is complete rather than missing arrows.
            for e in edges { for id in [e.from, e.to] where ids.insert(id).inserted { nodes.append(.init(id: id)) } }
            if nodes.count > maxNodes { issues.append("diagram \(n): only the first \(maxNodes) of \(nodes.count) nodes were drawn"); nodes = Array(nodes.prefix(maxNodes)) }
            let kept = Set(nodes.map(\.id))
            edges = Array(edges.filter { kept.contains($0.from) && kept.contains($0.to) }.prefix(maxEdges))
            if nodes.isEmpty { issues.append("diagram \(n): no nodes — give nodes:[{id, label}] and edges:[{from, to}]") }
            return .diagram(title: title, nodes: nodes, edges: edges)
        case "progress":
            let total = num(o["total"] ?? .null) ?? 100
            let done = num(o["completed"] ?? o["value"] ?? o["done"] ?? .null) ?? 0
            if total <= 0 { issues.append("progress \(n): `total` must be > 0 (used 100)") }
            return .progress(description: str(o["description"]) ?? title, total: total > 0 ? total : 100, completed: max(0, done))
        case "image", "photo", "picture":
            let url = str(o["url"]) ?? str(o["src"])
            let attachment = num(o["attachment"] ?? o["index"] ?? .null).map { Int($0) }
            if url == nil, attachment == nil { issues.append("image \(n): give `url` (https) or `attachment` (0 = the first picture in the user's message)") }
            return .image(url: url, attachment: attachment, caption: str(o["caption"]) ?? title)
        default:
            issues.append("component \(n): unknown type \"\(type.isEmpty ? "(missing)" : type)\" — known: \(RenderComponent.knownTypes.joined(separator: ", "))")
            return .unknown(type: type.isEmpty ? "(missing)" : type)
        }
    }

    // MARK: coercions (small models send numbers as strings and strings as numbers)
    private static func str(_ v: JSONValue?) -> String? {
        guard let v else { return nil }
        switch v {
        case .string(let s): return s.isEmpty ? nil : s
        case .number, .bool: return v.compact
        default: return nil
        }
    }
    private static func scalar(_ v: JSONValue) -> String {
        switch v {
        case .null: return ""
        case .string(let s): return s
        case .number, .bool: return v.compact
        case .array, .object: return v.compact
        }
    }
    private static func num(_ v: JSONValue) -> Double? {
        switch v {
        case .number(let n): return n.isFinite ? n : nil
        case .string(let s):
            let cleaned = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            if let d = Double(cleaned), d.isFinite { return d }
            if cleaned.lowercased().hasSuffix("k"), let d = Double(cleaned.dropLast()) { return d * 1000 }   // "4k" → 4000
            if cleaned.lowercased().hasSuffix("m"), let d = Double(cleaned.dropLast()) { return d * 1_000_000 }
            return nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    private static func coord(_ v: JSONValue) -> RenderComponent.Coordinate? {
        var lat: Double?, lon: Double?
        if let o = v.objectValue {
            lat = num(o["lat"] ?? o["latitude"] ?? .null); lon = num(o["lon"] ?? o["lng"] ?? o["long"] ?? o["longitude"] ?? .null)
        } else if let a = v.arrayValue, a.count >= 2 { lat = num(a[0]); lon = num(a[1]) }
        guard let lat, let lon, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return .init(lat: lat, lon: lon)
    }

    /// What the model reads back: enough to know the card is on screen (so it does not repeat the data in prose)
    /// plus every repair, so a bad call can be corrected on the next step.
    public var resultText: String {
        let kinds = components.map(\.kindName)
        var s = "rendered \(components.count) component\(components.count == 1 ? "" : "s") (\(kinds.joined(separator: ", "))). The user sees the card — do not repeat the same data in prose."
        // MEASURED (loopl-0.8b): a line labelled `issues:` read as "it failed" → the model re-sent the same card 4×. The
        // card IS drawn; the notes are for next time, and the result says so in those words.
        if !issues.isEmpty { s += "\nnotes (the card above is already drawn — do not send it again; for your next call): " + issues.joined(separator: "; ") }
        return s
    }
}

private enum TextStyleParse {
    static func parse(_ s: String?) -> RenderComponent.TextStyle {
        switch (s ?? "").lowercased() {
        case "secondary", "muted", "gray", "grey", "dim": .secondary
        case "strong", "bold", "title", "headline": .strong
        case "caption", "small", "footnote": .caption
        case "mono", "code", "monospace": .mono
        default: .plain
        }
    }
}

/// The tool. Validation is the spec parser; the drawing is the host's (`RenderCard` in LooplUI reads the saved
/// `ToolUse.input` back through `RenderSpec(args:)`, so a card in History re-renders from the same bytes).
public struct RenderUITool: Tool {
    public static let toolName = "render_ui"
    public init() {}
    public let name = RenderUITool.toolName
    public let description = """
    Show the user a native card instead of prose — call it DIRECTLY with the data (no calculator first) whenever the answer is \
    numbers over categories or time (a chart), places (a map), steps or a flow (a diagram), or structured data (table, keyvalue, list). \
    components is an ARRAY of objects, each with a type: \
    {"type":"chart","kind":"bar","series":[{"name":"steps","points":[{"label":"Mon","value":4000},{"label":"Tue","value":6200}]}]} · \
    {"type":"map","pins":[{"lat":40.74,"lon":-74.03,"label":"bwè kafe"}],"route":[[40.74,-74.03],[40.75,-74.02]]} · \
    {"type":"diagram","nodes":[{"id":"open","label":"Open app"},{"id":"home","label":"Home"}],"edges":[{"from":"open","to":"home","label":"ok"}]} · \
    table{headers,rows} · keyvalue{data:{key:value}} · list{items} · progress{description,total,completed} · markdown{content} · text{content} · image{url|attachment} · rule{title}. \
    kind is bar, line or pie; values are numbers (4000, not "4k"). The card appears in the chat; afterwards answer in one short \
    sentence and do not repeat the data.
    """
    public let parameters: JSONValue = ["type": "object", "properties": [
        "title": ["type": "string", "description": "optional heading for the whole card"],
        "components": ["type": "array", "description": "one or more components, drawn top to bottom", "items": ["type": "object", "properties": [
            "type": ["type": "string", "enum": .array(RenderComponent.knownTypes.map(JSONValue.string)), "description": "which component this is"],
            "title": ["type": "string"],
            "content": ["type": "string", "description": "markdown / text: the prose"],
            "style": ["type": "string", "enum": .array(RenderComponent.TextStyle.allCases.map { .string($0.rawValue) }), "description": "text only"],
            "data": ["type": "object", "description": "keyvalue: {key: value}"],
            "headers": ["type": "array", "items": ["type": "string"], "description": "table column names"],
            "rows": ["type": "array", "items": ["type": "array", "items": ["type": "string"]], "description": "table rows, one array of cells per row"],
            "items": ["type": "array", "description": "list: strings or {title, subtitle, icon}"],
            "kind": ["type": "string", "enum": ["bar", "line", "pie"], "description": "chart kind (default bar)"],
            "series": ["type": "array", "description": "chart: [{name, points:[{label, value}]}]", "items": ["type": "object", "properties": [
                "name": ["type": "string"],
                "points": ["type": "array", "items": ["type": "object", "properties": ["label": ["type": "string"], "value": ["type": "number"]], "required": ["label", "value"]]]],
                "required": ["points"]]],
            "pins": ["type": "array", "description": "map: [{lat, lon, label}]", "items": ["type": "object", "properties": [
                "lat": ["type": "number"], "lon": ["type": "number"], "label": ["type": "string"]], "required": ["lat", "lon"]]],
            "route": ["type": "array", "description": "map: optional polyline [[lat, lon], …]", "items": ["type": "array", "items": ["type": "number"]]],
            "nodes": ["type": "array", "description": "diagram: [{id, label}]", "items": ["type": "object", "properties": ["id": ["type": "string"], "label": ["type": "string"]], "required": ["id"]]],
            "edges": ["type": "array", "description": "diagram: [{from, to, label}] using node ids", "items": ["type": "object", "properties": [
                "from": ["type": "string"], "to": ["type": "string"], "label": ["type": "string"]], "required": ["from", "to"]]],
            "description": ["type": "string", "description": "progress: what is being measured"],
            "total": ["type": "number", "description": "progress: the whole"],
            "completed": ["type": "number", "description": "progress: how much is done"],
            "url": ["type": "string", "description": "image: https URL"],
            "attachment": ["type": "integer", "description": "image: index of a picture in the user's latest message (0 = first)"],
            "caption": ["type": "string"]],
            "required": ["type"]]]],
        "required": ["components"]]

    public func call(_ args: [String: JSONValue]) async throws -> String {
        try RenderSpec(args: args).resultText
    }
    /// `image{attachment: i}` hands the user's own picture back as the result image so the card can show it natively.
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput {
        let spec = try RenderSpec(args: args)
        var out: [ImageBlock] = []
        var issues = spec.issues
        for c in spec.components { if case .image(let url, let i?, _) = c, url == nil {
            if images.indices.contains(i) { out.append(images[i]) } else { issues.append("image: attachment \(i) does not exist (the message has \(images.count) picture\(images.count == 1 ? "" : "s"))") }
        } }
        var fixed = spec; fixed.issues = issues
        return ToolOutput(text: fixed.resultText, images: out)
    }
}
