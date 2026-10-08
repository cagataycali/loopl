import SwiftUI
import Loopl
import Charts
#if canImport(MapKit)
import MapKit
#endif

// MARK: - render_ui card
//
// The model emits a typed spec (`RenderSpec`, Sources/Loopl/RenderUI.swift); this file DRAWS it with native SwiftUI:
// Swift Charts for `chart`, MapKit for `map` (tap opens Apple Maps), a Canvas for `diagram` (layered node-edge graph,
// no mermaid engine), the transcript's own `MarkdownBody`/`MarkdownTable` for prose and tables. Nothing here executes
// code or loads a web view — a bad spec draws an honest card that says what it could not read.
//
// Where it sits: a `render_ui` call is an ordinary tool row (mark · render_ui · ✓, tap for the raw arguments), and
// the card hangs under it in the same chrome as AgentCard/ApprovalCard. The card re-renders from the saved
// `ToolUse.input` on every launch (History stores arguments in full), so there is no second persistence path.

/// The row for a `render_ui` call: the tool row, then the drawn card. `images` are the tool's result images
/// (an `image{attachment}` component hands the user's picture back through `ToolOutput.images`).
public struct RenderCard: View {
    public var call: ToolUse
    public var result: ToolResult?
    public var spec: RenderSpec
    public var images: [ImageBlock]
    public init(call: ToolUse, result: ToolResult?, spec: RenderSpec, images: [ImageBlock] = []) {
        self.call = call; self.result = result; self.spec = spec; self.images = images
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ToolRow(call: call, result: result)
            RenderBody(spec: spec, images: images)
                .accessibilityIdentifier("render-card-\(call.toolUseId)")
        }
    }
}

/// The drawn card alone (used by the row above and by fixtures/previews).
public struct RenderBody: View {
    public var spec: RenderSpec
    public var images: [ImageBlock]
    @Environment(\.dynamicTypeSize) private var typeSize
    public init(spec: RenderSpec, images: [ImageBlock] = []) { self.spec = spec; self.images = images }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let t = spec.title, !t.isEmpty {
                Text(t).font(.headline).foregroundStyle(.primary).accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(spec.components.enumerated()), id: \.offset) { i, c in
                RenderComponentView(component: c, index: i, images: images)
            }
            if !spec.issues.isEmpty {
                // Quiet, but present: the model was told the same thing in its result.
                Label(spec.issues.joined(separator: " · "), systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .accessibilityLabel("render issues: \(spec.issues.joined(separator: ". "))")
                    .accessibilityIdentifier("render-issues")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(LooplDesign.accent.opacity(0.5)).frame(width: 2).padding(.vertical, 12)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spec.title.map { "card: \($0)" } ?? "card")
    }
}

