# f_a2a

A dynamic-library implementation of the **Agent-to-Agent (A2A) protocol**: task model, state machine, server and client,
reusing [`fountain::f_jsonrpc`](../f_jsonrpc) for transport and protocol (JSON-RPC 2.0 over HTTP).

The design baseline lives in [`doc/a2a-protocol.md`](doc/a2a-protocol.md) — method mapping, data model, state machine,
error codes and supported boundaries are all there.

## Scope

| Item | Detail |
|---|---|
| Provides | `A2aAgentCard` / `A2aTask` / `A2aMessage` / `A2aPart` / `A2aArtifact` models; `A2aServer` (method registration + task store); `A2aClient` |
| Does not provide | Transport (use `f_jsonrpc`), routing and auth (use `f_mvc`), LLM calls (implement `A2aExecutor` and wire `f_llm` yourself) |
| Output type | `dynamic` (`cjpm build` produces a shared library) |

## Dependencies

```toml
[dependencies]
  "fountain::f_collection" = {path = "../f_collection"}
  "fountain::f_data" = {path = "../f_data"}
  "fountain::f_jsonrpc" = {path = "../f_jsonrpc"}
  "fountain::f_log" = {path = "../f_log"}
```

## Quick start

Server:

```cangjie
import fountain::f_a2a.*

let card = A2aAgentCard(name: 'daily-report-agent', description: 'Summarise daily commits',
                        url: 'http://127.0.0.1:8080/rpc/a2a', version: '1.0.0')
let server = A2aServer(card, MyExecutor())
server.register()      // registers a2a.message.send / a2a.tasks.get / a2a.tasks.cancel
```

Client:

```cangjie
let client = A2aClient('http://127.0.0.1:8080/rpc/a2a')
let task = client.send(A2aMessage(parts: [A2aPart(text: 'summarise today's commits')]))
println(task.status)   // completed | failed | input-required | canceled
```

## Build

```bash
cd f_a2a
cjpm build
cjpm test
```

## Boundaries

- Synchronous semantics: one `message/send` call runs the executor to a terminal state and returns the task;
  long-running work uses `input-required` plus client-side polling of `tasks/get`;
- No SSE streaming (`message/stream`), no `tasks/resubscribe`, no push notifications, no non-text `Part` — see design doc §7;
- The task store is in-memory by default and lost on restart; implement `A2aTaskStore` for persistence.
