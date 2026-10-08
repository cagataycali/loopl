import Foundation
import Loopl

#if canImport(llama)
import llama

/// llama.cpp runtime (official ggml-org xcframework, vendored by
/// `scripts/fetch-llama-xcframework.sh`). Loads ONE .gguf file, Metal
/// offload on device, decodes token by token into `StreamEvent`s.
/// Tool calls: specs are rendered into the system prompt with the family's
/// manual dialect (llama_chat_apply_template has no `tools` argument) and
/// the model's markup is resolved by `ToolCallStreamGate`, exactly like the
/// MLX runtime. One generation at a time; a second caller gets
/// `ModelThrottledError` (retryable) instead of a crash.
public actor GGUFModel: Model {
    public nonisolated let kind: RuntimeKind = .gguf
    public private(set) var loadedModelId: String?
    public private(set) var params = GenerationParams()

    /// Raw llama pointers, boxed so Swift 6 lets them cross to the decode queue and the deinit.
    private final class Handles: @unchecked Sendable {
        var model: OpaquePointer?; var ctx: OpaquePointer?
        init(model: OpaquePointer?, ctx: OpaquePointer?) { self.model = model; self.ctx = ctx }
    }
    private var handles = Handles(model: nil, ctx: nil)
    private var model: OpaquePointer? { get { handles.model } set { handles.model = newValue } }
    private var ctx: OpaquePointer? { get { handles.ctx } set { handles.ctx = newValue } }
    private var spec: ModelSpec?
    private var chatTemplate: String?
    private var busy = false
    /// All llama.cpp calls happen here, off the cooperative pool (decode blocks for seconds).
    private static let queue = DispatchQueue(label: "loopl.gguf", qos: .userInitiated)
    private static let backend: Void = {
        llama_backend_init()
        llama_log_set({ level, text, _ in
            #if DEBUG
            if level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text { fputs("[llama] " + String(cString: text), stderr) }
            #endif
        }, nil)
    }()

    public init() {}

    public nonisolated static func availability() -> RuntimeAvailability {
        #if targetEnvironment(simulator)
        return RuntimeAvailability(available: true, reason: "simulator: CPU only (no Metal offload); numbers are not device numbers")
        #else
        return .ok
        #endif
    }

    public func updateConfig(_ params: GenerationParams) {
        let needsNewContext = ctx != nil && params.contextLength != self.params.contextLength
        self.params = params
        if needsNewContext, let model { ctx.map { llama_free($0) }; ctx = Self.makeContext(model, params) }
    }

    // MARK: load / unload

    public func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        guard let directory else { throw ModelError("\(spec.name) is not downloaded") }
        let file: URL
        if let name = spec.file { file = directory.appendingPathComponent(name) }
        else if let any = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "gguf" }) { file = any }
        else { throw ModelError("no .gguf file in \(directory.lastPathComponent)") }
        guard FileManager.default.fileExists(atPath: file.path) else { throw ModelError("\(file.lastPathComponent) is missing") }
        await unload()
        _ = Self.backend
        let p = spec.defaultParams
        let path = file.path
        let loaded: (OpaquePointer, OpaquePointer, String?) = try await withCheckedThrowingContinuation { cont in
            Self.queue.async {
                var mp = llama_model_default_params()
                #if targetEnvironment(simulator)
                mp.n_gpu_layers = 0
                #else
                mp.n_gpu_layers = 99
                #endif
                let box = ProgressBox(progress)
                mp.progress_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
                mp.progress_callback = { value, user in
                    guard let user else { return true }
                    Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue().report(Double(value))
                    return true
                }
                guard let m = llama_model_load_from_file(path, mp) else {
                    cont.resume(throwing: ModelError("llama.cpp could not load \(file.lastPathComponent)")); return
                }
                withExtendedLifetime(box) {}
                guard let c = Self.makeContext(m, p) else {
                    llama_model_free(m)
                    cont.resume(throwing: ModelError("llama.cpp could not create a context (n_ctx \(p.contextLength)) — not enough memory?")); return
                }
                let tmpl = llama_model_chat_template(m, nil).map { String(cString: $0) }
                cont.resume(returning: (m, c, tmpl))
            }
        }
        model = loaded.0; ctx = loaded.1; chatTemplate = loaded.2
        self.spec = spec
        params = p
        loadedModelId = spec.id
        progress(1)
    }

    private static func makeContext(_ model: OpaquePointer, _ p: GenerationParams) -> OpaquePointer? {
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(max(512, p.contextLength))
        cp.n_batch = 512
        cp.n_ubatch = 512
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        let cores = ProcessInfo.processInfo.activeProcessorCount
        cp.n_threads = Int32(max(1, min(6, cores - 2)))
        cp.n_threads_batch = cp.n_threads
        return llama_init_from_model(model, cp)
    }

    public func unload() async {
        let (m, c) = (model, ctx)
        model = nil; ctx = nil; spec = nil; chatTemplate = nil; loadedModelId = nil
        guard m != nil || c != nil else { return }
        await withCheckedContinuation { cont in
            Self.queue.async { c.map { llama_free($0) }; m.map { llama_model_free($0) }; cont.resume() }
        }
    }

    deinit {
        let h = handles
        if h.model != nil || h.ctx != nil { Self.queue.async { h.ctx.map { llama_free($0) }; h.model.map { llama_model_free($0) } } }
    }

    // MARK: stream

    private struct Snapshot: @unchecked Sendable { let model: OpaquePointer; let ctx: OpaquePointer; let spec: ModelSpec; let params: GenerationParams; let template: String? }

    private func begin() throws -> Snapshot {
        guard let model, let ctx, let spec else { throw ModelError("no model loaded") }
        guard !busy else { throw ModelThrottledError("llama.cpp context is busy with another generation") }
        busy = true
        return Snapshot(model: model, ctx: ctx, spec: spec, params: params, template: chatTemplate)
    }
    private func end() { busy = false }

    public nonisolated func stream(_ messages: [Loopl.Message], toolSpecs: [Loopl.ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let cancel = CancelFlag()
            let task = Task {
                do {
                    let snap = try await self.begin()
                    defer { Task { await self.end() } }
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        Self.queue.async {
                            do {
                                try Self.generate(snap, messages: messages, toolSpecs: toolSpecs, systemPrompt: systemPrompt, cancel: cancel, emit: { continuation.yield($0) })
                                cont.resume()
                            } catch { cont.resume(throwing: error) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in cancel.set(); task.cancel() }
        }
    }

    /// The decode loop. Runs on `queue`; `emit` is thread-safe (AsyncThrowingStream continuation).
    private static func generate(_ s: Snapshot, messages: [Loopl.Message], toolSpecs: [Loopl.ToolSpec], systemPrompt: String?,
                                 cancel: CancelFlag, emit: (StreamEvent) -> Void) throws {
        let started = Date()
        let vocab = llama_model_get_vocab(s.model)
        let nCtx = Int(llama_n_ctx(s.ctx))

        // 1. Prompt text: model template via llama_chat_apply_template (tools folded into the system prompt), else ChatML.
        let prompt = renderPrompt(template: s.template, systemPrompt: systemPrompt, messages: messages, toolSpecs: toolSpecs, family: s.spec.family,
                                  kwargs: s.spec.chatTemplateKwargs)

        // 2. Tokenize.
        var tokens = tokenize(vocab, prompt)
        if tokens.count >= nCtx - 4 {
            throw ContextWindowOverflowError("prompt is \(tokens.count) tokens; context window is \(nCtx)")
        }
        var stats = Metrics()
        stats.contextMax = nCtx
        stats.promptTokens = tokens.count
        stats.contextUsed = tokens.count
        emit(.metadata(stats))

        // 3. Fresh KV + prefill in n_batch slices.
        llama_memory_clear(llama_get_memory(s.ctx), true)
        let nBatch = Int(llama_n_batch(s.ctx))
        var offset = 0
        while offset < tokens.count {
            if cancel.isSet { return }
            let n = min(nBatch, tokens.count - offset)
            let rc = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(s.ctx, llama_batch_get_one(buf.baseAddress! + offset, Int32(n)))
            }
            if rc != 0 { throw rc == 1 ? ContextWindowOverflowError("llama_decode: no KV slot for a \(tokens.count)-token prompt") : ModelError("llama_decode failed (\(rc)) during prefill") }
            offset += n
        }

        // 4. Sampler chain: top_p → min_p → temperature → dist (greedy when temperature ≤ 0).
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(chain) }
        if s.params.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            if s.params.topP < 1 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.params.topP, 1)) }
            if s.params.minP > 0 { llama_sampler_chain_add(chain, llama_sampler_init_min_p(s.params.minP, 1)) }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(s.params.temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32(truncatingIfNeeded: s.params.seed ?? UInt64.random(in: 0...UInt64(UInt32.max)))))
        }

        // 5. Decode loop.
        var gate = ToolCallStreamGate(family: s.spec.family)
        var utf8 = UTF8Accumulator()
        var nPast = tokens.count
        var generated = 0
        var first: Date?
        var stopReason: StopReason = .endTurn
        let budget = s.params.maxTokens ?? Int.max
        var piece = [CChar](repeating: 0, count: 512)
        while true {
            if cancel.isSet { return }
            let token = llama_sampler_sample(chain, s.ctx, -1)
            if llama_vocab_is_eog(vocab, token) { stopReason = .endTurn; break }
            generated += 1
            if first == nil { first = Date(); stats.ttftMs = first!.timeIntervalSince(started) * 1000 }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 {
                let text = utf8.append(piece[0..<Int(n)].map { UInt8(bitPattern: $0) })
                if !text.isEmpty { for ev in gate.feed(text) { emit(ev) } }
            }
            stats.generatedTokens = generated
            stats.contextUsed = nPast + 1
            if let f = first { let dt = Date().timeIntervalSince(f); if dt > 0.05 { stats.tokensPerSecond = Double(generated - 1) / dt } }
            emit(.metadata(stats))
            nPast += 1
            if nPast >= nCtx - 1 { stopReason = .maxTokens; break }     // context full
            if generated >= budget { stopReason = .maxTokens; break }
            var next = token
            let rc = llama_decode(s.ctx, llama_batch_get_one(&next, 1))
            if rc != 0 { stopReason = .maxTokens; break }
        }
        if let tail = utf8.flush(), !tail.isEmpty { for ev in gate.feed(tail) { emit(ev) } }
        if let f = first, generated > 1 { stats.tokensPerSecond = Double(generated - 1) / max(0.001, Date().timeIntervalSince(f)) }
        stats.finished = true
        stats.stopReason = stopReason.rawValue
        emit(.metadata(stats))
        for ev in gate.finish(stopReason: stopReason) { emit(ev) }
    }

    // MARK: prompt

    static func applyTemplate(_ template: String, _ chat: [(String, String)]) -> String? {
        let roles = chat.map { strdup($0.0)! }, contents = chat.map { strdup($0.1)! }
        defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
        var msgs = zip(roles, contents).map { llama_chat_message(role: UnsafePointer($0.0), content: UnsafePointer($0.1)) }
        let hint = chat.reduce(0) { $0 + $1.1.utf8.count } * 2 + 1024
        var buf = [CChar](repeating: 0, count: hint)
        var n = llama_chat_apply_template(template, &msgs, msgs.count, true, &buf, Int32(buf.count))
        if n > Int32(buf.count) { buf = [CChar](repeating: 0, count: Int(n) + 1); n = llama_chat_apply_template(template, &msgs, msgs.count, true, &buf, Int32(buf.count)) }
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func tokenize(_ vocab: OpaquePointer?, _ text: String) -> [llama_token] {
        let addBOS = llama_vocab_get_add_bos(vocab)
        let utf8 = Array(text.utf8)
        var n = utf8.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { llama_tokenize(vocab, $0, Int32(p.count), nil, 0, addBOS, true) }
        }
        if n < 0 { n = -n }
        var out = [llama_token](repeating: 0, count: Int(n))
        let got = utf8.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { llama_tokenize(vocab, $0, Int32(p.count), &out, Int32(out.count), addBOS, true) }
        }
        return Array(out.prefix(Int(max(0, got))))
    }
}