/// One component. Each kind carries its own VoiceOver summary so the card reads as data, not as "image".
struct RenderComponentView: View {
    let component: RenderComponent
    let index: Int
    let images: [ImageBlock]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        switch component {
        case .markdown(let s):
            MarkdownBody(s)
        case .text(let s, let style):
            styledText(s, style)
        case .rule(let title):
            RenderRule(title: title)
        case .keyvalue(let title, let data):
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(title)
                RenderKeyValue(data: data)
            }
        case .table(let title, let headers, let rows):
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(title)
                MarkdownTable(header: headers.isEmpty ? Array(repeating: "", count: rows.first?.count ?? 0) : headers, rows: rows)
            }
            .accessibilityElement(children: .contain)
        case .list(let title, let items):
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(title)
                RenderList(items: items)
            }
        case .chart(let title, let kind, let series):
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(title)
                RenderChart(kind: kind, series: series)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(RenderA11y.chart(title: title, kind: kind, series: series))
            .accessibilityIdentifier("render-chart-\(index)")
        case .map(let title, let pins, let route):
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(title)
                RenderMap(pins: pins, route: route)
            }   // no identifier on the wrapper: SwiftUI would stamp it on every child and hide the map button's own `render-map`
        case .diagram(let title, let nodes, let edges):
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(title)
                RenderDiagram(nodes: nodes, edges: edges)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(RenderA11y.diagram(title: title, nodes: nodes, edges: edges))
            .accessibilityIdentifier("render-diagram-\(index)")
        case .progress(let description, let total, let completed):
            RenderProgress(description: description, total: total, completed: completed)
        case .image(let url, let attachment, let caption):
            RenderImage(url: url, attachment: attachment, caption: caption, images: images)
        case .unknown(let type):
            // Never silent: the card names the type the model invented, the result told the model the known ones.
            Label("unknown component type “\(type)”", systemImage: "questionmark.square.dashed")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.tertiary))
                .accessibilityIdentifier("render-unknown-\(index)")
        }
    }

    @ViewBuilder private func sectionTitle(_ t: String?) -> some View {
        if let t, !t.isEmpty { Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader) }
    }

    @ViewBuilder private func styledText(_ s: String, _ style: RenderComponent.TextStyle) -> some View {
        switch style {
        case .plain: Text(MarkdownBody.inline(s)).font(.body).textSelection(.enabled)
        case .secondary: Text(MarkdownBody.inline(s)).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
        case .strong: Text(MarkdownBody.inline(s)).font(.body.weight(.semibold)).textSelection(.enabled)
        case .caption: Text(MarkdownBody.inline(s)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        case .mono: Text(s).font(.callout.monospaced()).textSelection(.enabled)
        }
    }
}

// MARK: - Simple kinds

struct RenderRule: View {
    let title: String?
    var body: some View {
        if let title, !title.isEmpty {
            HStack(spacing: 10) {
                Rectangle().fill(.tertiary).frame(height: 1)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.tertiary).fixedSize()
                Rectangle().fill(.tertiary).frame(height: 1)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("section: \(title)")
        } else {
            Divider()
        }
    }
}

struct RenderKeyValue: View {
    let data: [RenderComponent.KeyValue]
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if typeSize.isAccessibilitySize {
            // AX sizes: a two-column grid squeezes values to one word per line — stack instead.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(data, id: \.key) { kv in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kv.key).font(.caption).foregroundStyle(.secondary)
                        Text(MarkdownBody.inline(kv.value)).font(.body.weight(.medium)).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(kv.key): \(kv.value)")
                }
            }
        } else {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(data, id: \.key) { kv in
                    GridRow {
                        Text(kv.key).font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text(MarkdownBody.inline(kv.value)).font(.callout.weight(.medium)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(kv.key): \(kv.value)")
                }
            }
        }
    }
}

struct RenderList: View {
    let items: [RenderComponent.ListItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let icon = item.icon, !icon.isEmpty {
                        Image(systemName: icon).font(.callout).foregroundStyle(LooplDesign.accent).frame(width: 20).accessibilityHidden(true)
                    } else {
                        Circle().fill(.tertiary).frame(width: 5, height: 5).padding(.top, 1).frame(width: 20).accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(MarkdownBody.inline(item.title)).font(.callout)
                        if let s = item.subtitle, !s.isEmpty { Text(MarkdownBody.inline(s)).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.subtitle.map { "\(item.title), \($0)" } ?? item.title)
            }
        }
    }
}

struct RenderProgress: View {
    let description: String?
    let total: Double
    let completed: Double
    private var fraction: Double { total > 0 ? min(1, max(0, completed / total)) : 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let description, !description.isEmpty { Text(description).font(.callout) }
                Spacer(minLength: 8)
                Text("\(Int((fraction * 100).rounded())) %").font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).tint(LooplDesign.accent)
            Text("\(RenderA11y.number(completed)) of \(RenderA11y.number(total))").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(description ?? "progress"): \(Int((fraction * 100).rounded())) percent, \(RenderA11y.number(completed)) of \(RenderA11y.number(total))")
    }
}

