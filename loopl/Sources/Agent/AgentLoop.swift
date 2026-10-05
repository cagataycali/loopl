import Foundation

/// Everything the UI needs to show each step of the loop.
public enum AgentEvent: Sendable {
    case iterationStarted(Int)
    case token(String)                       // streamed assistant text (current iteration)
    case stats(StreamStats)
    case assistantMessage(Message)           // final assistant turn of an iteration (text + parsed calls)
    case toolStarted(ToolCall)
    case toolFinished(callId: String, name: String, result: String, durationMs: Double, isError: Bool)
    case finished(iterations: Int, reason: FinishReason)
}

public enum FinishReason: String, Sendable { case answered, maxIterations, cancelled }

public struct AgentConfig: Sendable {
    public var maxIterations = 8
    public var family: ToolFamily = .hermes
    public var params = GenerationParams()
    public init() {}
}

/// The strands algorithm: stream → parse tool calls → run tools → append →
/// recurse until the model answers without a call or we hit the cap.
/// Pure Swift: it only knows `LLMRuntime` and `AgentTool`.
public enum AgentLoop {
    public static func run(
        messages initial: [Message],
        runtime: any LLMRuntime,
        tools: [any AgentTool],
        config: AgentConfig
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var messages = initial
                let parser = ToolCallParser(family: config.family)
                let toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                var iteration = 0
                do {
                    while iteration < config.maxIterations {
                        iteration += 1
                        try Task.checkCancellation()
                        continuation.yield(.iterationStarted(iteration))

                        var text = ""
                        var nativeCalls: [ToolCall] = []
                        for try await token in runtime.stream(messages: messages, tools: tools, params: config.params) {
                            try Task.checkCancellation()
                            switch token {
                            case .text(let t): text += t; continuation.yield(.token(t))
                            case .toolCall(let c): nativeCalls.append(c)
                            case .stats(let s): continuation.yield(.stats(s))
                            }
                        }

                        let parsed = parser.parse(text)
                        let calls = nativeCalls + parsed.calls
                        let assistant = Message.assistant(text: parsed.text, toolCalls: calls)
                        messages.append(assistant)
                        continuation.yield(.assistantMessage(assistant))

                        if calls.isEmpty {
                            continuation.yield(.finished(iterations: iteration, reason: .answered))
                            continuation.finish()
                            return
                        }

                        for call in calls {
                            try Task.checkCancellation()
                            continuation.yield(.toolStarted(call))
                            let started = Date()
                            var result: String
                            var isError = false
                            if let tool = toolsByName[call.name] {
                                do { result = try await tool.call(call.arguments) }
                                catch { result = "error: \(error.localizedDescription)"; isError = true }
                            } else {
                                result = "error: unknown tool '\(call.name)'. Available: \(toolsByName.keys.sorted().joined(separator: ", "))"
                                isError = true
                            }
                            let ms = Date().timeIntervalSince(started) * 1000
                            messages.append(.tool(result: result, callId: call.id, name: call.name))
                            continuation.yield(.toolFinished(callId: call.id, name: call.name, result: result, durationMs: ms, isError: isError))
                        }
                    }
                    continuation.yield(.finished(iterations: iteration, reason: .maxIterations))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finished(iterations: iteration, reason: .cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
