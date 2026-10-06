import Foundation
import Observation
import SwiftUI
import Loopl
import LooplUI

/// Saved conversations — a JSON file per conversation in Application Support.
/// The transcript is what is kept (what you saw), not the model's raw messages.
struct SavedConversation: Codable, Identifiable, Hashable {
    enum Item: Codable, Hashable {
        /// `images`: the pictures the user attached / a tool produced, kept as ≤ 512 px thumbnails (see `HistoryImage`)
        /// so a reopened vision thread still shows what was sent. Optional + decodeIfPresent — 0.1 files decode as nil.
        case user(String, images: [ImageBlock]?), assistant(String), tool(name: String, args: [String: JSONValue], result: String?, isError: Bool, ms: Double, images: [ImageBlock]?), note(String)

        /// Text-only spellings (fixtures, tests, the pre-images call sites).
        static func user(_ s: String) -> Item { .user(s, images: nil) }
        static func tool(name: String, args: [String: JSONValue], result: String?, isError: Bool, ms: Double) -> Item {
            .tool(name: name, args: args, result: result, isError: isError, ms: ms, images: nil)
        }
    }
    var id: UUID
    var title: String
    var updated: Date
    var modelName: String?
    var items: [Item]
    /// Set when the thread was rewritten (a message edited, retried, or cut) — optional so 0.1 files still decode.
    var editedAt: Date?
    /// Phase 5 (Share to Hugging Face): the Hub id of the model that answered and the tools the thread OFFERED
    /// (OpenAI function specs). Optional + tolerant — files saved before this field exist decode as nil.
    var modelId: String?
    var tools: [ToolSpec]?

    init(id: UUID, title: String, updated: Date, modelName: String?, items: [Item], editedAt: Date? = nil, modelId: String? = nil, tools: [ToolSpec]? = nil) {
        self.id = id; self.title = title; self.updated = updated; self.modelName = modelName; self.items = items
        self.editedAt = editedAt; self.modelId = modelId; self.tools = tools
    }

    static func from(_ t: Transcript, id: UUID, modelName: String?, editedAt: Date? = nil, modelId: String? = nil, tools: [ToolSpec]? = nil) -> SavedConversation? {
        let items: [Item] = t.items.compactMap {
            switch $0.kind {
            case .user(let s): .user(s, images: HistoryImage.thumbnails($0.images))
            case .assistant(let s): .assistant(s)
            case .toolUse(let c, let r): .tool(name: c.name, args: c.input, result: r?.content, isError: r?.isError ?? false, ms: r?.durationMs ?? 0, images: HistoryImage.thumbnails($0.images))
            case .note(let s): .note(s)
            case .approval(let req, let d):
                switch d {
                case nil: nil                                   // still waiting — the agent will not be there on reopen
                case .deny(let reason)?: .note("denied \(req.title)" + (reason.map { " — \($0)" } ?? ""))
                case .approve?, .approveEdited?: .note("approved \(req.title)")
                }
            case .reasoning: nil
            }
        }
        guard items.contains(where: { if case .user = $0 { return true }; return false }) else { return nil }
        let first = items.compactMap { if case .user(let s, _) = $0 { return s }; return nil }.first ?? "Conversation"
        return SavedConversation(id: id, title: String(first.prefix(60)), updated: Date(), modelName: modelName, items: items, editedAt: editedAt, modelId: modelId, tools: tools)
    }

    /// Everything strictly before the item at `index` (History-level "delete from here" / the kept half of an edit).
    func truncated(before index: Int) -> SavedConversation {
        var c = self
        c.items = Array(items.prefix(max(0, index)))
        c.editedAt = Date()
        c.updated = c.editedAt!
        return c
    }

    /// Replace the user message at `index` (must be a `.user` item) and drop everything after it.
    func replacing(userAt index: Int, with text: String) -> SavedConversation? {
        guard items.indices.contains(index), case .user(_, let images) = items[index] else { return nil }
        var c = truncated(before: index)
        c.items.append(.user(text, images: images))
        if index == 0 { c.title = String(text.prefix(60)) }
        return c
    }

