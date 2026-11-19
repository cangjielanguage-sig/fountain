# f_a2a

A dynamic-library implementation of the **Agent-to-Agent (A2A) protocol**: task model, state machine, server and client.
Transport and protocol are fully delegated to [`fountain::f_jsonrpc`](../f_jsonrpc)
(JSON-RPC 2.0 over HTTP; streaming via SSE). **`f_mvc` needs no changes.**

Design baseline: [`doc/a2a-protocol.md`](doc/a2a-protocol.md).

## Scope

| Item | Detail |
|---|---|
| Provides | Models (`A2aTask` / `A2aMessage` / `A2aPart` / `A2aArtifact` / `A2aAgentCard`), `A2aServer`, `A2aClient`, `A2aTaskStore`, `A2aExecutor`, `A2aPushConfigStore` |
| Does not provide | Transport/routing (use `f_jsonrpc` / `f_mvc`), LLM calls (implement `A2aExecutor` and wire `f_llm` yourself) |
| Output type | `dynamic` (`cjpm build` produces a shared library) |

## Dependencies

```toml
[dependencies]
  "fountain::f_collection" = {path = "../f_collection"}
  "fountain::f_data" = {path = "../f_data"}
  "fountain::f_httpclient" = {path = "../f_httpclient"}
  "fountain::f_jsonrpc" = {path = "../f_jsonrpc"}
  "fountain::f_log" = {path = "../f_log"}
```

## Registered JSON-RPC methods (9)

| Method | Purpose |
|---|---|
| `a2a.message.send` | Create a task, execute synchronously, return the terminal task |
| `a2a.message.stream` | Same, plus `a2a.task.status` / `a2a.task.artifact` events over SSE |
| `a2a.tasks.get` | Fetch a task by `id`; `-32020` when missing |
| `a2a.tasks.cancel` | Only `submitted` / `working`; terminal tasks return `-32021` |
| `a2a.tasks.resubscribe` | Re-subscribe: returns the task and replays one status event |
| `a2a.agent.extendedCard` | Base card plus `x-a2a-extensions` (omitted when unset) |
| `a2a.pushConfig.set` / `get` / `delete` | task → callback URL registry |

Error codes: `-32020` task not found, `-32021` not cancelable, `-32023` unsupported part, `-32024` rejected —
all inside the `-32020 ~ -32099` business range.

## Server

```cangjie
import fountain::f_a2a.*

class MyExecutor <: A2aExecutor {
    public func execute(task: A2aTask, message: A2aMessage): A2aExecutionResult {
        A2aExecutionResult.done('done: ${message.text()}')
    }
}

let card = A2aAgentCard(name: 'daily-report-agent', description: 'Summarise daily commits',
                        url: 'http://127.0.0.1:8080/rpc/a2a')
let server = A2aServer(card, MyExecutor())
server.register()          // idempotent: repeated calls register nothing new
```

