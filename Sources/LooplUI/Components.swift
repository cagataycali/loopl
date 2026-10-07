import SwiftUI
import Loopl

// MARK: - Markdown body (a tiny block renderer: paragraphs, headings, bullets, fenced code)

/// Readable Markdown for an assistant turn: 17 pt body, comfortable line
/// spacing, monospaced code cards. Inline Markdown goes through
/// `AttributedString(markdown:)`; blocks are split here so code fences and
/// lists survive streaming (a half-open fence renders as code).
public struct MarkdownBody: View {
    public var text: String
    public var streaming: Bool
    public init(_ text: String, streaming: Bool = false) { self.text = text; self.streaming = streaming }

    public enum Block: Hashable, Sendable {
        case paragraph(String), heading(Int, String), bullet([String]), numbered([String]), code(String, lang: String)
        /// A pipe table: header cells, then rows (ragged rows are padded / cut to the header's width).
        case table(header: [String], rows: [[String]])
        /// `> quoted` lines, joined.
        case quote(String)
        /// `---` / `***` / `___` on a line of its own.
        case rule
    }

    /// `| a | b |` → ["a", "b"]; the alignment row `|---|:-:|` is recognised by `isTableRule`.
    nonisolated static func tableCells(_ line: String) -> [String]? {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return nil }
        t.removeFirst(); if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
    nonisolated static func isTableRule(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { c in c.count >= 1 && c.allSatisfy { $0 == "-" || $0 == ":" } && c.contains("-") }
    }
    nonisolated static func isHorizontalRule(_ t: String) -> Bool {
        guard t.count >= 3 else { return false }
        let c = t.first!
        return (c == "-" || c == "*" || c == "_") && t.allSatisfy { $0 == c }
    }

    /// The block structure of `s` — public so streaming stability (a prefix must not re-flow when the next
    /// token arrives) is unit-tested.
    nonisolated public static func blocks(_ s: String, streaming: Bool = false) -> [Block] {
        var s = s
        // While streaming, a last line that is only the START of a block marker ("1", "12.", "`", "``") is held
        // back for one token: rendered as a paragraph it would re-flow into a list / code card when the marker
        // completes, and the whole document below the fold would move. Final text is never trimmed.
        if streaming {
            let start = s.lastIndex(of: "\n").map { s.index(after: $0) } ?? s.startIndex
            if Self.isMarkerPrefix(s[start...].trimmingCharacters(in: .whitespaces)) { s = String(s[..<start]) }
        }
        var out: [Block] = []
        var para: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var quote: [String] = []
        var table: (header: [String], rows: [[String]])? = nil
        var code: [String]? = nil
        var lang = ""
        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para.removeAll() } }
        func flushLists() {
            if !bullets.isEmpty { out.append(.bullet(bullets)); bullets.removeAll() }
            if !numbers.isEmpty { out.append(.numbered(numbers)); numbers.removeAll() }
        }
        func flushQuote() { if !quote.isEmpty { out.append(.quote(quote.joined(separator: " "))); quote.removeAll() } }
        func flushTable() {
            guard let t = table else { return }
            let w = t.header.count
            out.append(.table(header: t.header, rows: t.rows.map { r in Array((r + Array(repeating: "", count: max(0, w - r.count))).prefix(w)) }))
            table = nil
        }
        func flushAll() { flushPara(); flushLists(); flushQuote(); flushTable() }
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if var c = code {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { out.append(.code(c.joined(separator: "\n"), lang: lang)); code = nil }
                else { c.append(line); code = c }
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { flushAll(); code = []; lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces); continue }
            if t.isEmpty { flushAll(); continue }
            // Pipe table: the first `| … |` line is the header; a following `|---|` line is swallowed; more `|` lines are rows.
            // A header alone (no rule yet, while streaming) still renders as a table so the layout does not flip later.
            if let cells = Self.tableCells(t) {
                flushPara(); flushLists(); flushQuote()
                if var tb = table {
                    if !(tb.rows.isEmpty && Self.isTableRule(cells)) { tb.rows.append(cells) }
                    table = tb
                } else {
                    table = (header: cells, rows: [])
                }
                continue
            }
            flushTable()
            if t.hasPrefix(">") { flushPara(); flushLists(); quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)); continue }
            flushQuote()
            if Self.isHorizontalRule(t) { flushPara(); flushLists(); out.append(.rule); continue }
            if let m = t.firstMatch(of: /^(#{1,4})\s+(.*)$/) { flushPara(); flushLists(); out.append(.heading(m.1.count, String(m.2))); continue }
            // A marker may arrive before its first word while streaming ("- ", "1. "): it is already a list item,
            // not a one-character paragraph — otherwise the block re-flows (and the document moves) a token later.
            if let m = t.firstMatch(of: /^[-*•](?:\s+(.*))?$/) { flushPara(); if !numbers.isEmpty { flushLists() }; bullets.append(String(m.1 ?? "")); continue }
            // "1. " (marker + space, content still to come) is a list item; a bare "42." or "1081." — a whole answer that is a
            // number — is prose. The trimmed `t` cannot tell them apart, so the raw line's trailing whitespace decides.
            if let m = t.firstMatch(of: /^\d+[.)](?:\s+(.*))?$/), m.1 != nil || line.last?.isWhitespace == true {
                flushPara(); if !bullets.isEmpty { flushLists() }; numbers.append(String(m.1 ?? "")); continue
            }
            flushLists(); para.append(t)
        }
        flushAll()
        if var c = code {   // unterminated fence while streaming
            // The newline that will precede the closing ``` is not a code line yet: drop it so the card does not
            // grow a blank line and shrink again when the fence closes.
            if c.last == "" { c.removeLast() }
            out.append(.code(c.joined(separator: "\n"), lang: lang))
        }
        return out
    }

    /// "1", "12", "3." or one/two backticks: the start of a numbered item or a fence, not yet a block.
    nonisolated static func isMarkerPrefix(_ t: String) -> Bool {
        if t.isEmpty || t.count > 4 { return false }
        if t == "|" || t == ">" || t == "-" || t == "--" { return true }   // a table row, a quote or a rule about to start
        if t.allSatisfy({ $0 == "`" }) { return t.count <= 2 }
        let digits = t.hasSuffix(".") ? t.dropLast() : Substring(t)
        return !digits.isEmpty && digits.count <= 3 && digits.allSatisfy(\.isNumber)
    }

    nonisolated static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    public var body: some View {
        let blocks = Self.blocks(text, streaming: streaming)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                let last = i == blocks.count - 1
                switch b {
                case .paragraph(let s):
                    if last, streaming {
                        ChunkFadeText(s).font(.body).lineSpacing(5)
                    } else {
                        Text(Self.inline(s)).font(.body).lineSpacing(5)
                    }
                case .heading(let level, let s):
                    Text(Self.inline(s)).font(level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline).padding(.top, 4)
                case .bullet(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { j, it in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("•").foregroundStyle(.secondary)
                                (Text(Self.inline(it)) + caret(last && j == items.count - 1)).lineSpacing(4)
                            }
                        }
                    }.font(.body)
                case .numbered(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { j, it in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(j + 1).").foregroundStyle(.secondary).monospacedDigit()
                                (Text(Self.inline(it)) + caret(last && j == items.count - 1)).lineSpacing(4)
                            }
                        }
                    }.font(.body)
                case .code(let s, let lang):
                    CodeCard(code: s, language: lang)
                case .table(let header, let rows):
                    MarkdownTable(header: header, rows: rows)
                case .quote(let s):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5).fill(LooplDesign.accent.opacity(0.6)).frame(width: 3)
                        Text(Self.inline(s)).font(.body).foregroundStyle(.secondary).lineSpacing(4)
                    }
                    .padding(.vertical, 2)
                case .rule:
                    Rectangle().fill(LooplDesign.tertiaryFill).frame(height: 1).padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
            }
            if blocks.isEmpty, streaming { StreamingCaret() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func caret(_ show: Bool) -> Text {
        show && streaming ? Text(" ▍").foregroundStyle(LooplDesign.accent) : Text("")
    }
}

