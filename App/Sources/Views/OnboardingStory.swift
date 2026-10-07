import SwiftUI
import UIKit
import Loopl
import LooplUI

// The first-run story: three LIVE pages built from the app's real components (a chat turn that streams,
// the real ApprovalCard, real ToolRows) inside a phone-shaped card — not screenshots. Each page scripts
// itself when it becomes the current page and stops when it leaves (`.task(id:)`), so swiping back
// replays it. Copy follows the loopl.dev landing: ≤ 12 words per headline, one supporting line.

enum OnboardingStory {
    struct Page: Identifiable {
        let id: Int
        let headline: String
        let line: String
    }
    static let pages: [Page] = [
        Page(id: 0, headline: "Works with the network off.", line: "The model runs on the chip in your pocket. Airplane mode changes nothing."),
        Page(id: 1, headline: "Asks before it acts.", line: "Anything that leaves the device waits for your tap. Deny, and the model is told so."),
        Page(id: 2, headline: "Sees. Listens.", line: "Send a photo. Record a take. The tools do the rest — on the device."),
    ]
    static let tagline = "Agents that run on your phone."
}

/// One story page: headline, supporting line, and the live scene in a phone-shaped card.
struct StoryPageView: View {
    var page: OnboardingStory.Page
    var active: Bool
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        // The page is at least as tall as its container (so the card fills a phone and the block centres on an iPad)
        // and scrolls only when the text itself is taller (accessibility sizes).
        GeometryReader { g in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 8) {
                    Text(page.headline)
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(page.line)
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                PhoneCard {
                    switch page.id {
                    case 0: OfflineScene(active: active)
                    case 1: ApprovalScene(active: active)
                    default: SensesScene(active: active)
                    }
                }
                .frame(minHeight: type.isAccessibilitySize ? 260 : 340)
                .frame(maxHeight: 560)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LooplDesign.gutter)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, minHeight: g.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityIdentifier("onboarding-page-\(page.id)")
    }
}

/// A phone screen, abstractly: a tall rounded canvas on the system background with a hairline edge and a soft
/// shadow, content pinned to the top the way a transcript is. The scenes inside are the app's own views.
struct PhoneCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            FauxComposer()
        }
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.10), radius: 24, y: 12)
            .clipped()
    }
}

// MARK: - Scene 1 · works offline

private struct OfflineScene: View {
    var active: Bool
    @State private var text = ""
    @State private var streaming = false
    @State private var sent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let answer = "72 °F is **22.2 °C**. Subtract 32, then multiply by 5/9: 40 × 5/9 ≈ 22.2."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: LooplDesign.iconOffline).font(.caption.weight(.semibold))
                Text("Offline").font(.caption.weight(.semibold))
            }
            .foregroundStyle(LooplDesign.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(LooplDesign.accent.opacity(0.14), in: Capsule())
            .accessibilityLabel("Offline mode on")

            if sent {
                UserTurn("Convert 72 °F to Celsius and show the steps.", menu: false)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if !text.isEmpty || streaming {
                MarkdownBody(text, streaming: streaming)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: sent)
        .task(id: active) {
            text = ""; streaming = false; sent = false
            guard active else { return }
            try? await Task.sleep(for: .seconds(0.5))
            sent = true
            try? await Task.sleep(for: .seconds(0.7))
            streaming = true
            // Word by word, the way tokens land — pace is the real 0.8B on an A18, roughly.
            for word in Self.answer.split(separator: " ", omittingEmptySubsequences: false) {
                guard !Task.isCancelled else { return }
                text += (text.isEmpty ? "" : " ") + word
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 45 : 70))
            }
            streaming = false
        }
    }
}

// MARK: - Scene 2 · asks before it acts

