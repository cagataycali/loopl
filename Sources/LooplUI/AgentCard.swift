import SwiftUI
import Loopl

// MARK: - Sub-agent cards (use_agent)
//
// A `use_agent` call is a tool row like any other — mark · `use_agent` · ✓ — but what it does is run ANOTHER agent,
// and that agent streams: text, its own tool calls, approvals it needs from the human. Hiding all of that behind
// "running…" would be the TUI's old dark batch (spawn-strip.tsx): a chip, then nothing, for minutes. So the row
// carries the child's picture-in-picture: one `ChildCard` per child, stacked, each with the child's name, one line
// of its system prompt, a status chip (running · waiting for you · background · done · failed), elapsed, and the
// child's transcript rendered with the SAME components the parent uses (`StreamingTextView`, `ToolRow`,
// `ApprovalCard`, `ReasoningRow`) — a reader learns one vocabulary.
//
// Background children (wait:false, or a child that outlived its row) fold to the chip line: tap to open. Inline
// children are open while they run and fold to their summary when done, so a finished card reads as one line and
// the answer that follows it stays the loudest thing on screen.
//
// Data: lane C's `TranscriptItem.Kind.agent(SubAgentRun)` — the SDK inserts one row per child right after its
// `use_agent` tool row (`AgentEvent.childStarted / child / childStatus`), so stacking is the transcript's order.

/// What the chip says — `SubAgentStatus` plus one derived state: a child whose transcript holds an unanswered approval
/// is *waiting for you*, whatever the hub calls it (running or background). Pure, so it is unit-tested.
public enum AgentCardState: String, Sendable, Hashable {
    case queued, running, waiting, background, done, failed, stopped

    public init(_ run: SubAgentRun) {
        if !run.status.isFinished, !run.transcript.pendingApprovals.isEmpty || !run.transcript.pendingAsks.isEmpty { self = .waiting; return }
        switch run.status {
        case .queued: self = .queued
        case .running: self = .running
        case .background: self = .background
        case .done: self = .done
        case .failed: self = .failed
        case .stopped: self = .stopped
        }
    }
    public var isFinished: Bool { self == .done || self == .failed || self == .stopped }
    /// The chip text.
    public var label: String {
        switch self {
        case .queued: "queued"
        case .running: "running"
        case .waiting: "waiting for you"
        case .background: "background"
        case .done: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }
    /// Open by default while the child runs inline or needs the human; folded when queued, in the background or over.
    public var defaultExpanded: Bool { self == .running || self == .waiting }
}

/// The card of one sub-agent (`TranscriptItem.Kind.agent`) — drawn right under the `use_agent` tool row it belongs to;
/// several children of one turn stack. Header = status glyph · name · chip · elapsed · chevron, one line of the system
/// prompt, the tools; body = the child's transcript with the parent's own row views.
public struct AgentCard: View {
    public var run: SubAgentRun
    public var expandTools: Bool
    public var onApproval: ((ApprovalRequest, ApprovalDecision) -> Void)?
    /// Phase 7: an `ask_user` card inside the child's transcript, answered on the child (toolUseId, answer).
    public var onAsk: ((String, AskUserAnswer) -> Void)?
    /// `nil` = follow the default for the state; set by a tap, reset when the state changes.
    @State private var userExpanded: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var badge: CGFloat = 16

    public init(run: SubAgentRun, expandTools: Bool = false, onApproval: ((ApprovalRequest, ApprovalDecision) -> Void)? = nil,
                onAsk: ((String, AskUserAnswer) -> Void)? = nil) {
        self.run = run; self.expandTools = expandTools; self.onApproval = onApproval; self.onAsk = onAsk
    }

