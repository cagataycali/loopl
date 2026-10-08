---
title: "Human in the loop"
description: "Approve, deny or edit a tool call before it runs. The call waits inside the agent; the card is a SwiftUI view."
---

# Human in the loop

A tool can ask before it acts. loopl pauses **that one call** inside the agent, emits an event and resumes when a person answers. Other tools in the same turn keep running.

## Ask

A `Tool` returns an `ApprovalRequest` from `requiresApproval(for:)`. `HttpTool` does for every request, graded by method — GET low, POST · PUT · PATCH medium, DELETE high — with credential headers redacted. `open_app` asks unless the scheme is allow-listed.

`ApprovalPolicy` decides what actually reaches the person: `.mutating` (the app's default) lets reads through and asks for writes, `.always` asks for everything, `.never` never asks. Trusted hosts pass.

## Answer

```swift
// snippet: compile
import Loopl

func run(_ model: any Model) async throws {
    let agent = Agent(model: model, tools: [HttpTool()],
                      hooks: [ApprovalPolicy(mode: .mutating, trustedHosts: ["api.example.com"])],
                      approvalTimeout: 120)
    for try await event in agent.stream("Post today's summary to the notes API.") {
        switch event {
        case .approvalRequested(let request):
            await agent.resolve(approval: request.id, .approve)   // or .deny(reason:), .approveEdited(input)
        case .toolResult(let result) where result.isError:
            print(result.content)                                  // a denial reaches the model as an error
        default: break
        }
    }
}
```

No answer within `approvalTimeout` (120 s) denies; so does cancelling. `agent.pendingApprovals` lists what is waiting. An approval is an [interrupt](agent.md#interrupts) underneath.

## In SwiftUI

`AgentTranscriptView` renders an `ApprovalCard` inline — method, host and path, redacted headers, the body, and **Approve · Deny · Edit**. Route answers with `.onApproval { request, decision in … }`. It springs in with `LooplDesign.Motion` and cross-fades under Reduce Motion.
