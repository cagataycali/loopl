import SwiftUI
import UniformTypeIdentifiers
import Loopl
import LooplUI

/// Share a conversation as a Markdown file or as a picture of the transcript (#20) — from the chat toolbar and the
/// History context menu. Everything is rendered on the device; the share sheet decides where it goes.
enum ConversationShare {
    static let markdownType = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText

    /// The conversation as Markdown: title, model + date, each turn under a bold speaker, tool calls as one quiet
    /// line with their result in a fenced block (trimmed), notes in italics. Pictures are counted, not embedded.
    static func markdown(_ c: SavedConversation) -> String {
        var out = ["# \(c.title.replacingOccurrences(of: "\n", with: " "))", ""]
        var meta = [c.updated.formatted(date: .abbreviated, time: .shortened)]
        if let m = c.modelName { meta.insert(m, at: 0) }
        out.append("_\(meta.joined(separator: " · ")) · on-device with [loopl](https://loopl.dev)_")
        out.append("")
        for item in c.items {
            switch item {
            case .user(let s, let images, let videos):
                let text = AudioAttachmentMarker.split(s)
                var head = "**You**"
                var extras: [String] = []
                if let n = images?.count, n > 0 { extras.append("\(n) image\(n == 1 ? "" : "s")") }
                if let vids = videos, !vids.isEmpty { extras.append(vids.map { "video \($0.clock)" }.joined(separator: ", ")) }
                if !text.clips.isEmpty { extras.append("\(text.clips.count) recording\(text.clips.count == 1 ? "" : "s")") }
                if !extras.isEmpty { head += " _(\(extras.joined(separator: ", ")))_" }
                out += [head, "", text.text, ""]
            case .assistant(let s):
                out += ["**loopl**", "", s, ""]
            case .tool(let name, let args, let result, let isError, _, _, _):
                let argText = args.isEmpty ? "" : " `" + compact(args) + "`"
                out.append("> \(isError ? "✗" : "✓") **\(name)**\(argText)")
                if let r = result, !r.isEmpty {
                    out += [">", "> ```", r.prefix(600).split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n"), "> ```"]
                    if r.count > 600 { out.append("> …") }
                }
                out.append("")
            case .note(let s):
                out += ["_\(s)_", ""]
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func compact(_ args: [String: JSONValue]) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let s = (try? enc.encode(args)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return s.count > 120 ? String(s.prefix(117)) + "…" : s
    }

    /// A safe file name from the title ("What's the weather?" → "Whats the weather.md").
    static func fileName(_ c: SavedConversation, ext: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>'\n\r\t")
        let base = c.title.components(separatedBy: bad).joined().trimmingCharacters(in: .whitespaces)
        return String((base.isEmpty ? "loopl conversation" : base).prefix(60)) + "." + ext
    }

    /// The transcript column rendered to a PNG (3×, 390 pt wide — a phone screenshot's width, any length up to the cap).
    @MainActor static func image(_ c: SavedConversation, dark: Bool = false) -> Data? {
        let r = ImageRenderer(content: ShareCard(conversation: c).environment(\.colorScheme, dark ? .dark : .light).environment(\.looplStaticRender, true))
        r.scale = 3
        r.proposedSize = ProposedViewSize(width: ShareCard.width, height: nil)
        #if canImport(UIKit)
        return r.uiImage?.pngData()
        #else
        return nil
        #endif
    }
}

/// What the share sheet receives. Markdown is a `.md` file named after the conversation; the image is a PNG.
struct MarkdownTranscript: Transferable {
    var conversation: SavedConversation
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: ConversationShare.markdownType) { t in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(ConversationShare.fileName(t.conversation, ext: "md"))
            try Data(ConversationShare.markdown(t.conversation).utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
        ProxyRepresentation { ConversationShare.markdown($0.conversation) }   // apps that only take text (Messages, Notes)
    }
}

struct TranscriptImage: Transferable {
    var conversation: SavedConversation
    var dark: Bool
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { t in
            guard let d = await ConversationShare.image(t.conversation, dark: t.dark) else { throw CocoaError(.fileWriteUnknown) }
            return d
        }
        .suggestedFileName { ConversationShare.fileName($0.conversation, ext: "png") }
    }
}

/// The two share entries, for a toolbar Menu or a context menu.
struct ConversationShareItems: View {
    var conversation: SavedConversation
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ShareLink(item: MarkdownTranscript(conversation: conversation),
                  preview: SharePreview(ConversationShare.fileName(conversation, ext: "md"), image: Image(systemName: "doc.plaintext"))) {
            Label("Share as Markdown", systemImage: "doc.plaintext")
        }
        .accessibilityIdentifier("share-markdown")
        ShareLink(item: TranscriptImage(conversation: conversation, dark: scheme == .dark),
                  preview: SharePreview(conversation.title, image: Image(systemName: "photo"))) {
            Label("Share as image", systemImage: "photo")
        }
        .accessibilityIdentifier("share-image")
    }
}

/// A static transcript column for `ImageRenderer` (no ScrollView/List — those render empty): header with the
/// mark, the turns as the chat draws them, tool calls as one line each, a quiet footer.
struct ShareCard: View {
    static let width: CGFloat = 390
    static let maxItems = 40
    var conversation: SavedConversation
    var body: some View {
        let items = Array(conversation.items.prefix(Self.maxItems))
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                LooplMark().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title).font(.headline).lineLimit(2)
                    Text([conversation.modelName, conversation.updated.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .user(let s, let images, let videos): UserTurn(s, images: images ?? [], videos: videos ?? [], menu: false)
                case .assistant(let s): MarkdownBody(s)
                case .tool(let name, _, _, let isError, let ms, _, _):
                    HStack(spacing: 6) {
                        Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(isError ? Color.red : LooplDesign.accent)
                        Text(name).font(.subheadline.monospaced())
                        if ms > 0 { Text(ms < 1000 ? "\(Int(ms)) ms" : String(format: "%.1f s", ms / 1000)).font(.caption).foregroundStyle(.secondary) }
                    }
                case .note(let s): Text(s).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if conversation.items.count > Self.maxItems {
                Text("… \(conversation.items.count - Self.maxItems) more").font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            Text("loopl · runs on this \(LooplDesign.deviceName) · loopl.dev").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(LooplDesign.gutter)
        .frame(width: Self.width, alignment: .leading)
        .background(Color(.systemBackground))
    }
}