    private var state: AgentCardState { AgentCardState(run) }
    private var expanded: Bool { userExpanded ?? state.defaultExpanded }
    private var info: SubAgentInfo { run.info }
    private var isRunning: Bool { !run.status.isFinished }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : LooplDesign.spring) { userExpanded = !expanded }
            } label: { header.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel("agent \(info.name)")
            .accessibilityValue(state == .waiting ? "needs your answer" : state.label)
            .accessibilityHint(expanded ? "collapses the agent" : "shows what the agent is doing")
            .accessibilityIdentifier("agent-card-\(info.id)")

            if expanded {
                AgentTranscriptRows(run: run, expandTools: expandTools, onApproval: onApproval, onAsk: onAsk)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            } else if state.isFinished, let text = run.resultText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                // Folded + over (done or failed): the first line of what came of it, so the card still tells the story.
                Text(MarkdownBody.inline(text)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.leading, badge + 8)
                    .accessibilityLabel("result: \(text)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LooplDesign.secondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            // A 2 pt rail on the leading edge: "this is inside the agent" at a glance, also in monochrome.
            RoundedRectangle(cornerRadius: 1).fill(railTint).frame(width: 2).padding(.vertical, 10)
        }
        .padding(.leading, 4)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: state)
        .onChange(of: state) { _, _ in userExpanded = nil }   // a state change re-applies the default fold
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        // AX sizes: the chip and elapsed drop under the name instead of squeezing it to a hyphen.
        let stacked = typeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusGlyph.frame(width: badge, height: badge)
                Text(info.name).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                if !stacked {
                    StatusChip(state: state)
                    Spacer(minLength: 8)
                    Elapsed(run: run)
                }
                if stacked { Spacer(minLength: 8) }
                DisclosureChevron(expanded: expanded)
            }
            if stacked {
                HStack(spacing: 8) { StatusChip(state: state); Elapsed(run: run) }.padding(.leading, badge + 8)
            }
            if !info.systemPrompt.isEmpty {
                Text(info.systemPrompt.replacingOccurrences(of: "\n", with: " "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, badge + 8)
                    .accessibilityLabel("instructions: \(info.systemPrompt)")
            }
            if !info.tools.isEmpty {
                Text(info.tools.joined(separator: " · ")).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.leading, badge + 8)
                    .accessibilityLabel("tools: \(info.tools.joined(separator: ", "))")
            }
        }
    }

    @ViewBuilder private var statusGlyph: some View {
        switch state {
        case .running, .waiting: PulsingMark().frame(width: badge - 2, height: badge - 2).transition(.opacity)
        case .queued: Image(systemName: "circle.dotted").font(.footnote).foregroundStyle(.tertiary).transition(.opacity)
        case .background: Image(systemName: "moon.fill").font(.footnote).foregroundStyle(.secondary).transition(.opacity)
        case .done: Image(systemName: "checkmark.circle.fill").font(.footnote).foregroundStyle(LooplDesign.accent).transition(.scale.combined(with: .opacity))
        case .failed: Image(systemName: "xmark.circle.fill").font(.footnote).foregroundStyle(Color.red).transition(.scale.combined(with: .opacity))
        case .stopped: Image(systemName: "stop.circle.fill").font(.footnote).foregroundStyle(.secondary).transition(.scale.combined(with: .opacity))
        }
    }
    private var railTint: Color {
        switch state {
        case .waiting: LooplDesign.amber
        case .failed: .red
        case .queued, .background, .stopped: Color.secondary.opacity(0.5)
        case .done: LooplDesign.accent.opacity(0.5)
        case .running: LooplDesign.accent
        }
    }
}

/// `running` · `waiting for you` · `background` · `done` · `failed` … — a small capsule, tinted by state.
public struct StatusChip: View {
    public var state: AgentCardState
    @Environment(\.colorScheme) private var scheme
    public init(state: AgentCardState) { self.state = state }
    public var body: some View {
        Text(state.label)
            .font(.caption2.weight(.medium)).foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(bg, in: Capsule())
            .contentTransition(.interpolate)
            .accessibilityHidden(true)   // the card's accessibilityValue carries it
    }
    private var fg: Color {
        switch state {
        case .waiting: scheme == .dark ? LooplDesign.amber : Color(red: 0.48, green: 0.29, blue: 0)   // amber on dark, brown on light — both ≥ 4.5:1
        case .failed: .red
        case .running: LooplDesign.accent
        case .queued, .background, .done, .stopped: .secondary
        }
    }
    private var bg: Color {
        switch state {
        case .waiting: LooplDesign.amber.opacity(scheme == .dark ? 0.18 : 0.28)
        case .failed: Color.red.opacity(0.12)
        case .running: LooplDesign.accent.opacity(0.14)
        case .queued, .background, .done, .stopped: LooplDesign.tertiaryFill
        }
    }
}