/// A pipe table on the same quiet card as code: header row in semibold, hairlines between rows, horizontally
/// scrollable when the columns need more than the column width (edge fade as a cue). Cells take inline Markdown.
public struct MarkdownTable: View {
    public var header: [String]
    public var rows: [[String]]
    @State private var overflows = false
    @Environment(\.looplStaticRender) private var staticRender
    public init(header: [String], rows: [[String]]) { self.header = header; self.rows = rows }
    public var body: some View {
        LooplHScroll(enabled: !staticRender) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                        Text(MarkdownBody.inline(h)).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.vertical, 8).gridColumnAlignment(.leading)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    GridRow {
                        ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                            Text(MarkdownBody.inline(c)).font(.callout).padding(.vertical, 8).textSelection(.enabled)
                        }
                    }
                    if i < rows.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 12)
        }
        .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.x + g.containerSize.width < g.contentSize.width - 2 } action: { _, o in overflows = o }
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [LooplDesign.secondaryBackground.opacity(0), LooplDesign.secondaryBackground], startPoint: .leading, endPoint: .trailing)
                .frame(width: 28).allowsHitTesting(false).opacity(overflows ? 1 : 0)
        }
        .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("table, \(header.count) columns, \(rows.count) rows")
    }
}

/// Monospaced code on a quiet card, horizontally scrollable, with a visible Copy action and an edge fade
/// where a line runs past the card (scroll indicators are hidden, so the fade is the only cue).
public struct CodeCard: View {
    public var code: String
    public var language: String
    @State private var copied = false
    @State private var overflowsRight = false
    @State private var overflowsLeft = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.looplStaticRender) private var staticRender
    public init(code: String, language: String = "") { self.code = code; self.language = language }

    /// Lines of code — the header shows the count when there is no language to name.
    private var lineCount: Int { code.split(separator: "\n", omittingEmptySubsequences: false).count }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(language.isEmpty ? "\(lineCount) line\(lineCount == 1 ? "" : "s")" : language)
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    copy(code)
                    withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion)) { copied = true }
                    Task { try? await Task.sleep(for: .seconds(1.4)); withAnimation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion)) { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium)).labelStyle(.titleAndIcon)
                        .foregroundStyle(copied ? LooplDesign.accent : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(LooplDesign.tertiaryFill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 12).padding(.top, 8)
            LooplHScroll(enabled: !staticRender) {
                Text(code).font(.callout.monospaced()).textSelection(.enabled).padding(12)
            }
            .onScrollGeometryChange(for: Edges.self) { g in
                Edges(left: g.contentOffset.x > 2, right: g.contentOffset.x + g.containerSize.width < g.contentSize.width - 2)
            } action: { _, e in overflowsLeft = e.left; overflowsRight = e.right }
            .overlay(alignment: .trailing) { fade(.trailing).opacity(overflowsRight ? 1 : 0) }
            .overlay(alignment: .leading) { fade(.leading).opacity(overflowsLeft ? 1 : 0) }
            .animation(LooplDesign.Motion.crossfade, value: overflowsRight || overflowsLeft)
        }
        .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu { Button("Copy code", systemImage: "doc.on.doc") { copy(code) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("code block\(language.isEmpty ? "" : ", \(language)")")
    }

    private struct Edges: Equatable { var left: Bool; var right: Bool }

    /// A 28 pt strip of the card's own colour fading to clear — the line continues under it.
    private func fade(_ edge: HorizontalEdge) -> some View {
        LinearGradient(colors: [LooplDesign.secondaryBackground.opacity(0), LooplDesign.secondaryBackground],
                       startPoint: edge == .trailing ? .leading : .trailing, endPoint: edge == .trailing ? .trailing : .leading)
            .frame(width: 28)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// `ImageRenderer` draws a ScrollView as nothing, so a picture of the transcript (Share as image) sets
/// `.looplStaticRender(true)` and tables / code cards lay out in place (wrapping) instead of scrolling.
public extension EnvironmentValues { @Entry var looplStaticRender: Bool = false }

/// A horizontal ScrollView — or, when `enabled` is false, the content laid out in place.
struct LooplHScroll<Content: View>: View {
    var enabled: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if enabled { ScrollView(.horizontal, showsIndicators: false) { content } } else { content.frame(maxWidth: .infinity, alignment: .leading) }
    }
}

@MainActor func copy(_ s: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = s
    #endif
    LooplDesign.haptic()
}

/// A pulsing bar shown where the next token will land.
public struct StreamingCaret: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public var body: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(LooplDesign.accent).frame(width: 3, height: 18)
            .opacity(on && !reduceMotion ? 0.25 : 1)
            // Scoped to `on`: a `withAnimation(.repeatForever)` in onAppear leaks into enclosing transactions.
            .animation(reduceMotion ? nil : LooplDesign.Motion.pulse, value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// Streaming text that fades each new chunk in instead of popping it: the text already on
/// screen is the stable base; the newest delta is drawn on top in a layer that starts at
/// opacity 0 and springs to 1 (`Motion.chunk`). Both layers lay out the SAME string (the
/// hidden part is painted clear), so glyphs never shift when the layer swaps. The caret is
/// the last glyph of the base and pulses only while streaming. Under Reduce Motion the
/// chunk appears instantly (no fade, no caret pulse).
public struct ChunkFadeText: View {
    public var text: String
    @State private var committed = ""
    @State private var tail = ""
    @State private var generation = 0
    @State private var caretOn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(_ text: String) { self.text = text }

    private enum Layer { case base, tail, caret }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Text(layer(.base))
            if !reduceMotion, !tail.isEmpty {
                Text(layer(.tail))
                    .id(generation)
                    .transition(.asymmetric(insertion: .opacity.animation(LooplDesign.Motion.chunk), removal: .identity))
            }
            // The caret is its own layer so its opacity can breathe as a view (text attributes do not animate).
            Text(layer(.caret))
                .opacity(caretOn && !reduceMotion ? 0.3 : 1)
                .animation(reduceMotion ? nil : LooplDesign.Motion.pulse, value: caretOn)
        }
        // Content changes must never cross-fade: a repeat-forever pulse in the same transaction would
        // otherwise keep the previous string ghosting at the top-left forever.
        .contentTransition(.identity)
        .onAppear { committed = text; tail = "" }
        .task { caretOn = true }   // a later transaction than the text, so the pulse animates only the opacity
        .onChange(of: text) { old, new in
            if new.hasPrefix(old), new.count > old.count {
                // Grew: what was on screen is now committed, the delta is the new tail.
                committed = old; tail = String(new.dropFirst(old.count))
            } else {
                committed = new; tail = ""
            }
            generation &+= 1
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// All three layers lay out the identical string; each paints only its own part.
    private func layer(_ l: Layer) -> AttributedString {
        var a = MarkdownBody.inline(committed)
        if l != .base { a.foregroundColor = .clear }
        var t = AttributedString(tail)
        if l != .tail { t.foregroundColor = .clear }
        a.append(t)
        var c = AttributedString(" ▍")
        c.foregroundColor = l == .caret ? LooplDesign.accent : .clear
        a.append(c)
        return a
    }
}

// MARK: - Turns

/// The user's turn: a small secondary "You" label and the text, left-aligned.
public struct UserTurn: View {
    public var text: String
    /// Pictures the user attached — rendered as tiles above the text (tap to zoom).
    public var images: [ImageBlock]
    /// Clips the user attached (Phase 8): a chip each, plus the transcript row when the clip had speech.
    public var videos: [VideoBlock]
    /// The built-in Copy menu. `EditableUserTurn` passes false and supplies the richer hold menu itself.
    public var menu: Bool
    public init(_ text: String, images: [ImageBlock] = [], videos: [VideoBlock] = [], menu: Bool = true) { self.text = text; self.images = images; self.videos = videos; self.menu = menu }
    public var body: some View {
        // An EMPTY `.contextMenu {}` still installs the interaction and eats the long-press, so the Copy menu is
        // attached only when asked for; with menu == false (EditableUserTurn) the outer hold menu owns the gesture.
        if menu { turn.contextMenu { Button("Copy", systemImage: "doc.on.doc") { copy(text) } } } else { turn }
    }
    private var turn: some View {
        // A recording travels as a marker line in the text (`AudioAttachmentMarker`); it is shown as a chip, not as the line.
        let parts = AudioAttachmentMarker.split(text)
        return VStack(alignment: .leading, spacing: 6) {
            Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).kerning(0.6)
            if !images.isEmpty { ImageStrip(images).padding(.bottom, 2) }
            ForEach(Array(videos.enumerated()), id: \.offset) { _, v in
                VStack(alignment: .leading, spacing: 4) {
                    VideoClipChip(video: v)
                    if let t = v.transcript, !t.isEmpty { VideoTranscriptRow(t).padding(.leading, 4) }
                }
                .padding(.bottom, 2)
            }
            if !parts.clips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(parts.clips, id: \.self) { AudioClipChip(url: $0.url, duration: $0.duration) }
                }
                .padding(.bottom, 2)
            }
            if !parts.text.isEmpty {
                // With the hold menu the text is NOT selectable: a long-press on selectable text opens the selection UI
                // and swallows the context menu. Copy is in the menu; Edit gives a real text field to select in.
                let body = Text(parts.text).font(.body).lineSpacing(4).foregroundStyle(.primary.opacity(0.85))
                if menu { body.textSelection(.enabled) } else { body }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText(parts))
    }

    private func accessibilityText(_ parts: (text: String, clips: [AudioAttachmentMarker])) -> String {
        var sent: [String] = []
        if !images.isEmpty { sent.append("\(images.count) image\(images.count == 1 ? "" : "s")") }
        if !videos.isEmpty { sent.append("\(videos.count) video\(videos.count == 1 ? "" : "s")") }
        if !parts.clips.isEmpty { sent.append("\(parts.clips.count) recording\(parts.clips.count == 1 ? "" : "s")") }
        return sent.isEmpty ? "You said: \(parts.text)" : "You sent \(sent.joined(separator: " and ")): \(parts.text)"
    }
}

