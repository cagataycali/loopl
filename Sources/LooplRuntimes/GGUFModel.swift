import Foundation
import Loopl

// llama.cpp runtime. The real implementation (GGUFModel on the ggml-org
// xcframework) lands in the next CORE2 commit behind `#if canImport(llama)`;
// until then the type exists so hosts compile and can ask `availability()`.
#if !canImport(llama)
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