/// `12 s` growing once a second while the child runs; frozen at its span once it ended. The clock only ticks while
/// running — a finished card is static, and under Reduce Motion a one-second text update is not motion.
struct Elapsed: View {
    var run: SubAgentRun
    var body: some View {
        if run.status.isFinished || run.endedAt != nil {
            label(run.elapsed)
        } else {
            TimelineView(.periodic(from: run.info.startedAt, by: 1)) { ctx in label(max(0, ctx.date.timeIntervalSince(run.info.startedAt))) }
        }
    }
    private func label(_ s: TimeInterval) -> some View {
        Text(Self.format(s)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            .contentTransition(.numericText())
            .accessibilityLabel(Self.spoken(s))
    }
    static func format(_ s: TimeInterval) -> String {
        let n = Int(max(0, s).rounded(.down))
        if n < 60 { return "\(n) s" }
        if n < 3600 { return "\(n / 60) m \(String(format: "%02d", n % 60)) s" }
        return String(format: "%.1f h", s / 3600)
    }
    static func spoken(_ s: TimeInterval) -> String {
        let n = Int(max(0, s).rounded(.down))
        if n < 60 { return "\(n) seconds" }
        return "\(n / 60) minutes \(n % 60) seconds"
    }
}

/// The child's transcript, rendered row by row with the parent's components. The task is shown once, quietly, as the
/// first line — not a bubble: the human did not type it.
struct AgentTranscriptRows: View {
    var run: SubAgentRun
    var expandTools: Bool
    var onApproval: ((ApprovalRequest, ApprovalDecision) -> Void)?
    var onAsk: ((String, AskUserAnswer) -> Void)?
    @ScaledMetric(relativeTo: .footnote) private var indent: CGFloat = 24
    private var isRunning: Bool { !run.status.isFinished }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !run.info.input.isEmpty {
                Text(run.info.input).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    .accessibilityLabel("task: \(run.info.input)")
            }
            ForEach(run.transcript.items) { item in row(item) }
            if isRunning, Self.showsPending(run.transcript) { PendingRow() }
        }
        .padding(.leading, indent)
        .accessibilityElement(children: .contain)
    }

    /// The child is working and nothing of its answer is on screen yet.
    static func showsPending(_ t: Transcript) -> Bool {
        guard let last = t.items.last else { return true }
        switch last.kind {
        case .user, .note: return true
        case .approval(_, let d): return d != nil
        case .ask(_, _, let a): return a != nil
        case .assistant, .toolUse, .reasoning, .agent: return false
        }
    }

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        switch item.kind {
        case .user(let s):
            // A child never has a human typing at it: a user row is a relay line.
            Text(s).font(.caption).foregroundStyle(.tertiary)
        case .assistant(let s):
            StreamingTextView(s, streaming: isRunning && item.id == run.transcript.items.last?.id)
        case .toolUse(let c, let r):
            VStack(alignment: .leading, spacing: 8) {
                ToolRow(call: c, result: r, expanded: expandTools)
                if !item.images.isEmpty { ImageStrip(item.images, maxHeight: 200) }
            }
        case .approval(let req, let d):
            ApprovalCard(request: req, decision: d) { onApproval?(req, $0) }
        case .ask(let id, let req, let a):
            AskUserCard(toolUseId: id, request: req, answer: a) { onAsk?(id, $0) }   // Phase 7 ask_user, answered on the child
        case .reasoning(let r):
            ReasoningRow(text: r, streaming: isRunning && item.id == run.transcript.items.last?.id)
        case .note(let s):
            Text(s).font(.caption).foregroundStyle(.tertiary)
        case .agent:
            EmptyView()   // depth 1: a child never shows grandchildren
        }
    }
}

/// The chip line a background child keeps under a settled transcript — the whole conversation sees at the bottom that
/// something still runs: `🌙 weather · background · 42 s`. Tap opens the card it belongs to (the host scrolls to it).
public struct BackgroundAgentsStrip: View {
    public var runs: [SubAgentRun]
    public var onOpen: (SubAgentRun) -> Void
    public init(runs: [SubAgentRun], onOpen: @escaping (SubAgentRun) -> Void) { self.runs = runs; self.onOpen = onOpen }
    public var body: some View {
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(runs, id: \.info.id) { r in
                    Button { onOpen(r) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "moon.fill").font(.caption2).foregroundStyle(.secondary)
                            Text(r.info.name).font(.footnote.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                            StatusChip(state: AgentCardState(r))
                            Spacer(minLength: 8)
                            Elapsed(run: r)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(LooplDesign.secondaryBackground, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("agent \(r.info.name) running in the background")
                    .accessibilityHint("opens its card")
                    .accessibilityIdentifier("agent-strip-\(r.info.id)")
                }
            }
        }
    }
}
