import Foundation
import Loopl
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// `clipboard` — the system pasteboard as a tool (owner 2026-10-06: "a clipboard tool in iOS to
// read/write the clipboard"). Reading hands the model the copied text, or the copied picture as an
// image on the result (the transcript shows it; `describe_image` can read it). Writing REPLACES
// the clipboard, so it is HITL: the approval card quotes the text before anything changes.
//
// Two schema shapes exist so the real-model harness (`ClipboardShapeMeasurement`) can pick the one a
// 0.8B calls correctly: shape A is ONE tool with `action: read|write`; shape B is `clipboard_read` +
// `clipboard_write`. MEASURED 2026-10-06 (temp 0.7, app prompt, full tool list, 3 runs × 3 scenarios):
//   Qwen3.5-0.8B-4bit  A 0/9 — "What did I just copy?" became `clipboard{action:"write"}` 4 of 6 times
//                       B 2/9 — reads right 2/3, writes with the right text 1/3
//   loopl-2b-4bit      A 9/9 · B 9/9 (approval card approved=1 on every write)
// `AppleTools.all` ships shape B; shape A stays for the measurement and the SDK.

/// Pasteboard access that works on iOS (UIPasteboard) and on the macOS test host (NSPasteboard),
/// so the harness executes the tool for real instead of recording "unavailable".
public enum Clipboard {
    public static let maxTextChars = 4_000

    public static var isAvailable: Bool {
        #if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)
        return true
        #else
        return false
        #endif
    }

    /// What is on the clipboard right now, without reading the content (no paste banner on iOS).
    public struct Peek: Sendable, Hashable { public var hasText: Bool; public var hasImage: Bool; public var hasURL: Bool }
    public static func peek() -> Peek {
        #if canImport(UIKit) && !os(watchOS)
        return MainActor.assumeIsolatedIfPossible {
            let p = UIPasteboard.general
            return Peek(hasText: p.hasStrings, hasImage: p.hasImages, hasURL: p.hasURLs)
        }
        #elseif canImport(AppKit)
        let p = NSPasteboard.general
        let types = Set(p.types ?? [])
        return Peek(hasText: types.contains(.string), hasImage: types.contains(.png) || types.contains(.tiff), hasURL: types.contains(.URL))
        #else
        return Peek(hasText: false, hasImage: false, hasURL: false)
        #endif
    }

    public static func readText() -> String? {
        #if canImport(UIKit) && !os(watchOS)
        return MainActor.assumeIsolatedIfPossible { UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString }
        #elseif canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }

    /// The copied picture, re-encoded as JPEG ≤ 1024 px like the composer's attachments.
    public static func readImage() -> ImageBlock? {
        #if canImport(UIKit) && !os(watchOS)
        guard let cg = MainActor.assumeIsolatedIfPossible({ UIPasteboard.general.image?.cgImage }) else { return nil }
        return try? ImageCodec.jpeg(cg, alt: "picture from the clipboard")
        #elseif canImport(AppKit)
        guard let img = NSImage(pasteboard: NSPasteboard.general), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return try? ImageCodec.jpeg(cg, alt: "picture from the clipboard")
        #else
        return nil
        #endif
    }

    @discardableResult
    public static func write(_ text: String) -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        MainActor.assumeIsolatedIfPossible { UIPasteboard.general.string = text }
        return true
        #elseif canImport(AppKit)
        let p = NSPasteboard.general
        p.clearContents()
        return p.setString(text, forType: .string)
        #else
        return false
        #endif
    }

    // MARK: shared behaviour for both shapes

    /// `read` — text (truncated at `maxTextChars`, says so), else the picture, else "empty".
    public static func performRead() -> ToolOutput {
        let peek = peek()
        if let text = readText(), !text.isEmpty {
            if text.count > maxTextChars {
                let cut = String(text.prefix(maxTextChars))
                return ToolOutput(text: "clipboard: text (\(text.count) characters, first \(maxTextChars) shown)\n\(cut)")
            }
            var head = "clipboard: text (\(text.count) characters)"
            if peek.hasImage { head += " — a picture is also on the clipboard" }
            return ToolOutput(text: head + "\n" + text)
        }
        if peek.hasImage, let img = readImage() {
            let size = (img.width != nil && img.height != nil) ? " \(img.width!)×\(img.height!)" : ""
            return ToolOutput(text: "clipboard: a picture\(size), attached to this result — call describe_image to see what is in it", images: [img])
        }
        return ToolOutput(text: "clipboard: empty")
    }

    /// `write` — validated text, then the replacement. The approval card has already been shown by then.
    public static func performWrite(_ text: String) throws -> String {
        guard !text.isEmpty else { throw ToolError("text must not be empty — give the text to put on the clipboard") }
        guard write(text) else { throw ToolError("could not write to the clipboard") }
        return "clipboard: replaced with \(text.count) character\(text.count == 1 ? "" : "s")"
    }

    /// The card for a write: quotes the text so the human sees exactly what replaces the clipboard.
    public static func approval(toolName: String, text: String, input: [String: JSONValue]) -> ApprovalRequest {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        let preview = one.count > 80 ? String(one.prefix(77)) + "…" : one
        let current = peek()
        var detail = "Replaces what is on the clipboard"
        if current.hasText || current.hasImage { detail += " (currently \(current.hasImage && !current.hasText ? "a picture" : "text"))" }
        return ApprovalRequest(toolName: toolName, title: "Copy to clipboard · \(preview)", method: "COPY", url: nil,
                               bodyPreview: text, detail: detail, risk: .medium, input: input)   // .low is auto-approved by the default .mutating policy — replacing the clipboard must ask
    }