struct RenderImage: View {
    let url: String?
    let attachment: Int?
    let caption: String?
    let images: [ImageBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url, let u = URL(string: url), u.scheme?.hasPrefix("http") == true {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    case .failure: Label("picture could not be loaded", systemImage: "photo.badge.exclamationmark").font(.footnote).foregroundStyle(.secondary).padding(12)
                    default: ProgressView().padding(24)
                    }
                }
                .frame(maxWidth: .infinity).frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(caption ?? "picture")
            } else if attachment != nil, !images.isEmpty {
                ToolImagesView(images)
            } else {
                Label(url == nil ? "no picture was attached" : "unsupported image address", systemImage: "photo.badge.exclamationmark")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let caption, !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Chart (Swift Charts)

private struct ChartDatum: Identifiable {
    let id: Int
    let series: String
    let label: String
    let value: Double
}

struct RenderChart: View {
    let kind: RenderComponent.ChartKind
    let series: [RenderComponent.Series]
    @Environment(\.dynamicTypeSize) private var typeSize

    private var data: [ChartDatum] {
        var out: [ChartDatum] = []
        for (si, s) in series.enumerated() {
            let name = s.name ?? (series.count > 1 ? "series \(si + 1)" : "")
            for p in s.points { out.append(ChartDatum(id: out.count, series: name, label: p.label, value: p.value)) }
        }
        return out
    }
    private var labelCount: Int { Set(data.map(\.label)).count }
    private var multi: Bool { series.count > 1 }
    /// Pie reads the FIRST series (a pie of several series has no meaning).
    private var pieData: [ChartDatum] { series.first?.points.enumerated().map { ChartDatum(id: $0.offset, series: "", label: $0.element.label, value: max(0, $0.element.value)) } ?? [] }

    var body: some View {
        let height: CGFloat = typeSize.isAccessibilitySize ? 240 : 200
        Group {
            switch kind {
            case .bar:
                Chart(data) { d in
                    BarMark(x: .value("Label", d.label), y: .value("Value", d.value))
                        .foregroundStyle(by: .value("Series", d.series))
                        .position(by: .value("Series", d.series))
                        .cornerRadius(4)
                }
                .chartForegroundStyleScale(range: palette)
                .chartLegend(multi ? .visible : .hidden)
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel().font(.caption2) } }
            case .line:
                Chart(data) { d in
                    LineMark(x: .value("Label", d.label), y: .value("Value", d.value))
                        .foregroundStyle(by: .value("Series", d.series))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    if labelCount <= 24 {
                        PointMark(x: .value("Label", d.label), y: .value("Value", d.value))
                            .foregroundStyle(by: .value("Series", d.series))
                            .symbolSize(28)
                    }
                }
                .chartForegroundStyleScale(range: palette)
                .chartLegend(multi ? .visible : .hidden)
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel().font(.caption2) } }
            case .pie:
                HStack(alignment: .center, spacing: 16) {
                    Chart(pieData) { d in
                        SectorMark(angle: .value("Value", d.value), innerRadius: .ratio(0.58), angularInset: 1.5)
                            .foregroundStyle(by: .value("Label", d.label))
                            .cornerRadius(3)
                    }
                    .chartForegroundStyleScale(range: palette)
                    .chartLegend(.hidden)
                    .frame(width: height - 40, height: height - 40)
                    // Our own legend: label · value · share — the built-in one hides the numbers.
                    VStack(alignment: .leading, spacing: 6) {
                        let total = pieData.reduce(0) { $0 + $1.value }
                        ForEach(Array(pieData.enumerated()), id: \.offset) { i, d in
                            HStack(spacing: 8) {
                                Circle().fill(palette[i % palette.count]).frame(width: 8, height: 8)
                                Text(d.label).font(.caption).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(total > 0 ? "\(Int((d.value / total * 100).rounded())) %" : "–").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .padding(.top, 4)
    }

    private var palette: [Color] {
        [LooplDesign.accent, Color(red: 0.35, green: 0.55, blue: 0.95), Color(red: 0.25, green: 0.72, blue: 0.55),
         LooplDesign.amber, Color(red: 0.75, green: 0.45, blue: 0.9), Color(red: 0.95, green: 0.4, blue: 0.5)]
    }
}

// MARK: - Map (MapKit)

struct RenderMap: View {
    let pins: [RenderComponent.Pin]
    let route: [RenderComponent.Coordinate]
    @Environment(\.looplStaticRender) private var staticRender

    #if canImport(MapKit)
    private var region: MKCoordinateRegion {
        let coords = pins.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } + route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard let first = coords.first else { return MKCoordinateRegion(center: .init(latitude: 0, longitude: 0), span: .init(latitudeDelta: 60, longitudeDelta: 60)) }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for c in coords { minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude); minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude) }
        let span = MKCoordinateSpan(latitudeDelta: max(0.012, (maxLat - minLat) * 1.6), longitudeDelta: max(0.012, (maxLon - minLon) * 1.6))
        return MKCoordinateRegion(center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2), span: span)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(region), interactionModes: []) {
                if route.count > 1 {
                    MapPolyline(coordinates: route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(LooplDesign.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array(pins.enumerated()), id: \.offset) { i, p in
                    Marker(p.label ?? "pin \(i + 1)", coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)).tint(LooplDesign.accent)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Label("Open in Maps", systemImage: "arrow.up.right.square").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule()).padding(8)
                    .accessibilityHidden(true)
            }
            .accessibilityHidden(true)   // MapKit's own tree is noise here; the tap layer below is the one spoken element
            .overlay {
                // One clear layer owns the tap and the accessibility: a button named by its pins ("map with 3 pins: …"),
                // which XCUITest and VoiceOver both see — MapKit's view does not reliably expose an identifier.
                Button(action: openInMaps) {
                    Color.clear.contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(RenderA11y.map(pins: pins, route: route))
                .accessibilityHint("opens in Maps")
                .accessibilityIdentifier("render-map")
            }
            if !pins.isEmpty {
                // The pins as text under the map: what the labels say, readable without the map and by VoiceOver.
                Text(pins.enumerated().map { i, p in p.label ?? "pin \(i + 1)" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func openInMaps() {
        guard !staticRender else { return }
        let items = pins.prefix(10).map { p -> MKMapItem in
            let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)))
            item.name = p.label ?? "pin"
            return item
        }
        if items.isEmpty, let c = route.first {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)))
            item.name = "route"
            item.openInMaps(launchOptions: nil); return
        }
        MKMapItem.openMaps(with: Array(items), launchOptions: [MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: region.center),
                                                              MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: region.span)])
    }
    #else
    var body: some View { Label("map (MapKit unavailable)", systemImage: "map").font(.footnote).foregroundStyle(.secondary) }
    #endif
}