final class CancelFlag: @unchecked Sendable {
    private var flag = false; private let lock = NSLock()
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

final class ProgressBox: @unchecked Sendable {
    let cb: @Sendable (Double) -> Void
    private var last: Double = -1
    init(_ cb: @Sendable @escaping (Double) -> Void) { self.cb = cb }
    func report(_ v: Double) { if v - last >= 0.02 || v >= 1 { last = v; cb(min(0.98, v)) } }
}

#else
/// llama.cpp is not linked in this build (Vendor/llama.xcframework absent — run
/// scripts/fetch-llama-xcframework.sh). The type exists so hosts compile and can ask `availability()`.
public actor GGUFModel: Model {
    public nonisolated let kind: RuntimeKind = .gguf
    public private(set) var loadedModelId: String?
    public private(set) var params = GenerationParams()
    public init() {}
    public func updateConfig(_ params: GenerationParams) { self.params = params }
    public nonisolated static func availability() -> RuntimeAvailability {
        RuntimeAvailability(available: false, reason: "llama.cpp is not linked in this build (run scripts/fetch-llama-xcframework.sh).")
    }
    public func load(_ spec: ModelSpec, from directory: URL?, progress: @Sendable @escaping (Double) -> Void) async throws {
        throw ModelError(Self.availability().reason)
    }
    public func unload() async {}
    public nonisolated func stream(_ messages: [Loopl.Message], toolSpecs: [Loopl.ToolSpec], systemPrompt: String?) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ModelError(Self.availability().reason)) }
    }
}
#endif