/// Assistant text while it streams (kept for API compatibility — a `MarkdownBody`).
public struct StreamingTextView: View {
    public var text: String
    public var streaming: Bool
    public init(_ text: String, streaming: Bool) { self.text = text; self.streaming = streaming }
    public var body: some View {
        MarkdownBody(text, streaming: streaming)
            .contextMenu { Button("Copy", systemImage: "doc.on.doc") { copy(text) } }
            .accessibilityLabel(streaming ? "loopl is writing: \(text)" : "loopl: \(text)")
    }
}

/// Legacy bubble kept so older call sites compile; the app uses `UserTurn`.
public struct UserBubble: View {
    public var text: String
    public init(_ text: String) { self.text = text }
    public var body: some View { UserTurn(text) }
}

// MARK: - Disclosure chevron

/// The one disclosure glyph for every expandable row (tool row, thinking row, approval body, model rows).
/// `chevron.forward` mirrors in right-to-left layouts (`chevron.right` kept pointing away from the content), and the
/// open state rotates TOWARDS the content on either side — +90° in LTR, −90° in RTL — so it always ends pointing down.
public struct DisclosureChevron: View {
    public var expanded: Bool
    public var font: Font
    @Environment(\.layoutDirection) private var layoutDirection
    public init(expanded: Bool = false, font: Font = .caption2.weight(.semibold)) { self.expanded = expanded; self.font = font }
    public var body: some View {
        Image(systemName: "chevron.forward").font(font).foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? (layoutDirection == .rightToLeft ? -90 : 90) : 0))
            .accessibilityHidden(true)
    }
}