    /// What `ConversationExport` needs: the transcript as agent messages. Each tool row becomes an
    /// assistant tool call + its result turn; rows without a result (interrupted) and notes are not learnable and are skipped.
    func exportThread() -> ConversationExport.Thread {
        var messages: [Message] = []
        for item in items {
            switch item {
            // Pictures go along (as the ≤ 512 px thumbnails History keeps) — ConversationExport writes them to images/<sha>.png
            // unless the person ticks "Remove pictures". Dropping them here made every shared dataset text-only (TRAIN-E2E-VISION).
            case .user(let s, let images): messages.append(images.map { $0.isEmpty ? .user(s) : .user(s, images: $0) } ?? .user(s))
            case .assistant(let s): messages.append(.assistant(s))
            case .tool(let name, let args, let result, let isError, let ms, _):
                guard let result else { continue }
                let use = ToolUse(name: name, input: args)
                messages.append(.assistant(text: "", toolUses: [use]))
                messages.append(.toolResults([ToolResult(toolUseId: use.toolUseId, name: name, status: isError ? .error : .success, content: result, durationMs: ms)]))
            case .note: continue
            }
        }
        return ConversationExport.Thread(id: id.uuidString, title: title, messages: messages, tools: tools ?? [], modelId: modelId ?? modelName, updated: updated)
    }

    func transcript() -> Transcript {
        var t = Transcript()
        t.items = items.map {
            switch $0 {
            case .user(let s, let images): return TranscriptItem(kind: .user(s), images: images ?? [])
            case .assistant(let s): return TranscriptItem(kind: .assistant(s))
            case .tool(let name, let args, let result, let isError, let ms, let images):
                let use = ToolUse(name: name, input: args)
                return TranscriptItem(kind: .toolUse(use, result: result.map { ToolResult(toolUseId: use.toolUseId, name: name, status: isError ? .error : .success, content: $0, durationMs: ms) }), images: images ?? [])
            case .note(let s): return TranscriptItem(kind: .note(s))
            }
        }
        t.isRunning = false
        return t
    }
}

/// Pictures in saved conversations: a ≤ 512 px JPEG per image (≈ 40–120 KB) so History stays small and the
/// reopened thread still shows what was sent. Nothing is ever upscaled; already-small PNGs keep their bytes.
enum HistoryImage {
    static let maxEdge: CGFloat = 512
    static let maxStoredBytes = 400_000

    static func thumbnails(_ images: [ImageBlock]) -> [ImageBlock]? {
        guard !images.isEmpty else { return nil }
        return images.compactMap(thumbnail)
    }

    static func thumbnail(_ b: ImageBlock) -> ImageBlock? {
        if b.data.count <= maxStoredBytes, let w = b.width, let h = b.height, max(w, h) <= Int(maxEdge) { return b }
        guard let ui = UIImage(data: b.data) else { return nil }
        let scaled = ui.normalizedOrientation().downscaled(maxEdge: maxEdge)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.8) else { return nil }
        return ImageBlock(data: jpeg, mime: "image/jpeg", width: Int(scaled.size.width * scaled.scale), height: Int(scaled.size.height * scaled.scale), alt: b.alt)
    }
}

@MainActor @Observable
final class ConversationArchive {
    private(set) var conversations: [SavedConversation] = []
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        conversations = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(SavedConversation.self, from: Data(contentsOf: $0)) }.sorted { $0.updated > $1.updated }
    }

    func upsert(_ c: SavedConversation) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(c) { try? data.write(to: Self.root.appendingPathComponent("\(c.id.uuidString).json"), options: .atomic) }
        conversations.removeAll { $0.id == c.id }
        conversations.insert(c, at: 0)
    }

    func delete(_ c: SavedConversation) { delete(id: c.id) }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent("\(id.uuidString).json"))
        AudioAttachment.removeDirectory(for: id)   // recordings go with the thread
        conversations.removeAll { $0.id == id }
    }

    func deleteAll() { conversations.forEach(delete) }
}

/// The sidebar (iPad) / sheet (iPhone) list of saved conversations. Swipe left deletes.
struct HistoryList: View {
    @Bindable var engine: Engine
    @Binding var selection: RootView.Pane
    var dismiss: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Edit mode: multi-select → "Share to Hugging Face" (Phase 5). `selecting` is the only state the
    // normal list path reads, so nothing changes for the tap-to-open flow.
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var sharing: ShareBatch? = nil
    struct ShareBatch: Identifiable { let id = UUID(); var conversations: [SavedConversation] }