// MARK: - Diagram (Canvas; layered node-edge graph)

/// Pure layout: nodes in layers (longest path from a source; cycles broken by order), each layer one row,
/// nodes spread across the width. Public-ish so the layering is unit-tested without a Canvas.
public struct DiagramLayout: Sendable, Hashable {
    public var layers: [[String]]     // node ids, top to bottom
    /// Edges that point back up the flow ("retry" → the form): drawn, but not used for layering.
    public var backEdges: Set<Int>    // indices into `edges`
    public init(nodes: [RenderComponent.Node], edges: [RenderComponent.Edge]) {
        let ids = nodes.map(\.id)
        // 1. DFS in node order (the first node is the presumed start) marks back edges — an edge to a node still on
        //    the stack. Everything else is a DAG, so longest-path layering below is well defined.
        var out: [String: [(to: String, index: Int)]] = [:]
        for (i, e) in edges.enumerated() where e.from != e.to { out[e.from, default: []].append((e.to, i)) }
        var state: [String: Int] = [:]           // 1 = on stack, 2 = done
        var back = Set<Int>()
        func visit(_ id: String) {
            state[id] = 1
            for (to, i) in out[id] ?? [] {
                switch state[to] {
                case 1: back.insert(i)
                case 2: break
                default: visit(to)
                }
            }
            state[id] = 2
        }
        for id in ids where state[id] == nil { visit(id) }
        var incoming: [String: [String]] = [:]
        for (i, e) in edges.enumerated() where e.from != e.to && !back.contains(i) { incoming[e.to, default: []].append(e.from) }
        var depth: [String: Int] = [:]
        func layer(_ id: String) -> Int {
            if let d = depth[id] { return d }
            let d = (incoming[id] ?? []).map { layer($0) + 1 }.max() ?? 0
            depth[id] = d
            return d
        }
        for id in ids { _ = layer(id) }
        let maxDepth = depth.values.max() ?? 0
        var rows = Array(repeating: [String](), count: maxDepth + 1)
        for id in ids { rows[depth[id] ?? 0].append(id) }
        layers = rows.filter { !$0.isEmpty }
        backEdges = back
    }
}