// MARK: - Tool rows

/// A quiet inline row — mark · tool name · (sweep) → ✓/✗ · duration — that expands on tap
/// to a monospaced card with the arguments and the result.
public struct ToolRow: View {
    public var call: ToolUse
    public var result: ToolResult?
    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The ✓/✗ glyph is `.footnote`, so its box scales with it: fixed at 16 pt it overflowed into the tool name at
    /// AX-XL (the glyph is ~26 pt there) and the two touched (UX audit).
    @ScaledMetric(relativeTo: .footnote) private var badge: CGFloat = 16
    public init(call: ToolUse, result: ToolResult?, expanded: Bool = false) { self.call = call; self.result = result; _expanded = State(initialValue: expanded) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : LooplDesign.spring) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    status.frame(width: badge, height: badge)
                    // A tool name is an identifier: it never hyphenates ("calcula-tor"). At accessibility sizes the
                    // duration moves under the name instead of fighting it for the line.
                    let nameLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                    nameLayout {
                        // Plain words for the row ("Time", "Copy to clipboard"); the id the model called stays in
                        // the expanded card and in History (IMPROVE-3 audit: `current_time` read as developer voice).
                        Text(ToolLabel.display(call.name)).font(.callout.weight(.medium)).foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                        if let r = result, r.durationMs > 0 {
                            Text(duration(r.durationMs)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                .contentTransition(.numericText())
                                .transition(.opacity)
                        }
                    }
                    Spacer(minLength: 8)
                    DisclosureChevron(expanded: expanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(a11y)
            .accessibilityHint(expanded ? "collapses the details" : "shows arguments and result")

            if result == nil, !expanded {
                // Running: a thin sweep under the row, never a spinner. It leaves the instant the result lands —
                // a fade-out here used to overlap the ✓ for a frame or two (a "done" row with a sweep under it).
                IndeterminateBar().padding(.leading, badge + 8).padding(.trailing, 20)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
            if expanded { ToolCallCard(call: call, result: result).transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))) }
            // A picture the tool made is the result — shown folded or not.
            if let r = result, !r.images.isEmpty { ToolImagesView(r.images) }
        }
        .padding(.vertical, 2)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: result == nil)
    }

    @ViewBuilder private var status: some View {
        if let r = result {
            Image(systemName: r.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(r.isError ? Color.red : LooplDesign.accent)
                .transition(.scale.combined(with: .opacity))
        } else {
            // Running: the mark breathing (no rotating glyph, no spinner).
            PulsingMark().frame(width: badge - 2, height: badge - 2).transition(.opacity)
        }
    }
    private var a11y: String {
        if let r = result { return "tool \(call.name) \(r.isError ? "failed" : "finished")" }
        return "tool \(call.name) running"
    }
    private func duration(_ ms: Double) -> String { ms < 1 ? "<1 ms" : ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.1f s", ms / 1000) }
}

/// The model's thinking, folded to one quiet line; tap to read it.
public struct ReasoningRow: View {
    public var text: String
    public var streaming: Bool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(text: String, streaming: Bool) { self.text = text; self.streaming = streaming }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(reduceMotion ? nil : LooplDesign.spring) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain").font(.caption2).foregroundStyle(.secondary)
                    Text(streaming ? "Thinking…" : "Thought for a moment").font(.callout).foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                    Spacer(minLength: 0)
                    DisclosureChevron(expanded: expanded)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(streaming ? "model is thinking" : "model reasoning")
            .accessibilityHint(expanded ? "collapses the reasoning" : "shows the reasoning")
            if expanded {
                Text(text).font(.footnote).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// The expanded details of a tool call: arguments in, result out, monospaced.
public struct ToolCallCard: View {
    public var call: ToolUse
    public var result: ToolResult?
    public init(call: ToolUse, result: ToolResult?) { self.call = call; self.result = result }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(call.name).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                .accessibilityLabel("tool id \(call.name)")
            labelled("arguments", argsText)
            if let r = result {
                labelled(r.isError ? "error" : "result", r.content)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("running…").font(.caption).foregroundStyle(.secondary)
                    IndeterminateBar()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            Button("Copy arguments", systemImage: "doc.on.doc") { copy(argsText) }
            if let r = result { Button("Copy result", systemImage: "doc.on.doc.fill") { copy(r.content) } }
        }
    }

    private var argsText: String {
        let pairs = call.input.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.compactDescription)" }
        return pairs.isEmpty ? "{}" : pairs.joined(separator: "\n")
    }
    private func labelled(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).kerning(0.5)
            Text(v).font(.footnote.monospaced()).textSelection(.enabled).lineLimit(12)
        }
    }
}