    var body: some View {
        List(selection: $selected) {
            Section {
                Button {
                    engine.newConversation(); selection = .chat; dismiss?()
                } label: { Label("New conversation", systemImage: "square.and.pencil") }
                .accessibilityHint("starts an empty conversation")
            }
            if !engine.archive.conversations.isEmpty {
                Section("History") {
                    ForEach(engine.archive.conversations) { c in
                        Button {
                            if selecting { toggle(c.id); return }
                            LooplDesign.haptic(); engine.open(c); selection = .chat; dismiss?()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.title).lineLimit(2).foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Text(c.updated, format: .relative(presentation: .named))
                                    if let m = c.modelName { Text("·"); Text(m) }
                                    if c.editedAt != nil { Text("·"); Label("edited", systemImage: "pencil").labelStyle(.titleAndIcon).accessibilityLabel("edited") }
                                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(c.id)
                        .listRowBackground(engine.currentId == c.id && !selecting ? LooplDesign.accent.opacity(0.1) : nil)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { withAnimation(reduceMotion ? nil : LooplDesign.spring) { engine.delete(c) } } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button("Copy transcript", systemImage: "doc.on.doc") { copyTranscript(c) }
                            Button("Share to Hugging Face", systemImage: "square.and.arrow.up") { LooplDesign.haptic(); sharing = ShareBatch(conversations: [c]) }
                            Button("Select", systemImage: "checkmark.circle") { beginSelecting(c.id) }
                            Button("Delete", systemImage: "trash", role: .destructive) { engine.delete(c) }
                        }
                        .accessibilityLabel("\(c.title), \(c.updated.formatted(.relative(presentation: .named)))")
                        .accessibilityHint("opens the conversation; swipe up or down for delete")
                    }
                }
            }
            if dismiss == nil {
                Section {
                    Button { selection = .models } label: { Label("Models", systemImage: LooplDesign.iconModels) }
                    Button { selection = .settings } label: { Label("Settings", systemImage: LooplDesign.iconSettings) }
                }
            }
        }
        // Shown as a sheet (from Chat) or as the iPad sidebar — no tab bar behind it
        // in either case, so only the home-indicator air applies.
        .looplBottomBar(false)
        .looplScrollClearance()
        .navigationTitle(selecting ? "\(selected.count) selected" : "loopl")
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .toolbar {
            if !engine.archive.conversations.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "Cancel" : "Select") {
                        LooplDesign.haptic()
                        withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { selecting.toggle(); if !selecting { selected.removeAll() } }
                    }
                    .accessibilityIdentifier("history.select")
                    .accessibilityHint(selecting ? "leaves selection mode" : "select conversations to share to Hugging Face")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: 12) {
                    Button(selected.count == engine.archive.conversations.count ? "Deselect all" : "Select all") {
                        LooplDesign.haptic()
                        if selected.count == engine.archive.conversations.count { selected.removeAll() } else { selected = Set(engine.archive.conversations.map(\.id)) }
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("history.selectAll")
                    Spacer()
                    Button {
                        LooplDesign.haptic(1)
                        sharing = ShareBatch(conversations: engine.archive.conversations.filter { selected.contains($0.id) })
                    } label: {
                        Label("Share to Hugging Face", systemImage: "square.and.arrow.up").font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent).tint(LooplDesign.accent)
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("history.share")
                    .accessibilityHint("exports the selected conversations to a private dataset in your Hugging Face account")
                }
                .padding(.horizontal, LooplDesign.gutter).padding(.vertical, 10)
                .background(.bar)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $sharing) { batch in
            HubShareView(share: HubShare(conversations: batch.conversations)) {
                sharing = nil
                withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { selecting = false; selected.removeAll() }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .overlay {
            if engine.archive.conversations.isEmpty {
                ContentUnavailableView { LooplMark().frame(width: 56, height: 56) } description: { Text("Conversations you finish appear here.") }
                    .allowsHitTesting(false)
            }
        }
    }

    private func toggle(_ id: UUID) {
        LooplDesign.haptic()
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func beginSelecting(_ id: UUID) {
        LooplDesign.haptic()
        withAnimation(LooplDesign.Motion.reduced(LooplDesign.Motion.snappy, reduceMotion)) { selecting = true; selected = [id] }
    }

    private func copyTranscript(_ c: SavedConversation) {
        let text = c.items.compactMap { item -> String? in
            switch item {
            case .user(let s, let imgs): (imgs?.isEmpty == false ? "You: [\(imgs!.count) image\(imgs!.count == 1 ? "" : "s")] " : "You: ") + s
            case .assistant(let s): "loopl: \(s)"
            case .tool(let n, _, let r, _, _, _): "[\(n)] \(r ?? "…")"
            case .note: nil
            }
        }.joined(separator: "\n\n")
        copy(text)
    }
}

@MainActor func copy(_ s: String) {
    UIPasteboard.general.string = s
    LooplDesign.haptic()
}