struct RenderDiagram: View {
    let nodes: [RenderComponent.Node]
    let edges: [RenderComponent.Edge]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var layout: DiagramLayout { DiagramLayout(nodes: nodes, edges: edges) }
    private var rowHeight: CGFloat { typeSize.isAccessibilitySize ? 84 : 64 }
    private var height: CGFloat { max(96, CGFloat(layout.layers.count) * rowHeight + 16) }

    var body: some View {
        let labels = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.label) })
        Canvas(rendersAsynchronously: false) { ctx, size in
            let layers = layout.layers
            guard !layers.isEmpty else { return }
            let nodeH: CGFloat = typeSize.isAccessibilitySize ? 52 : 40
            var frames: [String: CGRect] = [:]
            // A node is as wide as its label on one line; when a row would overflow, every node in it shrinks
            // proportionally (labels then wrap to two lines) — a long label never truncates while its neighbours have air.
            for (li, layer) in layers.enumerated() {
                let y = 8 + CGFloat(li) * rowHeight + (rowHeight - nodeH) / 2
                let gaps = CGFloat(layer.count - 1) * 10
                var widths: [CGFloat] = layer.map { id in
                    let t = ctx.resolve(Text(labels[id] ?? id).font(.footnote.weight(.medium)))
                    return min(size.width - 8, t.measure(in: CGSize(width: size.width, height: nodeH)).width + 20)
                }
                let natural = widths.reduce(0, +)
                if natural + gaps > size.width - 8 {
                    let scale = (size.width - 8 - gaps) / natural
                    widths = widths.map { max(56, $0 * scale) }
                }
                let total = widths.reduce(0, +) + gaps
                var x = max(4, (size.width - total) / 2)
                for (i, id) in layer.enumerated() {
                    frames[id] = CGRect(x: x, y: y, width: widths[i], height: nodeH)
                    x += widths[i] + 10
                }
            }
            let ink = Color.primary
            let edgeTint = Color.secondary
            // Edges first (under the nodes): a cubic from the bottom-centre of `from` to the top-centre of `to`,
            // arrowhead at the target; an edge going UP (cycle) leaves from the top and curves around.
            for e in edges {
                guard let a = frames[e.from], let b = frames[e.to], e.from != e.to else { continue }
                let down = b.minY >= a.maxY
                let start = down ? CGPoint(x: a.midX, y: a.maxY) : CGPoint(x: a.midX, y: a.minY)
                let end = down ? CGPoint(x: b.midX, y: b.minY) : CGPoint(x: b.midX, y: b.maxY)
                var path = Path()
                path.move(to: start)
                let dy = (end.y - start.y) / 2
                if down {
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + dy), control2: CGPoint(x: end.x, y: end.y - dy))
                } else {
                    // Going back up: arc out to the side so the line does not cut through the rows in between.
                    let side = min(90, size.width * 0.28) * (start.x >= size.width / 2 ? 1 : -1)
                    path.addCurve(to: end, control1: CGPoint(x: start.x + side, y: start.y + dy * 0.6), control2: CGPoint(x: end.x + side, y: end.y - dy * 0.6))
                }
                ctx.stroke(path, with: .color(edgeTint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                // Arrowhead.
                var head = Path()
                let dir: CGFloat = down ? 1 : -1
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x - 4.5, y: end.y - 7 * dir))
                head.addLine(to: CGPoint(x: end.x + 4.5, y: end.y - 7 * dir))
                head.closeSubpath()
                ctx.fill(head, with: .color(edgeTint))
                if let l = e.label, !l.isEmpty {
                    var mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                    if !down { mid.x += min(90, size.width * 0.28) * 0.75 * (start.x >= size.width / 2 ? 1 : -1) }   // on the arc, not on the nodes
                    let t = ctx.resolve(Text(l).font(.caption2).foregroundStyle(.secondary))
                    let s = t.measure(in: CGSize(width: 120, height: 40))
                    let bg = CGRect(x: mid.x - s.width / 2 - 4, y: mid.y - s.height / 2 - 1, width: s.width + 8, height: s.height + 2)
                    ctx.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(scheme == .dark ? Color(white: 0.11) : Color(white: 0.96)))
                    ctx.draw(t, at: mid)
                }
            }
            for (id, r) in frames {
                let shape = Path(roundedRect: r, cornerRadius: 9)
                ctx.fill(shape, with: .color(LooplDesign.accent.opacity(scheme == .dark ? 0.18 : 0.12)))
                ctx.stroke(shape, with: .color(LooplDesign.accent.opacity(0.7)), lineWidth: 1)
                let t = ctx.resolve(Text(labels[id] ?? id).font(.footnote.weight(.medium)).foregroundStyle(ink))
                ctx.draw(t, in: r.insetBy(dx: 7, dy: 3))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)   // the parent carries the spoken summary (RenderA11y.diagram)
    }
}