private struct ApprovalScene: View {
    var active: Bool
    @State private var sent = false
    @State private var card = false
    @State private var decision: ApprovalDecision?
    @State private var showRow = false
    @State private var result: ToolResult?
    @State private var reply = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let request = ApprovalRequest(
        id: "onb-approval", toolName: "http", title: "POST api.notes.app",
        method: "POST", url: "https://api.notes.app/v1/notes",
        headers: ["Content-Type": "application/json"],
        bodyPreview: #"{"text":"Build is green ✓","tags":["ci"]}"#,
        detail: "Sends 41 bytes of JSON to api.notes.app.", risk: .medium,
        input: ["method": .string("POST"), "url": .string("https://api.notes.app/v1/notes")])
    private static let use = ToolUse(toolUseId: "onb-approval", name: "http", input: request.input)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sent {
                UserTurn("Post “Build is green ✓” to my notes.", menu: false)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if card {
                ApprovalCard(request: Self.request, decision: decision) { d in decide(d) }
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                    .accessibilityIdentifier("onboarding-approval")
            }
            if showRow {
                ToolRow(call: Self.use, result: result).transition(.opacity)
            }
            if !reply.isEmpty {
                MarkdownBody(reply, streaming: false).transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: sent)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: card)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: decision)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: showRow)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: reply)
        .task(id: active) {
            sent = false; card = false; decision = nil; showRow = false; result = nil; reply = ""
            guard active else { return }
            try? await Task.sleep(for: .seconds(0.5))
            sent = true
            try? await Task.sleep(for: .seconds(0.8))
            card = true
            // Left alone, the preview approves itself after a beat — the page still tells the story in a recording.
            try? await Task.sleep(for: .seconds(3.2))
            if !Task.isCancelled, decision == nil { decide(.approve) }
        }
    }

    private func decide(_ d: ApprovalDecision) {
        guard decision == nil else { return }
        decision = d
        if d.isApproved { LooplDesign.success() } else { LooplDesign.haptic() }
        Task {
            // The card collapses to its one quiet line first; the tool row lands once that motion is done.
            try? await Task.sleep(for: .seconds(0.45))
            guard !Task.isCancelled, active else { return }
            showRow = true
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled, active else { return }
            if d.isApproved {
                result = ToolResult(toolUseId: Self.use.toolUseId, name: "http", status: .success,
                                    content: "HTTP 201 Created\n{\"id\":\"n_8f2\"}", durationMs: 212)
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled else { return }
                reply = "Posted — note `n_8f2` is in your notebook."
            } else {
                result = ToolResult(toolUseId: Self.use.toolUseId, name: "http", status: .error,
                                    content: "Tool call denied by the user. Do not retry it; continue without it.", durationMs: 1)
                try? await Task.sleep(for: .seconds(0.5))
                guard !Task.isCancelled else { return }
                reply = "Okay — I didn't send it. Your note is still here if you change your mind."
            }
        }
    }
}

// MARK: - Scene 3 · sees and listens

private struct SensesScene: View {
    var active: Bool
    @State private var sent = false
    @State private var describe: ToolResult?
    @State private var transcribe: ToolResult?
    @State private var showDescribe = false
    @State private var showTranscribe = false
    @State private var reply = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let describeUse = ToolUse(toolUseId: "onb-describe", name: "describe_image", input: ["image": .string("photo-1")])
    private static let transcribeUse = ToolUse(toolUseId: "onb-transcribe", name: "transcribe", input: ["path": .string("take-1.m4a")])
    private static let photo = OnboardingArt.harbour()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sent {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).kerning(0.6)
                    HStack(alignment: .center, spacing: 10) {
                        ImageTile(Self.photo, maxHeight: 64)
                        RecordingChip(duration: 4)
                    }
                    Text("What's in the photo, and what did I say?").font(.body).lineSpacing(4).foregroundStyle(.primary.opacity(0.85))
                }
                .accessibilityElement(children: .combine)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if showDescribe { ToolRow(call: Self.describeUse, result: describe).transition(.opacity) }
            if showTranscribe { ToolRow(call: Self.transcribeUse, result: transcribe).transition(.opacity) }
            if !reply.isEmpty { MarkdownBody(reply, streaming: false).transition(.opacity) }
            Spacer(minLength: 0)
        }
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: sent)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: showDescribe)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: showTranscribe)
        .animation(LooplDesign.Motion.faded(LooplDesign.Motion.spring, reduceMotion), value: reply)
        .task(id: active) {
            sent = false; describe = nil; transcribe = nil; showDescribe = false; showTranscribe = false; reply = ""
            guard active else { return }
            try? await Task.sleep(for: .seconds(0.5))
            sent = true
            try? await Task.sleep(for: .seconds(0.9))
            showDescribe = true
            try? await Task.sleep(for: .seconds(0.4))
            showTranscribe = true
            try? await Task.sleep(for: .seconds(1.1))
            describe = ToolResult(toolUseId: "onb-describe", name: "describe_image", content: "A harbour at sunset: two boats, orange sky, calm water.", durationMs: 1340)
            try? await Task.sleep(for: .seconds(0.6))
            transcribe = ToolResult(toolUseId: "onb-transcribe", name: "transcribe", content: "remind me to call Ada at six", durationMs: 980)
            try? await Task.sleep(for: .seconds(0.6))
            reply = "A harbour at sunset, two boats. You said *remind me to call Ada at six* — set the reminder?"
        }
    }
}