extension JSONValue {
    var compactDescription: String {
        switch self {
        case .string(let s): return s
        default: return (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "\(self)"
        }
    }
}

// MARK: - Performance footer

/// One quiet line of measured numbers; the app shows it only when
/// Settings › Show performance details is on.
public struct TokenMeter: View {
    public var metrics: Metrics
    public init(_ metrics: Metrics) { self.metrics = metrics }
    public var body: some View {
        if metrics.generatedTokens > 0 || metrics.ttftMs > 0 {
            Text(line).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("performance: \(line)")
        }
    }
    private var line: String {
        var parts: [String] = []
        if metrics.tokensPerSecond > 0 { parts.append(String(format: "%.1f tok/s", metrics.tokensPerSecond)) }
        if metrics.ttftMs > 0 { parts.append(metrics.ttftMs < 1000 ? "\(Int(metrics.ttftMs)) ms to first token" : String(format: "%.1f s to first token", metrics.ttftMs / 1000)) }
        if metrics.generatedTokens > 0 { parts.append("\(metrics.generatedTokens) generated") }
        if metrics.contextMax > 0 { parts.append("ctx \(metrics.contextUsed)/\(metrics.contextMax)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Transcript document

/// The conversation as a vertical document: left-aligned turns with a 20 pt
/// gutter, tool calls as inline rows, a streaming caret, and a scroll that
/// follows generation until the reader scrolls up (then a ↓ chip appears).
public struct AgentTranscriptView<Empty: View, Banner: View>: View {
    public var transcript: Transcript
    public var showPerformance: Bool
    /// Open every tool row by default (fixtures / screenshots); rows still toggle.
    public var expandTools = false
    private let empty: () -> Empty
    private let banner: () -> Banner
    /// Human-in-the-loop: called when an `ApprovalCard` is answered (see `onApproval(_:)`).
    public var onApproval: ((ApprovalRequest, ApprovalDecision) -> Void)? = nil
    /// Phase 7: called when an `AskUserCard` is answered (toolUseId, answer) — see `onAsk(_:)`.
    public var onAsk: ((String, AskUserAnswer) -> Void)? = nil
    /// Hold-to-edit (see MessageEditing.swift): nil = rows keep their Copy-only menus.
    public var actions: TranscriptActions? = nil
    @State private var pinned = true
    @State private var lastCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ transcript: Transcript, showPerformance: Bool = false, expandTools: Bool = false,
                @ViewBuilder banner: @escaping () -> Banner = { EmptyView() },
                @ViewBuilder empty: @escaping () -> Empty) {
        self.transcript = transcript; self.showPerformance = showPerformance; self.expandTools = expandTools; self.banner = banner; self.empty = empty
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack, on purpose. As a LazyVStack this transcript span a layout loop (main thread 100 % in
                // LazySubviewPlacements ⇄ the bottom `defaultScrollAnchor`) whenever the container changed size while
                // content ≈ container — dismissing the keyboard with a five-line draft froze the app on a 16 Pro and an
                // SE (296 s, never recovered; a Pro Max, taller, did not). A thread is a few dozen rows of text: eager
                // layout is cheap, and the anchor-follow below needs real heights, not estimates.
                VStack(alignment: .leading, spacing: 18) {
                    banner()
                    if transcript.items.isEmpty {
                        // Centred in the free space (the banner, when there is one, sits above): the scroll view's
                        // own height is the measure, so the mark does not hang high with a blank lower half.
                        empty().frame(maxWidth: .infinity)
                            .containerRelativeFrame(.vertical, alignment: .center) { h, _ in max(0, h - 160) }
                            // Leaves quickly when the first turn arrives: the tall centred block fading on the spring
                            // ghosted under the new row for half a second.
                            .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    }
                    ForEach(transcript.items) { item in
                        row(item)
                            .id(item.id)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    if Self.showsPending(transcript) {
                        // Between the send and the first token (or tool) there was nothing on screen but the ■:
                        // the mark breathes where the answer will land, and leaves with the first delta.
                        PendingRow().id("loopl.pending")
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    if showPerformance, !transcript.items.isEmpty { TokenMeter(transcript.metrics).padding(.top, -6) }
                    // Children still running after their use_agent row returned, once the parent has settled: one chip line
                    // each under the answer, so "something is still working" is visible without scrolling back to the card.
                    if !transcript.isRunning, !Self.backgroundAgents(transcript).isEmpty {
                        BackgroundAgentsStrip(runs: Self.backgroundAgents(transcript)) { r in
                            if let row = transcript.items.first(where: { if case .agent(let x) = $0.kind { return x.info.id == r.info.id }; return false }) {
                                withAnimation(reduceMotion ? nil : LooplDesign.Motion.value) { proxy.scrollTo(row.id, anchor: .top) }
                            }
                        }
                        .padding(.top, 4)
                        .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("loopl.bottom")
                }
                .padding(.horizontal, LooplDesign.gutter)
                .padding(.top, 12).padding(.bottom, 16)
                // iPad / Mac: a reading measure, centred — not 100 characters a line across the whole detail column.
                .frame(maxWidth: LooplDesign.readingWidth + 2 * LooplDesign.gutter)
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : LooplDesign.spring, value: transcript.items.count)
                .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: Self.showsPending(transcript))
            }
            // Follow generation by ANCHORING, not by scrolling: while the reader is pinned the scroll view keeps
            // its bottom edge glued to the content as the content grows, in the same layout pass. The pre-fix
            // follow called `scrollTo` from `onChange(of: last item)` — before layout had the new height — so it
            // landed 16–47 pt short on every token and the text snapped under the fold a frame later: the jump.
            .defaultScrollAnchor(pinned ? .bottom : nil, for: .sizeChanges)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: JumpSample.self) { JumpSample($0) } action: { _, s in JumpLog.record(s) }
            // Only the READER can lift the pin: content growing past the fold is not "scrolling away" (that is
            // the bug the geometry-only test had — the follow un-pinned itself on the first overflowing token).
            .onScrollPhaseChange { _, phase, ctx in
                switch phase {
                case .interacting: if transcript.isRunning { pinned = false }   // finger down: stop following at once
                case .idle, .decelerating: if Self.isAtBottom(ctx.geometry) { pinned = true }
                default: break
                }
                JumpLog.note("phase=\(phase) pinned=\(pinned)")
            }
            .onScrollGeometryChange(for: Bool.self) { g in Self.isAtBottom(g) } action: { _, atBottom in
                JumpLog.note("atBottom=\(atBottom) running=\(transcript.isRunning) pinned=\(pinned)")
                if atBottom { pinned = true }   // re-pin when the reader scrolls back down (or the document fits)
            }
            .onChange(of: transcript.items.count) { _, n in
                if n < lastCount { pinned = true }
                lastCount = n
                // A new turn (the user's send, a tool row) scrolls into view with motion; growth of the
                // streaming row itself is handled by the anchor above and never scrolls explicitly.
                if pinned { scrollDown(proxy) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !pinned, transcript.isRunning {
                    Button { pinned = true; scrollDown(proxy) } label: {
                        Image(systemName: "arrow.down").font(.footnote.weight(.semibold)).padding(10)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain).padding(16)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Scroll to the latest")
                }
            }
            .animation(LooplDesign.Motion.faded(LooplDesign.Motion.snappy, reduceMotion), value: pinned)
        }
    }

    /// The agent is running and nothing of its answer has arrived yet: the last item is still the user's turn
    /// (or a resolved approval / a note — anything that is not the model speaking or a tool in flight).
    nonisolated public static func showsPending(_ t: Transcript) -> Bool {
        guard t.isRunning, let last = t.items.last else { return false }
        switch last.kind {
        case .user, .note: return true
        case .approval(_, let d): return d != nil
        case .ask(_, _, let a): return a != nil
        case .assistant, .toolUse, .reasoning, .agent: return false
        }
    }

    /// Children still working after the turn they were started in settled — the strip under the transcript.
    nonisolated public static func backgroundAgents(_ t: Transcript) -> [SubAgentRun] {
        t.agents.filter { !$0.status.isFinished && ($0.status == .background || $0.info.background) }
    }

    static func isAtBottom(_ g: ScrollGeometry) -> Bool {
        LooplDesign.isAtBottom(offset: g.contentOffset.y, content: g.contentSize.height, container: g.containerSize.height,
                               insetTop: g.contentInsets.top, insetBottom: g.contentInsets.bottom)
    }

    private func scrollDown(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated, !reduceMotion { withAnimation(LooplDesign.Motion.value) { proxy.scrollTo("loopl.bottom", anchor: .bottom) } }
        else { proxy.scrollTo("loopl.bottom", anchor: .bottom) }
    }

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        switch item.kind {
        case .user(let s):
            if let actions { EditableUserTurn(item: item, text: s, actions: actions).padding(.top, 8) }
            else { UserTurn(s, images: item.images, videos: item.videos).padding(.top, 8) }
        case .assistant(let s):
            let streaming = transcript.isRunning && item.id == transcript.items.last?.id
            if let actions { RetryableAssistantTurn(item: item, text: s, streaming: streaming, actions: actions) }
            else { StreamingTextView(s, streaming: streaming) }
        case .toolUse(let c, let r):
            // Phase 7: a `render_ui` call draws its typed spec as a native card under the row (RenderCard.swift).
            if c.name == RenderUITool.toolName, let spec = try? RenderSpec(args: c.input) {
                RenderCard(call: c, result: r, spec: spec, images: item.images)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ToolRow(call: c, result: r, expanded: expandTools)
                    if !item.images.isEmpty { ImageStrip(item.images, maxHeight: 260) }   // tool-produced pictures (generate_image…)
                }
            }
        case .approval(let req, let d): ApprovalCard(request: req, decision: d) { onApproval?(req, $0) }
        case .ask(let id, let req, let a): AskUserCard(toolUseId: id, request: req, answer: a) { onAsk?(id, $0) }   // Phase 7 ask_user
        case .reasoning(let r):
            // Folded to one quiet line ("Thinking…" while it streams, "Thought for a moment" after); tap to read.
            ReasoningRow(text: r, streaming: transcript.isRunning && item.id == transcript.items.last?.id)
        case .note(let s): Text(s).font(.caption).foregroundStyle(.tertiary).accessibilityIdentifier("transcript-note")
        case .agent(let run):
            // A sub-agent's card (Phase 6): its own rows, approvals answered through the same handler (the Engine bubbles them).
            AgentCard(run: run, expandTools: expandTools, onApproval: { req, d in onApproval?(req, d) }, onAsk: { id, a in onAsk?(id, a) })
        }
    }
}

/// Measurement hook (DEBUG, launch arg `--jump-log`): one stdout line per scroll-geometry change so a capture
/// can be scored for jitter — `JUMP t=<ms> off=<contentOffset.y> content=<contentSize.height> view=<containerSize.height>`.
struct JumpSample: Hashable {
    var offset: CGFloat, content: CGFloat, container: CGFloat, top: CGFloat, bottom: CGFloat
    init(_ g: ScrollGeometry) {
        offset = g.contentOffset.y; content = g.contentSize.height; container = g.containerSize.height
        top = g.contentInsets.top; bottom = g.contentInsets.bottom
    }
}
enum JumpLog {
    static let enabled: Bool = {
        #if DEBUG
        return CommandLine.arguments.contains("--jump-log")
        #else
        return false
        #endif
    }()
    private static let t0 = Date()
    static func note(_ m: String) { guard enabled else { return }; print(String(format: "JUMPNOTE t=%.0f ", Date().timeIntervalSince(t0) * 1000) + m) }
    static func record(_ s: JumpSample) {
        guard enabled else { return }
        print(String(format: "JUMP t=%.0f off=%.2f content=%.2f view=%.2f top=%.2f bottom=%.2f", Date().timeIntervalSince(t0) * 1000, s.offset, s.content, s.container, s.top, s.bottom))
    }
}

public extension AgentTranscriptView {
    /// Hold a message to Edit / Copy / Delete from here (user rows) or Copy / Retry (assistant rows).
    func transcriptActions(_ actions: TranscriptActions?) -> Self {
        var copy = self; copy.actions = actions; return copy
    }
    /// Route approval answers (`ApprovalCard`) to the agent — `agent.resolve(approval: req.id, decision)`.
    func onApproval(_ handler: @escaping (ApprovalRequest, ApprovalDecision) -> Void) -> Self {
        var copy = self; copy.onApproval = handler; return copy
    }
    /// Route `ask_user` answers (`AskUserCard`) to the agent — `agent.resolve(interrupt: AskUserTool.interruptId(toolUseId:), …)`.
    func onAsk(_ handler: @escaping (String, AskUserAnswer) -> Void) -> Self {
        var copy = self; copy.onAsk = handler; return copy
    }
}

public extension AgentTranscriptView where Empty == AnyView, Banner == EmptyView {
    /// Convenience: an empty state made of the mark and one line of Markdown.
    init(_ transcript: Transcript, emptyHint: String, showPerformance: Bool = false) {
        self.init(transcript, showPerformance: showPerformance, banner: { EmptyView() }) {
            AnyView(EmptyState(hint: emptyHint))
        }
    }
}

/// Where the answer will land, before its first token: the mark breathing and a quiet "…". Reduce Motion: static.
public struct PendingRow: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 10) {
            PulsingMark().frame(width: 16, height: 16)
            Text("…").font(.body).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("loopl is thinking")
    }
}

