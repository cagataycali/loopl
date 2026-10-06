# ``Loopl``

Agents that run on the iPhone. Stream a model, run its tools, repeat until it answers.

## Overview

`Loopl` is the agent loop and nothing else — Foundation only, no network of its own. Give an ``Agent`` a ``Model`` and some ``Tool``s; it streams the answer, runs the calls the model makes, hands the results back, and stops when the model does.

A failed call is a result: the model reads `ERROR: …` and decides. Writes can wait for a person (``ApprovalPolicy``). Every run can be traced (``Tracer``), checkpointed and resumed.

Guides live at [loopl.dev](https://loopl.dev). Engines are in `LooplRuntimes`.

## Topics

### The loop

- ``Agent``
- ``AgentResult``
- ``Model``
- ``StreamEvent``

### Tools

- ``Tool``
- ``ClosureTool``
- ``ToolSchema``
- ``ToolError``
- ``ToolResult``
- ``ToolCallParser``
- ``ToolValidation``

### People in the loop

- ``ApprovalPolicy``
- ``ApprovalRequest``
- ``Interrupt``

### Hooks, tracing, checkpoints

- ``HookProvider``
- ``HookRegistry``
- ``Tracer``
- ``Span``

### Models and the Hub

- ``ModelSpec``
- ``Catalog``
- ``HubCatalog``
- ``HFDownloader``
- ``HFAccount``
- ``HFHubClient``
- ``TokenizerFiles``
- ``LocalModelFiles``

### Storage, export, training

- ``ExternalStorage``
- ``ModelLocation``
- ``ConversationExport``
- ``TrainingPlan``
- ``TrainingSession``