// MARK: - Spoken summaries

enum RenderA11y {
    static func number(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(format: "%.2f", v)
    }
    static func chart(title: String?, kind: RenderComponent.ChartKind, series: [RenderComponent.Series]) -> String {
        var s = "\(kind.rawValue) chart" + (title.map { " \($0)" } ?? "")
        for (i, ser) in series.prefix(3).enumerated() {
            let name = ser.name ?? (series.count > 1 ? "series \(i + 1)" : "")
            let pts = ser.points.prefix(12).map { "\($0.label) \(number($0.value))" }.joined(separator: ", ")
            s += (name.isEmpty ? ": " : "; \(name): ") + pts
            if ser.points.count > 12 { s += ", and \(ser.points.count - 12) more" }
        }
        return s
    }
    static func map(pins: [RenderComponent.Pin], route: [RenderComponent.Coordinate]) -> String {
        var s = "map with \(pins.count) pin\(pins.count == 1 ? "" : "s")"
        let names = pins.compactMap(\.label).prefix(6)
        if !names.isEmpty { s += ": " + names.joined(separator: ", ") }
        if route.count > 1 { s += "; with a route of \(route.count) points" }
        return s
    }
    static func diagram(title: String?, nodes: [RenderComponent.Node], edges: [RenderComponent.Edge]) -> String {
        let labels = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.label) })
        var s = "diagram" + (title.map { " \($0)" } ?? "") + " with \(nodes.count) steps"
        let steps = edges.prefix(10).map { "\(labels[$0.from] ?? $0.from) to \(labels[$0.to] ?? $0.to)" + ($0.label.map { " (\($0))" } ?? "") }
        if !steps.isEmpty { s += ": " + steps.joined(separator: "; ") }
        else { s += ": " + nodes.map(\.label).joined(separator: ", ") }
        return s
    }
}