/// The mark and one line — the whole empty state. The mark draws itself the first time it is seen.
public struct EmptyState: View {
    public var hint: String
    public init(hint: String) { self.hint = hint }
    public var body: some View {
        VStack(spacing: 18) {
            LooplMarkIntro().frame(width: 72, height: 72).accessibilityHidden(true)
            Text(MarkdownBody.inline(hint)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ModelPickerRow / DownloadProgressRow

/// One model in the list: name, size, dialect, with a ✓ when it is on disk and
/// a bolt when it is the loaded one.
public struct ModelPickerRow: View {
    public var spec: ModelSpec
    public var loaded: Bool
    public var downloaded: Bool
    /// When given, the bolt + highlight share a geometry across rows: switching models slides
    /// the "loaded" state from the old row to the new one instead of blinking.
    public var loadedMark: Namespace.ID?
    /// 0…1 while the weights are arriving: the trailing glyph becomes a ring instead of the download arrow,
    /// so a row shows ONE state at a time (in use ⚡ · on this device ✓ · downloading ○ · tap to download ↓).
    public var downloading: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    public init(spec: ModelSpec, loaded: Bool = false, downloaded: Bool = false, loadedMark: Namespace.ID? = nil, downloading: Double? = nil) {
        self.spec = spec; self.loaded = loaded; self.downloaded = downloaded; self.loadedMark = loadedMark; self.downloading = downloading
    }
    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(spec.name).font(.body.weight(loaded ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                // ONE Text so the facts stay on one line: on an SE they shrink a little instead of wrapping "ctx / 12,288".
                // At accessibility sizes even 0.72× lost the tail ("1.75 GB · 2B · ctx 12,2…" on an SE at AX-XL) — there the
                // facts wrap as they need to; the accessibility label reads them in full either way.
                if typeSize.isAccessibilitySize {
                    metaRow.fixedSize(horizontal: false, vertical: true).accessibilityLabel(metaAccessibility)
                } else {
                    metaRow.lineLimit(1).minimumScaleFactor(0.72).accessibilityLabel(metaAccessibility)
                }
            }
            Spacer()
            glyph
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background {
            if loaded {
                let glow = RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LooplDesign.accent.opacity(0.08))
                if let loadedMark, !reduceMotion { glow.matchedGeometryEffect(id: "loaded.glow", in: loadedMark) } else { glow.transition(.opacity) }
            }
        }
        .padding(.horizontal, -8).padding(.vertical, -6)
        .contentShape(Rectangle())
    }
    private var metaRow: Text {
        var t = meta(spec.isDownloadable ? spec.sizeLabel : "built in")
        t = t + meta(" · \(spec.paramsB.formatted(.number.precision(.fractionLength(0...1))))B · ctx \(spec.ctxUsable8GB.formatted()) · \(spec.runtime.label)")
        if spec.supportsVision {
            t = t + meta(" · ") + (Text(Image(systemName: "eye")) + Text(" vision")).font(.caption2.weight(.semibold)).foregroundColor(LooplDesign.accent)
        }
        if spec.isThinking {
            t = t + meta(" · ") + (Text(Image(systemName: "brain")) + Text(" thinks")).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
        }
        if spec.toolsUnverified == true {
            t = t + meta(" · ") + Text("tools unverified").font(.caption2.weight(.semibold)).foregroundColor(LooplDesign.amber)
        }
        return t
    }
    private var metaAccessibility: String {
        var parts = [spec.isDownloadable ? spec.sizeLabel : "built in", "\(spec.paramsB.formatted(.number.precision(.fractionLength(0...1))))B", "context \(spec.ctxUsable8GB.formatted())", spec.runtime.label]
        if spec.supportsVision { parts.append("sees pictures") }
        if spec.isThinking { parts.append("thinks before answering") }
        if spec.toolsUnverified == true { parts.append("tool calls unverified for this model") }
        return parts.joined(separator: ", ")
    }
    /// The row's single state glyph: in use ⚡ · on this device ✓ · downloading ○ · tap to download ↓.
    @ViewBuilder private var glyph: some View {
        if loaded {
            let bolt = Image(systemName: LooplDesign.iconLoaded).foregroundStyle(LooplDesign.accent).accessibilityLabel("loaded")
            if let loadedMark, !reduceMotion { bolt.matchedGeometryEffect(id: "loaded.bolt", in: loadedMark) } else { bolt.transition(.opacity) }
        }
        else if downloaded || !spec.isDownloadable { Image(systemName: "checkmark").foregroundStyle(.secondary).font(.footnote.weight(.semibold)).accessibilityLabel("on this device").transition(.opacity) }
        else if let downloading {
            ProgressView(value: min(max(downloading, 0), 1)).progressViewStyle(.circular).controlSize(.small).tint(LooplDesign.accent)
                .frame(width: 18, height: 18).accessibilityLabel("downloading").transition(.opacity)
        }
        else { Image(systemName: LooplDesign.iconDownload).foregroundStyle(.tertiary).accessibilityLabel("not downloaded").transition(.opacity) }
    }
    private func meta(_ s: String) -> Text { Text(s).font(.caption).foregroundColor(.secondary) }
}

public struct DownloadProgressRow: View {
    public var done: Int64
    public var total: Int64
    public var fileIndex: Int
    public var fileCount: Int
    public var onPause: (() -> Void)?
    public init(done: Int64, total: Int64, fileIndex: Int, fileCount: Int, onPause: (() -> Void)? = nil) {
        self.done = done; self.total = total; self.fileIndex = fileIndex; self.fileCount = fileCount; self.onPause = onPause
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(done), total: Double(max(total, 1))).tint(LooplDesign.accent)
                .animation(LooplDesign.Motion.value, value: done)
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(LooplDesign.Motion.value, value: done)
                Spacer()
                if let onPause { Button("Pause", action: onPause).font(.caption) }
            }
        }
        .accessibilityLabel("downloading, \(Int(Double(done) / Double(max(total, 1)) * 100)) percent")
    }
}