Call it (through `f_jsonrpc`'s `/rpc` endpoint, method in the body):

```bash
curl -s http://127.0.0.1:8080/rpc -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"a2a.message.send",
       "params":{"message":{"role":"user","messageId":"m1",
                 "parts":[{"kind":"text","text":"summarise today's commits"}]}}}'
```

### Streaming

```bash
curl -N 'http://127.0.0.1:8080/rpc/stream?topic=a2a&taskId=task-1' \
     -H 'Accept: text/event-stream'
```

```
id: 1
event: message
data: {"jsonrpc":"2.0","method":"a2a.task.status","params":{"taskId":"task-1","status":"working"}}
```

Create the task with `a2a.message.stream`, then subscribe with the returned `id`; reconnect with `Last-Event-ID`
to replay missed events.

### Push notifications

`a2a.pushConfig.set` with `{"taskId":"task-1","url":"https://hook/a2a","token":"tk-1"}`.
When the task reaches a terminal state the server POSTs one JSON-RPC notification carrying `token`;
failures only produce a warn and never change the task state.

### Extended card

```cangjie
@Controller
public class CardController {
    @GetMapping[path: '/.well-known/agent.json']
    public func card(): String {
        A2aAgentCard(name: 'daily-report-agent', url: 'http://127.0.0.1:8080/rpc/a2a').json()
    }
}
```

`f_a2a` does not register this route itself — it belongs to the host application; the module only serialises the card.

## Client

```cangjie
let client = A2aClient('http://127.0.0.1:8080/rpc')
let task = client.send(A2aMessage(parts: [A2aPart(text: 'summarise today's commits')]))
println(task.status)        // completed | failed | input-required | canceled
let again = client.get(task.id)
let _ = client.cancel(task.id)
client.close()
```

Protocol errors (for example `-32020`) are re-thrown unchanged — never rewritten, never swallowed.

## Model notes

- `A2aPart.kind`: `text` / `file` (`url` + `mimeType`, no inline bytes) / `data` (small JSON string);
  unknown kinds return `-32023`;
- State machine: `submitted → working → completed | failed | canceled`; **`input-required` is not terminal** —
  send again with the same `contextId` to continue;
- The default task store is in-memory (`Mutex`, reads return **copies**) and lost on restart;
  implement `A2aTaskStore` for persistence.

## Build

```bash
cd f_a2a
cjpm build
cjpm test        # 32/32
```

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `A2aCapabilities` (class), `A2aError` (class), `A2aEvents` (class), `A2aExecutionResult` (class), `A2aJson` (class), `A2aSkill` (class), `A2aStates` (class), `InMemoryA2aTaskStore` (class)
- `A2aAgentCard`: `var capabilities: A2aCapabilities = A2aCapabilities()`, `var skills: ArrayList<A2aSkill> = ArrayList<A2aSkill>()`, `var version: String =`
- `A2aArtifact`: `var artifactId: String =`, `textOf` (func)
- `A2aCapabilities`: `var pushNotifications: Bool = false`, `var streaming: Bool = true`
- `A2aError`: `static let CONTENT_TYPE_UNSUPPORTED: Int64 = -32023`, `static let TASK_NOT_CANCELABLE: Int64 = -32021`, `static let TASK_NOT_FOUND: Int64 = -32020`, `static let TASK_REJECTED: Int64 = -32024`, `static let UNSUPPORTED: Int64 = -32022`
- `A2aEvents`: `static let METHOD_ARTIFACT =`, `METHOD_STATUS` (let), `TOPIC` (let), `notify` (func), `publish` (func), `pushBody` (func), `statusParams` (func)
- `A2aExecutionResult`: `let needsInput: Bool`, `reject` (func), `let rejected: Bool`
- `A2aJson`: `arrayOf` (func), `artifactOf` (func), `artifactsOf` (func), `copyOf` (func), `intOf` (func), `messageOf` (func), `messagesOf` (func), `partOf` (func), `partsOf` (func), `strOf` (func), `taskOf` (func)
- `A2aMessage`: `var messageId: String =`, `var role: String =`
- `A2aPart`: `isSupported` (func)
- `A2aServer`: `static let METHOD_CANCEL =`, `static let METHOD_CARD =`, `METHOD_COUNT` (let), `static let METHOD_GET =`, `static let METHOD_PUSH_DELETE =`, `static let METHOD_PUSH_GET =`, `static let METHOD_PUSH_SET =`, `static let METHOD_RESUBSCRIBE =`, `METHOD_SEND` (let), `static let METHOD_STREAM =`, `cancelTask` (func), `getTask` (func), `pushDelete` (func), `pushGet` (func), `pushSet` (func), `registrationCount` (func)
- `A2aSkill`: `var tags: ArrayList<String> = ArrayList<String>()`
- `A2aStates`: `static let CANCELED =`, `static let COMPLETED =`, `static let FAILED =`, `static let INPUT_REQUIRED =`, `static let SUBMITTED =`, `static let WORKING =`, `isTerminal` (func), `isValid` (func)
- `A2aTask`: `var artifacts: ArrayList<A2aArtifact> = ArrayList<A2aArtifact>()`, `var createdAt: Int64 = 0`, `var history: ArrayList<A2aMessage> = ArrayList<A2aMessage>()`, `isTerminal` (func), `var statusMessage: ?A2aMessage = None`, `var updatedAt: Int64 = 0`
- `InMemoryA2aTaskStore`: `count` (func), `list` (func), `save` (func)