/// The composer's recording chip, as a still: play dot, waveform, length. (The real `AudioClipChip` wants a file.)
private struct RecordingChip: View {
    var duration: TimeInterval
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30).background(LooplDesign.accent, in: Circle()).foregroundStyle(.white)
            StaticWaveform(seed: "take-1.m4a", fill: 0).frame(width: 72, height: 22)
            Text(String(format: "0:%02d", Int(duration))).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, 4 seconds")
    }
}

/// The composer as scenery: the field, the photo and mic buttons — so the card reads as the chat screen.
private struct FauxComposer: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").font(.body).foregroundStyle(.secondary)
            Text("Message").font(.body).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: Capsule())
            Image(systemName: "mic").font(.body).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .accessibilityHidden(true)
    }
}

/// Drawn, not shipped: a small "photo" for the story so the bundle carries no JPEG and the tile is always crisp.
enum OnboardingArt {
    static func harbour() -> ImageBlock {
        let size = CGSize(width: 480, height: 320)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 2
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cg = ctx.cgContext
            let sky = CGGradient(colorsSpace: nil, colors: [
                UIColor(red: 0.98, green: 0.55, blue: 0.22, alpha: 1).cgColor,
                UIColor(red: 0.99, green: 0.78, blue: 0.36, alpha: 1).cgColor,
                UIColor(red: 0.42, green: 0.22, blue: 0.36, alpha: 1).cgColor] as CFArray, locations: [0, 0.55, 1])!
            cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            // Sun
            cg.setFillColor(UIColor(white: 1, alpha: 0.85).cgColor)
            cg.fillEllipse(in: CGRect(x: 300, y: 118, width: 64, height: 64))
            // Water
            cg.setFillColor(UIColor(red: 0.22, green: 0.16, blue: 0.3, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 190, width: size.width, height: 130))
            cg.setFillColor(UIColor(red: 0.98, green: 0.6, blue: 0.3, alpha: 0.35).cgColor)
            for i in 0..<6 { cg.fill(CGRect(x: 280 + CGFloat(i) * 6, y: 200 + CGFloat(i) * 14, width: 100 - CGFloat(i) * 12, height: 3)) }
            // Two boats
            cg.setFillColor(UIColor(red: 0.08, green: 0.06, blue: 0.1, alpha: 1).cgColor)
            for (x, w) in [(90.0, 70.0), (210.0, 48.0)] {
                let hull = UIBezierPath()
                hull.move(to: CGPoint(x: x, y: 200)); hull.addLine(to: CGPoint(x: x + w, y: 200))
                hull.addLine(to: CGPoint(x: x + w - 10, y: 214)); hull.addLine(to: CGPoint(x: x + 10, y: 214)); hull.close()
                cg.addPath(hull.cgPath); cg.fillPath()
                cg.fill(CGRect(x: x + w / 2 - 1.5, y: 150, width: 3, height: 50))
            }
        }
        return ImageBlock(data: img.pngData() ?? Data(), mime: "image/png", width: 960, height: 640, alt: "A harbour at sunset")
    }
}
