import SwiftUI
import Loopl

// MARK: - ToolCallCard

/// Collapsed pill → expandable args + result, with status spinner / ✓ / ✗.
public struct ToolCallCard: View {
    public var call: ToolCall
    public var result: ToolResult?
    @State private var expanded = false

    public init(call: ToolCall, result: ToolResult?) { self.call = call; self.result = result }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    status
                    Text(call.name).font(.subheadline.weight(.semibold).monospaced()).lineLimit(1)
                    Spacer()
                    if let r = result { Text(String(format: "%.0f ms", r.durationMs)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("tool \(call.name), \(result == nil ? "running" : result!.isError ? "failed" : "done")")
            Text(JSONValue.object(call.arguments).compact).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(expanded ? nil : 1)
            if let r = result, expanded || r.content.count < 120 {
                Divider()
                Text(r.content).font(.caption.monospaced()).foregroundStyle(r.isError ? .red : .primary).lineLimit(expanded ? nil : 4).textSelection(.enabled)
            }
        }
        .looplCard()
    }

    @ViewBuilder private var status: some View {
        if let r = result {
            Image(systemName: r.isError ? "xmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(r.isError ? .red : LooplDesign.accent)
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

// MARK: - TokenMeter

/// TTFT · tok/s · prompt · gen · context used/max bar. Shows "≈" when a runtime can only estimate.
public struct TokenMeter: View {
    public var metrics: Metrics
    public init(_ metrics: Metrics) { self.metrics = metrics }
    public var body: some View {
        let max = Swift.max(1, metrics.contextMax)
        let frac = min(1, Double(metrics.contextUsed) / Double(max))
        HStack(spacing: 12) {
            stat("TTFT", metrics.ttftMs > 0 ? String(format: "%.0f ms", metrics.ttftMs) : "—")
            stat("tok/s", metrics.tokensPerSecond > 0 ? String(format: "%.1f", metrics.tokensPerSecond) : "—")
            stat("prompt", (metrics.estimated ? "≈" : "") + "\(metrics.promptTokens)")
            stat("gen", (metrics.estimated ? "≈" : "") + "\(metrics.generatedTokens)")
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Text("ctx \(metrics.contextUsed)/\(metrics.contextMax)").foregroundStyle(.secondary)
                Capsule().fill(LooplDesign.tertiaryFill).frame(width: 60, height: 6)
                    .overlay(alignment: .leading) { Capsule().fill(frac > 0.9 ? Color.red : LooplDesign.accent).frame(width: 60 * frac) }
            }
            .accessibilityLabel("context \(metrics.contextUsed) of \(metrics.contextMax) tokens")
        }
        .font(.caption2.monospacedDigit())
    }
    private func stat(_ k: String, _ v: String) -> some View {
        HStack(spacing: 3) { Text(k).foregroundStyle(.secondary); Text(v).fontWeight(.semibold) }
    }
}

// MARK: - StreamingTextView

/// Assistant bubble; shows a cursor while text is still arriving.
public struct StreamingTextView: View {
    public var text: String
    public var streaming: Bool
    public init(_ text: String, streaming: Bool = false) { self.text = text; self.streaming = streaming }
    public var body: some View {
        HStack {
            (Text(text.isEmpty ? "…" : text) + (streaming ? Text(" ▍").foregroundStyle(LooplDesign.accent) : Text("")))
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 18))
            Spacer(minLength: 48)
        }
    }
}

public struct UserBubble: View {
    public var text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        HStack { Spacer(minLength: 48)
            Text(text).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 9)
                .background(LooplDesign.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

// MARK: - AgentTranscriptView

/// Renders a `Transcript` (the fold of `AgentEvent`s): bubbles, tool cards, warnings, notes.
public struct AgentTranscriptView: View {
    public var transcript: Transcript
    public var emptyHint: String
    public init(_ transcript: Transcript, emptyHint: String = "Ask something.") { self.transcript = transcript; self.emptyHint = emptyHint }
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if transcript.items.isEmpty {
                        VStack(spacing: 10) {
                            Text("🔁").font(.system(size: 44))
                            Text(.init(emptyHint)).multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
                        }.frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 32)
                    }
                    ForEach(transcript.items) { item in
                        row(item).id(item.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: transcript.items.last?.kind) { _, _ in
                if let last = transcript.items.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        switch item.kind {
        case .user(let s): UserBubble(s).padding(.horizontal, 12)
        case .assistant(let s): StreamingTextView(s, streaming: transcript.isRunning && item.id == transcript.items.last?.id).padding(.horizontal, 12)
        case .toolCall(let c, let r): ToolCallCard(call: c, result: r).padding(.horizontal, 12)
        case .warning(let w): Label(w, systemImage: LooplDesign.iconWarning).font(.caption).foregroundStyle(.orange).padding(.horizontal, 24)
        case .note(let s): Text(s).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.horizontal, 24)
        }
    }
}

// MARK: - ModelPickerRow / DownloadProgressRow

public struct ModelPickerRow: View {
    public var spec: ModelSpec
    public var loaded: Bool
    public init(spec: ModelSpec, loaded: Bool = false) { self.spec = spec; self.loaded = loaded }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.name).font(.headline)
                Spacer()
                if loaded { Pill("loaded") }
                if spec.gated { Pill("gated", tint: .orange) }
                Pill(spec.runtime.label)
            }
            if !spec.repo.isEmpty { Text(spec.repo).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
            HStack(spacing: 10) {
                if spec.isDownloadable { meta(spec.sizeLabel) }
                meta("\(spec.paramsB.formatted(.number.precision(.fractionLength(0...1))))B")
                meta("ctx \(spec.ctxNominal.formatted()) · use \(spec.ctxUsable8GB.formatted())")
                meta(spec.family.rawValue)
            }
            if let n = spec.notes, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func meta(_ s: String) -> some View { Text(s).font(.caption2).foregroundStyle(.secondary) }
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
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · file \(min(fileIndex + 1, max(fileCount, 1)))/\(fileCount)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if let onPause { Button("Pause", action: onPause).font(.caption) }
            }
        }
        .accessibilityLabel("downloading, \(Int(Double(done) / Double(max(total, 1)) * 100)) percent")
    }
}