// MARK: - Previews (fixture events, no model)

enum PreviewFixtures {
    static let call = ToolUse(toolUseId: "call_1", name: "calculator", input: ["expression": "23*47"])
    static let result = ToolResult(toolUseId: "call_1", name: "calculator", status: .success, content: "23*47 = 1081", durationMs: 1.2)
    static var transcript: Transcript {
        var t = Transcript()
        t.user("what time is it in Istanbul and what is 23*47?")
        t.apply(.startEventLoop(cycle: 1))
        t.apply(.text("Let me check both."))
        t.apply(.modelMessage(.assistant(text: "Let me check both.", toolUses: [call, ToolUse(toolUseId: "call_2", name: "current_time", input: ["timezone": "Europe/Istanbul"])])))
        t.apply(.toolStarted(call)); t.apply(.toolResult(result))
        t.apply(.toolStarted(ToolUse(toolUseId: "call_2", name: "current_time", input: ["timezone": "Europe/Istanbul"])))
        t.apply(.startEventLoop(cycle: 2))
        t.apply(.text("It is **05:41** in Istanbul and 23 × 47 = 1081.\n\n```swift\nlet agent = Agent(model: model)\n```"))
        var m = Metrics(); m.ttftMs = 412; m.tokensPerSecond = 38.4; m.promptTokens = 612; m.generatedTokens = 41; m.contextUsed = 653; m.contextMax = 8192
        t.apply(.metrics(m))
        return t
    }
}

#Preview("Transcript document") {
    AgentTranscriptView(PreviewFixtures.transcript, emptyHint: "Ask anything.", showPerformance: true)
}

#Preview("Empty") {
    AgentTranscriptView(Transcript(), emptyHint: "Runs on this iPhone. Nothing leaves it.")
}

#Preview("ToolRow") {
    VStack(alignment: .leading, spacing: 12) {
        ToolRow(call: PreviewFixtures.call, result: nil)
        ToolRow(call: PreviewFixtures.call, result: PreviewFixtures.result)
        ToolRow(call: PreviewFixtures.call, result: ToolResult(toolUseId: "call_1", name: "calculator", status: .error, content: "error: division by zero", durationMs: 0.4))
    }.padding()
}
