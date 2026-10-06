import Foundation
import Loopl
#if canImport(FoundationModels)
import FoundationModels
#endif

// A narrow seam over Apple's `LanguageModelSession`.
//
// Why: Apple Intelligence is not available in CI, not in the iOS Simulator and
// not on an ineligible Mac, so the only way to pin the *loop* behaviour of the
// Apple FM runtime (one tool call → one execution → one answer) with a test is
// to be able to script the model's replies. The protocol is deliberately tiny —
// instructions in, cumulative response snapshots out — so the live
// implementation is a 10-line wrapper and nothing about the real framework's
// semantics is re-implemented.

/// One generation: cumulative snapshots of the response text, exactly as
/// `LanguageModelSession.streamResponse(to:)` yields them (each element is the
/// whole response so far, not a delta).
public protocol AppleFMSession: Sendable {
    func snapshots(prompt: String) -> AsyncThrowingStream<String, Error>
}

/// Makes one session per generation (Apple FM sessions are single-shot in loopl:
/// the conversation lives in `Agent.messages`, not in the session's transcript).
public protocol AppleFMSessionFactory: Sendable {
    /// Availability of the backing model, reported as-is to the UI.
    var availability: RuntimeAvailability { get }
    func makeSession(instructions: String?, temperature: Double, maxTokens: Int?) throws -> any AppleFMSession
}

// MARK: - Live (FoundationModels)

/// The real Apple Intelligence model.
public struct LiveAppleFMSessionFactory: AppleFMSessionFactory {
    public init() {}

    public var availability: RuntimeAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ok
            case .unavailable(let reason):
                let why: String
                switch reason {
                case .deviceNotEligible: why = "device not eligible for Apple Intelligence"
                case .appleIntelligenceNotEnabled: why = "Apple Intelligence is off — Settings › Apple Intelligence & Siri"
                case .modelNotReady: why = "model not ready (still downloading / device busy)"
                @unknown default: why = "unavailable: \(String(describing: reason))"
                }
                return RuntimeAvailability(available: false, reason: why)
            @unknown default:
                return RuntimeAvailability(available: false, reason: "unknown availability")
            }
        }
        return RuntimeAvailability(available: false, reason: "needs iOS 26 or later")
        #else
        return RuntimeAvailability(available: false, reason: "FoundationModels framework not in this SDK")
        #endif
    }

    public func makeSession(instructions: String?, temperature: Double, maxTokens: Int?) throws -> any AppleFMSession {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return LiveAppleFMSession(instructions: instructions, temperature: temperature, maxTokens: maxTokens)
        }
        throw ModelError("needs iOS 26")
        #else
        throw ModelError("FoundationModels not available")
        #endif
    }
}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
struct LiveAppleFMSession: AppleFMSession {
    let instructions: String?
    let temperature: Double
    let maxTokens: Int?

    func snapshots(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: (instructions?.isEmpty ?? true) ? nil : instructions!)
                    var options = GenerationOptions()
                    options.temperature = temperature
                    if let maxTokens { options.maximumResponseTokens = maxTokens }
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