// MARK: - Previews (fixture events, no model)

enum PreviewFixtures {
    static let call = ToolCall(id: "call_1", name: "calculator", arguments: ["expression": "23*47"])
    static let result = ToolResult(callId: "call_1", name: "calculator", content: "23*47 = 1081", isError: false, durationMs: 1.2)
    static var transcript: Transcript {
        var t = Transcript()
        t.user("what time is it in Istanbul and what is 23*47?")
        t.apply(.iterationStarted(1))
        t.apply(.text("Let me check both."))
        t.apply(.assistantMessage(.assistant(text: "Let me check both.", toolCalls: [call, ToolCall(id: "call_2", name: "current_time", arguments: ["timezone": "Europe/Istanbul"])])))
        t.apply(.toolStarted(call)); t.apply(.toolFinished(result))
        t.apply(.toolStarted(ToolCall(id: "call_2", name: "current_time", arguments: ["timezone": "Europe/Istanbul"])))
        t.apply(.warning("tool 'calculator' called 3× in a row with identical arguments — the model may be stuck"))
        t.apply(.iterationStarted(2))
        t.apply(.text("It is 05:41 in Istanbul and 23 × 47 = 1081."))
        var m = Metrics(); m.ttftMs = 412; m.tokensPerSecond = 38.4; m.promptTokens = 612; m.generatedTokens = 41; m.contextUsed = 653; m.contextMax = 8192
        t.apply(.metrics(m))
        return t
    }
}

#Preview("ToolCallCard") {
    VStack(spacing: 12) {
        ToolCallCard(call: PreviewFixtures.call, result: nil)
        ToolCallCard(call: PreviewFixtures.call, result: PreviewFixtures.result)
        ToolCallCard(call: PreviewFixtures.call, result: ToolResult(callId: "call_1", name: "calculator", content: "error: division by zero", isError: true, durationMs: 0.4))
    }.padding()
}

#Preview("TokenMeter") {
    TokenMeter(PreviewFixtures.transcript.metrics).padding()
}

#Preview("AgentTranscriptView") {
    AgentTranscriptView(PreviewFixtures.transcript)
}

#Preview("ModelPickerRow + DownloadProgressRow") {
    List {
        ModelPickerRow(spec: Catalog.loadBundled().models.first ?? ModelSpec(id: "qwen3-1.7b-4bit", name: "Qwen3-1.7B (4-bit)", repo: "mlx-community/Qwen3-1.7B-4bit", runtime: .mlx, family: .hermes, paramsB: 1.7, sizeBytes: 968_080_210, ctxNominal: 40960, ctxUsable8GB: 8192, minRAMGB: 6, gated: false, notes: "Default pick."), loaded: true)
        DownloadProgressRow(done: 412_000_000, total: 968_080_210, fileIndex: 0, fileCount: 7) {}
    }
}
