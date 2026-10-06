import Foundation
import Observation
import SwiftUI
import Loopl
import LooplUI

/// Saved conversations — a JSON file per conversation in Application Support.
/// The transcript is what is kept (what you saw), not the model's raw messages.
struct SavedConversation: Codable, Identifiable, Hashable {
    enum Item: Codable, Hashable {
        case user(String), assistant(String), tool(name: String, args: [String: JSONValue], result: String?, isError: Bool, ms: Double), note(String)
    }
    var id: UUID
    var title: String
    var updated: Date
    var modelName: String?
    var items: [Item]

    static func from(_ t: Transcript, id: UUID, modelName: String?) -> SavedConversation? {
        let items: [Item] = t.items.compactMap {
            switch $0.kind {
            case .user(let s): .user(s)
            case .assistant(let s): .assistant(s)
            case .toolUse(let c, let r): .tool(name: c.name, args: c.input, result: r?.content, isError: r?.isError ?? false, ms: r?.durationMs ?? 0)
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
        let first = items.compactMap { if case .user(let s) = $0 { return s }; return nil }.first ?? "Conversation"
        return SavedConversation(id: id, title: String(first.prefix(60)), updated: Date(), modelName: modelName, items: items)
    }

    func transcript() -> Transcript {
        var t = Transcript()
        t.items = items.map {
            switch $0 {
            case .user(let s): return TranscriptItem(kind: .user(s))
            case .assistant(let s): return TranscriptItem(kind: .assistant(s))
            case .tool(let name, let args, let result, let isError, let ms):
                let use = ToolUse(name: name, input: args)
                return TranscriptItem(kind: .toolUse(use, result: result.map { ToolResult(toolUseId: use.toolUseId, name: name, status: isError ? .error : .success, content: $0, durationMs: ms) }))
            case .note(let s): return TranscriptItem(kind: .note(s))
            }
        }
        t.isRunning = false
        return t
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
        conversations = files.compactMap { try? dec.decode(SavedConversation.self, from: Data(contentsOf: $0)) }.sorted { $0.updated > $1.updated }
    }

    func upsert(_ c: SavedConversation) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(c) { try? data.write(to: Self.root.appendingPathComponent("\(c.id.uuidString).json"), options: .atomic) }
        conversations.removeAll { $0.id == c.id }
        conversations.insert(c, at: 0)
    }

    func delete(_ c: SavedConversation) {
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent("\(c.id.uuidString).json"))
        conversations.removeAll { $0.id == c.id }
    }

    func deleteAll() { conversations.forEach(delete) }
}

/// The sidebar (iPad) / sheet (iPhone) list of saved conversations. Swipe left deletes.
struct HistoryList: View {
    @Bindable var engine: Engine
    @Binding var selection: RootView.Pane
    var dismiss: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
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
                            LooplDesign.haptic(); engine.open(c); selection = .chat; dismiss?()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.title).lineLimit(2).foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Text(c.updated, format: .relative(presentation: .named))
                                    if let m = c.modelName { Text("·"); Text(m) }
                                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .listRowBackground(engine.currentId == c.id ? LooplDesign.accent.opacity(0.1) : nil)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { withAnimation(reduceMotion ? nil : LooplDesign.spring) { engine.delete(c) } } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button("Copy transcript", systemImage: "doc.on.doc") { copyTranscript(c) }
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
        .navigationTitle("loopl")
        .overlay {
            if engine.archive.conversations.isEmpty {
                ContentUnavailableView { LooplMark().frame(width: 56, height: 56) } description: { Text("Conversations you finish appear here.") }
                    .allowsHitTesting(false)
            }
        }
    }

    private func copyTranscript(_ c: SavedConversation) {
        let text = c.items.compactMap { item -> String? in
            switch item {
            case .user(let s): "You: \(s)"
            case .assistant(let s): "loopl: \(s)"
            case .tool(let n, _, let r, _, _): "[\(n)] \(r ?? "…")"
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