    static let actions = ["read", "write"]
    static let unavailableReason = "Needs an iPhone, iPad or Mac"
    static let onDeviceCopy = "Reads what you copied (text or a picture) and, after asking you, copies text back. Nothing leaves the device."
}

// MARK: - Shape A: one tool, `action: read|write`

public struct ClipboardTool: AppleTool {
    public init() {}
    public let name = "clipboard"
    public let description = "Read what the user copied to the clipboard (text, a link or a picture) with action \"read\", or copy text to the clipboard with action \"write\" and text. Use read when the user says \"paste\", \"what I copied\" or \"my clipboard\"; use write when they ask to copy something."
    public let parameters: JSONValue = ToolSchema.object([
        "action": ["type": "string", "enum": ["read", "write"], "description": "read = get the clipboard contents; write = put text on the clipboard"],
        "text": ToolSchema.string("The text to copy (write only)"),
    ], required: ["action"])
    public static let onDeviceCopy = Clipboard.onDeviceCopy
    public static var defaultOn: Bool { true }

    public struct Request: Sendable, Hashable { public var action: String; public var text: String? }
    /// Lenient like the memory tools: a missing action with `text` present means write; `value`/`content` alias `text`.
    public static func parse(_ args: [String: JSONValue]) throws -> Request {
        let text = args.string("text") ?? args.string("value") ?? args.string("content")
        var action = args.string("action")?.lowercased().trimmingCharacters(in: .whitespaces)
        if action == nil || action == "" { action = text == nil ? "read" : "write" }
        if action == "get" || action == "paste" { action = "read" }
        if action == "set" || action == "copy" { action = "write" }
        guard let a = action, Clipboard.actions.contains(a) else { throw ToolError("action must be read or write") }
        if a == "write", text == nil { throw ToolError("write needs text — the text to copy") }
        return Request(action: a, text: text)
    }

    public static func availability() -> ToolAvailability { Clipboard.isAvailable ? .ok : .no(Clipboard.unavailableReason) }

    public func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
        guard let r = try? Self.parse(input), r.action == "write", let t = r.text, !t.isEmpty else { return nil }
        return Clipboard.approval(toolName: name, text: t, input: input)
    }

    public func call(_ args: [String: JSONValue]) async throws -> String { try await callOutput(args).text }
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        let r = try Self.parse(args)
        let a = Self.availability()
        guard a.available else { throw ToolError("clipboard is not available here: \(a.reason)") }
        switch r.action {
        case "write": return ToolOutput(text: try Clipboard.performWrite(r.text ?? ""))
        default: return Clipboard.performRead()
        }
    }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}

// MARK: - Shape B: two tools

public struct ClipboardReadTool: AppleTool {
    public init() {}
    public let name = "clipboard_read"
    public let description = "Read what the user copied to the clipboard: text, a link or a picture. Use when the user says \"paste\", \"what I copied\", \"what's on my clipboard\" or asks you to use the copied text."
    public let parameters: JSONValue = ToolSchema.object([:])
    public static let onDeviceCopy = "Reads what you copied (text or a picture). Nothing leaves the device."
    public static var defaultOn: Bool { true }
    public static func availability() -> ToolAvailability { Clipboard.isAvailable ? .ok : .no(Clipboard.unavailableReason) }
    public func call(_ args: [String: JSONValue]) async throws -> String { try await callOutput(args).text }
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput {
        let a = Self.availability()
        guard a.available else { throw ToolError("clipboard_read is not available here: \(a.reason)") }
        return Clipboard.performRead()
    }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}

public struct ClipboardWriteTool: AppleTool {
    public init() {}
    public let name = "clipboard_write"
    public let description = "Copy text to the user's clipboard, replacing what is there. Use when the user asks to copy something."
    public let parameters: JSONValue = ToolSchema.object(["text": ToolSchema.string("The text to copy")], required: ["text"])
    public static let onDeviceCopy = "Copies text to the clipboard after asking you."
    public static var defaultOn: Bool { true }
    public static func availability() -> ToolAvailability { Clipboard.isAvailable ? .ok : .no(Clipboard.unavailableReason) }
    static func text(_ args: [String: JSONValue]) -> String? { args.string("text") ?? args.string("value") ?? args.string("content") }
    public func requiresApproval(for input: [String: JSONValue]) -> ApprovalRequest? {
        guard let t = Self.text(input), !t.isEmpty else { return nil }
        return Clipboard.approval(toolName: name, text: t, input: input)
    }
    public func call(_ args: [String: JSONValue]) async throws -> String {
        let a = Self.availability()
        guard a.available else { throw ToolError("clipboard_write is not available here: \(a.reason)") }
        guard let t = Self.text(args) else { throw ToolError("need text — the text to copy") }
        return try Clipboard.performWrite(t)
    }
    public func callOutput(_ args: [String: JSONValue]) async throws -> ToolOutput { ToolOutput(text: try await call(args)) }
    public func call(_ args: [String: JSONValue], images: [ImageBlock]) async throws -> ToolOutput { try await callOutput(args) }
}
