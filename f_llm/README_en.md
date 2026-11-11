# f_llm

A large-model engineering library for Cangjie, part of the [fountain](../) repository. Six capabilities:

| Capability | Entry point |
|---|---|
| Model access (multi-provider, candidates, circuit breaking, streaming) | `fountain::f_llm.llm.LLM` |
| Storage (content / metadata / evolution families) | `fountain::f_llm.store.Stores` |
| Memory, knowledge, skills, personas, prompts | `MemoryStore` / `KnowledgeStore` / `MetaStore` |
| loom orchestration (text → flow → execution) | `fountain::f_llm.loom.LoomWiring` |
| Flow routing (a description → the flow that handles it) | `fountain::f_llm.loom.Supervisor` |
| Third-party channels (email send/receive, IM-ready) | `fountain::f_llm.channel.ChannelMediator` |
| Skill evolution (experience → skill, with A/B gate) | `fountain::f_llm.loom.SkillEvolutionJob` |
| Retrieval quality evaluation | `fountain::f_llm.loom.RetrievalEvalRunner` |

- Version: `1.3.18`, `output-type = "dynamic"`
- Dependencies: `f_base` / `f_bean` / `f_config` / `f_data` / `f_egraph` / `f_jit` / `f_orm` / `f_store` / `f_hydra` / `f_mcp` / `f_ticktock` / `f_util`, all modules in the same repository

---

## Layout

```
src/
├── llm/            model access: LLM facade, LLMConf loading, dialects, pruners, streaming, token counting
├── llm/openai/     OpenAI-compatible request/response mapping
├── embedding/      BGE-M3 embeddings: Embedding facade, HTTP transports, three-way encoding
├── store/          store contracts and implementations (f_store / f_hydra / fhydra / postgres / mysql / inMemory)
├── dao/            SQL statements (postgres / mysql)
├── loom/           flow orchestration, Supervisor routing, store gateway, skill evolution, retrieval evaluation
├── memory/         memory summaries and extraction (FaithfulMemory / ExperienceExtractor / IndividualityExtractor)
├── search/         web search providers
├── tool/           function-calling framework and built-in tools
├── finder/         query facades (skills, knowledge, memory, organization, events, token usage)
├── model/          data models (LLMConf, Skill, Knowledge, Agent, MemorySummary, TokenUsage…)
├── agents/         agent events and event data
├── balance/        provider balance queries and signing
├── service/        LLM conf sources (static / file / env / database / meta store)
├── config/         environment keys and defaults
├── constant/       constants (model names, roles, pruner names, todo status, knowledge kinds…)
├── wiring/         startup wiring (StoreWiring)
├── exception/      exception types
├── util/           Redactor (sensitive-data masking)
├── mcp/            MCP client
└── macros/         annotation macro entry
```

---

## Quick start

### 1. Configuration (environment variables, read once at startup)

```bash
export llm_memoryStore=f_hydra                      # content family (default)
export llm_metaStore=f_store                        # metadata family (default)
export llm_metaStorePath=./data/f_llm-meta          # f_store directory
export llm_embeddingUrl=http://127.0.0.1:8000/v1/embeddings
```

**Configuration is read only once at startup**; runtime changes are not supported (see `doc/known-limitations.md`).

### 2. Wire storage

```cangjie
import fountain::f_llm.wiring.StoreWiring

main(): Int64 {
    // Registers implementations, validates configuration, creates tables, seeds memory kinds
    StoreWiring.wire()
    0
}
```

### 3. Call a model

```cangjie
import std.collection.ArrayList

import fountain::f_llm.llm.*

main(): Int64 {
    let messages = ArrayList<ChatMessage>()
    messages.add(UserMessage(content: 'Explain circuit breaking in one sentence'))
    let resp = LLM.chatByName('deepseek-flash',
                              LLMParams(model: 'deepseek-flash', messages: messages))
    println(resp.messages[0].content)
    0
}
```

| Method | Behaviour |
|---|---|
| `chat(candidates, params, hooks?)` | Try candidates in order, failover + circuit breaking |
| `chatByName(llmName, params)` | Resolve candidates from the configuration snapshot |
| `respond` / `respondByName` | Responses-style API |
| `chatStream` / `respondStream` | Streaming with per-chunk callbacks |
| `setTransport` / `setStreamTransport` | Replace the transport (test injection) |

### 4. Orchestrate

```cangjie
import fountain::f_llm.loom.*

let service = LoomWiring.wire(plannerModel: 'deepseek-flash')
let preview = service.execute(LoomRequest(
    name: 'daily-report',
    description: 'Summarise yesterday commits and issues into a daily report'))
```

See "loom orchestration" below.

---

## API cheat sheet

Find the entry point by task; details live in the section named on the right.

| Task | Entry point | Section |
|---|---|---|
| One model call | `LLM.chatByName(llmName, LLMParams(model:, messages:))` | Model access |
| Streaming | `LLM.chatStream(candidates, params, onDelta)` | Model access |
| Failover across providers | `LLM.chat(candidates, params)` + `LLMConfs` | Model access |
| Embed text | `Embedding.embed(llmName, EmbeddingParam(agentId: 0, session: '', input: '…'))` | Storage · Embeddings |
| Write / query memories | `Stores.content().memory` → `add` / `get` / `list` / `search` | Storage · Contracts |
| Write / query knowledge | `Stores.content().knowledge` → `upsert` / `get` / `search` / `docIds` | Storage · Contracts |
| Skills / prompts / personas | `Stores.meta().skills` / `.prompts` / `.characters` | Storage · Contracts |
| Add a tool | `@Bean` + `FunctionCalling<T>`, picked up by `FunctionMediator` | Model access · Tool calling |
| Plan and run a flow from one sentence | `LoomWiring.wire(...)` → `execute` → `confirmFlow` → `executeNow` | loom orchestration |
| Run a hand-written DAG | `LoomRunner().run(plan, host, start)` | loom · Hand-written flows |
| Route a description to the best flow | `Supervisor.current().getOrThrow().dispatch(text)` | loom · Flow routing |
| Send mail / IM message | `ChannelMediator.send(platform, account, msg)` or the `channelSend` tool | loom · Third-party channels |
| Evaluate retrieval quality | `RetrievalEvalRunner.run(...)` | Retrieval evaluation |
| Debug: is skill search really using vectors | `SkillCatalog.embedFailureDetail()` | loom · Skill injection |
| Debug: did startup restore flows | `LoomBootstrap.startup(registry).restoreFailed` | loom · Flow routing |

Three shortest working snippets (full examples in their sections):

```cangjie
// 1) call a model
let resp = LLM.chatByName('deepseek-flash',
    LLMParams(model: 'deepseek-flash', messages: messages))

// 2) embed (endpoint defaults to http://127.0.0.1:8000/v1/embeddings)
let vectors = Embedding.embed('bge-m3', EmbeddingParam(agentId: 0, session: '', input: 'text to embed'))

// 3) hand a description to the right flow: routing + execution in one call
let outcome = Supervisor.current().getOrThrow().dispatch('summarise today's commits')
```

---

## Model access

### Configuration loading

| Component | Purpose |
|---|---|
| `LLMConf` | One provider config: provider, url, auth, actual model name, capability flags |
| `LLMConfs` | Candidate set: weighted pick, failover, circuit state |
| `LLMConfService` | Refresh / distribution / persistence of configs |
| `LLMConfSource` | `StaticConfSource` / `FileConfSource` / `EnvConfSource` / `DatabaseConfSource` / `StoreMetaConfSource` |
| `LLMCandidateProvider` | Candidate provider (by name or weight) |
| `CircuitBreaker` | Failure counting and cooldown window |

The source is chosen by `llm_confSource`; `llm_confs` can inline a set of configs for static deployments.

### Provider dialects

`ProviderDialect` turns the unified request body into each provider's format:

| Dialect | Applies to |
|---|---|
| `StandardDialect` | OpenAI-compatible endpoints (most aggregators) |
| `DeepSeekDialect` | DeepSeek-specific fields |
| `ZhipuDialect` / `VolcengineDialect` / `AliyunDialect` / `SiliconFlowDialect` | Provider-specific parameters |

`DialectRegistry` picks the dialect by provider. Model name normalisation (`ModelNames.normalize`) is only used for capability checks and logs — the outgoing `model` field always carries the configured text.

### Context pruning

`ContextPrunerMediator` selects a pruner by name; `llm_prunerLlmName` sets the model used by model-dependent pruners.

| Name | Implementation | Behaviour |
|---|---|---|
| `Retain` | `RetainContextPruner` | Keep everything |
| `LastN` | `LastNContextPruner` | Keep the most recent N messages |
| `RetainLastUser` | `RetainLastUserPruner` | Keep the last user message |
| `RetainLastRound` | `RetainLastNRoundPruner` | Keep the most recent N rounds |
| `TokenBudget` | `TokenBudgetContextPruner` | Prune to a token budget |
| `Saturation` | `SaturationContextPruner` | Saturation-based pruning |
| `DRC` | `DRCContextPruner` | Dynamic relevance pruning |
| `Summary` / `Keywords` | model-dependent | Summary / keyword compression |

Pruning runs through `ContextPrunerMediator.prune(...)`; every strategy keeps the leading system message (see `doc/f_llm-memory-design.md` §6.5 for where persona and skills are injected).

### Tool calling

| Component | Purpose |
|---|---|
| `FunctionDefinition` | Function signature (name, description, parameter schema) |
| `FunctionCalling<T>` / `CommonFunctionCalling` | Single-function wrapper |
| `WrappedFunctionCalling<T>` | Wrap an existing function |
| `FunctionMediator` | Registry and call entry (`FunctionMediator.call(name, args)`) |
| `LLMToolLoop` | Multi-round "model asks for a tool → execute → feed back" loop |

Built-in tools (`ToolName` holds the constants):

| Tool | Purpose |
|---|---|
| `FileReadingFunction` / `FileWritingFunction` / `FileReplacngFunction` | File read/write/replace, bounded by `llm_fileSandboxPath` |
| `CommandFunction` | Run shell commands |
| `ConsoleFunction` | Console read/write |
| `WebSearchFunction` / `WebFetchFunction` | Web search and fetch (with `SsrfGuard`) |
| `SkillLoadingFunction` / `SkillReferenceLoadingFunction` | Load skills and skill references |
| `MemoriesLoadingFunction` | Load experience, lessons and user individuality |
| `TodoFunction` | Todo CRUD |
| `CurrentTimeFunction` | Current time |
| `AnswerFunction` | Structured answers |

---

## Storage

### Three families

| Family | Stores | Implementations | Config key |
|---|---|---|---|
| Content | memories, experience, knowledge, documents | `f_hydra` (default) / `fhydra` / `postgres` / `mysql` / `inMemory` | `llm_memoryStore` |
| Metadata | characters, skills, prompts, model configs | `postgres` / `mysql` / `f_store` (default) | `llm_metaStore` |
| Evolution | reports, state, consumed knowledge, daily lease | reports/state follow the metadata family; the lease follows the content family | same keys |

- An unknown value **fails startup** with the list of available implementations; there is no silent fallback.
- Custom implementations register with `Stores.registerContent(name, factory)` / `Stores.registerMeta(name, factory)`.
- `Stores.content()` / `Stores.meta()` return the configured implementation.

### Contracts

| Contract | Purpose |
|---|---|
| `ContentStore` | Content-family container: `prop memory: MemoryStore` + `prop knowledge: KnowledgeStore` |
| `MetaStore` | Metadata-family container: `characters` / `skills` / `prompts` / `confs` |
| `MemoryStore` | Memory and experience: `add / get / remove / list / search / listByKind` |
| `KnowledgeStore` | Knowledge and chunks: `upsert / get / remove / search / docIds` |
| `CharacterStore` | One persona per user: `get / set / reset` |
| `SkillStore` | Skills: `upsert / get / list / remove` |
| `PromptStore` | Prompts: `put / get(name,version) / latest / remove` |
| `LLMConfStore` | Model configs: `names / candidates / put` |

Models (`store/StoreModels.cj`):

| Type | Key fields |
|---|---|
| `MemoryRecord` | `id / userId / namespace / title / content / kind / saveTime` |
| `MemoryHit` | `record / score` (returned by `search`, includes content) |
| `KnowledgeDoc` | `docId / title / content` |
| `Character` | `userId / characterKey / prompts` |
| `Skill` | `id / title / details / functions / version` |
| `PromptEntry` | `name / version / content` |
| `EvolutionEntry` | `id / skillTitle / action / detail / at` |

### On-disk layout

**f_store** (no database):

```
f_llm:meta:character:{userId}                        → persona (key + prompts)
f_llm:meta:skill:{id}                                → skill
f_llm:meta:prompt:{name}:{version}                   → prompt
f_llm:evolution:data:{id}                            → evolution report
f_llm:evolution:idx:{titleLen}:{title}:{padAt}:{padId} → report index (bySkill)
f_llm:evolution:time:{padAt}:{padId}                  → report index (list)
f_llm:evo-state:run                                 → evolution watermark
f_llm:evo-state:skill:{title}                       → per-skill cooldown and gate result
f_llm:evo-state:kn:{docId}                          → consumed knowledge
```

**SQL**: DDL lives in `tables-pg.sql` / `tables-mysql.sql` at the module root. `StoreWiring.wire()` creates tables and indexes idempotently at startup (PG also gets the report index `(skill_title, at_time DESC)`).

### Embeddings (BGE-M3)

| Component | Purpose |
|---|---|
| `Embedding` | Facade: `embed(llmName, EmbeddingParam)` with config snapshot and circuit breaking |
| `HttpEmbedder` | OpenAI-compatible `/v1/embeddings` client |
| `BgeM3Transport` / `BgeM3Codec` | BGE-M3 three-way encoding (dense / sparse / colbert) |
| `DefaultEmbedder` | Production `Embedder`, reads `llm_embeddingUrl` |

The endpoint defaults to `http://127.0.0.1:8000/v1/embeddings`; `deploy_bge_m3.sh` starts a local service.

### Knowledge retrieval

- `KnowledgeChunker`: chunking with length and overlap;
- `KnowledgeSearch`: vector recall at chunk level, returns `KnowledgeHit`;
- `KnowledgeIndexRebuilder` / `MemoryIndexRebuilder`: rebuild at startup when `llm_rebuildIndexOnStart` is on.

---

## loom orchestration

```
natural language
→ Planner (LLM returns a JSON plan, or clarification questions)
→ CodeGen (plan → step sources + flow source, no compilation)
→ LoomRegistry / LoomStore (persist sources and status)
→ LoomCompiler (compile step closures)
→ LoomRunner (topological execution, emits events)
```

State machine: `clarifying → pending → compiled`; a failed recompile marks that flow `failed` without affecting others.

### Five-minute quickstart

```cangjie
import fountain::f_egraph.base.*
import fountain::f_llm.loom.*

// 1) Wire once: store gateway, host, memory policy, skill catalog, evolution tables/state/lease
let chat = { model: String, system: String, input: String => yourLlmCall(model, system, input) }
let service = LoomWiring.wire(chat, plannerModel: 'deepseek-flash')

// 2) Preview: Planner + CodeGen, stored as pending, not compiled
let preview = service.execute(LoomRequest(
    name: 'daily-report',
    description: 'Summarise yesterday commits and issues into a daily report'))
println(preview.status)          // pending | clarifying
println(preview.flowSource)      // generated flow source (readable, editable)
println(preview.stepSources)     // per-step source

// 3) Confirm: compile the step closures, status becomes compiled
let _ = service.confirmFlow('daily-report')

// 4) Execute: needs a host (model channel + tool channel)
let host = DefaultLoomHost(chat)
let _ = service.executeNow('daily-report', host,
    StartEvent(category: 'loom', tag: 'daily-report', name: 'start', data: '{}'))

// 5) Other entry points
service.status('daily-report')
service.delete('daily-report')
```

| Stage | What happens | On failure |
|---|---|---|
| `execute(confirm=false)` | Planner → plan, CodeGen → sources, stored as `pending` | ambiguous description → `clarifying` with `questions` |
| `confirmFlow(name)` | compile step closures | stays `pending` and throws (sources remain readable) |
| `executeNow(name, …)` | requires `compiled` | throws when not compiled |

Without a `chat` argument use `LoomWiring.wire(plannerModel: '…')`, which uses `LoomDefaults.chat` (requires configured `LLMConf`).

### Hand-written flows

```cangjie
let plan = FlowPlan('weekly-report')
let fetch = StepPlan('fetch', 'tool')
fetch.tool = 'webSearch'
fetch.args = '{"query":"release notes this week"}'
let sum = StepPlan('sum', 'llm')
sum.model = 'deepseek-flash'
sum.system = 'You are a technical editor'
sum.input = 'This week: {fetch.output}'      // reference an upstream step output
plan.steps.add(fetch)
plan.steps.add(sum)
plan.edges.add(EdgePlan('fetch', 'sum'))

let _ = LoomRunner().run(plan, host,
    StartEvent(category: 'loom', tag: 'weekly-report', name: 'start', data: ''))
```

| kind | Purpose | Key fields |
|---|---|---|
| `tool` | call a registered tool | `tool`, `args` |
| `mcp` | call an MCP tool | `tool`, `args` |
| `llm` | call the model | `model`, `system`, `input` |
| `jit` | arbitrary Cangjie snippet, may call `loomStore` | `input` is source; must produce `let <id>_result = …` |

`http` is a reserved kind; `plan.validate()` rejects it explicitly rather than silently treating it as `llm`.

| Rule | Notes |
|---|---|
| Order | topological over `edges`; steps without incoming edges run first |
| Placeholders | `{stepId.output}` is replaced with that step's output; `{start.output}` is the incoming event data |
| JIT scope | each JIT step compiles on its own — pass values with `{id.output}` |
| Parallelism | synchronous by default; `StepPlan.async` or `run(parallel: true)` (or plan `parallel`) enables it |
| Validation | `plan.validate()` rejects duplicate ids, dangling edges and missing kinds |

### Tools exposed to the model

| Tool | Key params | Behaviour |
|---|---|---|
| `loomExecute` | `name, description, tools?, mcps?, persona?, confirm?, execute?, parallel?` | `confirm=false` returns the plan only; `confirm=true` compiles; `execute=true` also runs it |
| `loomDelete` | `name` | Remove from registry and store |
| `memoryCall` | `op`(search/add/remove) + `payload` | Same gateway as `loomStore("memory", …)` |
| `knowledgeIngest` | `docId, title, content` | Write a knowledge document |
| `loomStoreCall` | `kind, op, payload` | Generic read/write entry on the same gateway as `loomStore` (read knowledge/experience, load skills) |
| `listTools` / `searchTools` | `offset, limit` / `query, topK` | List tools, keyword-search tools |
| `skillImport` | `path` | Import a skill package; idempotent by title |
| `scheduleCreate` / `scheduleDelete` | `name, cron, payload?` / `name` | Register / cancel a scheduled flow |

### JIT entry points inside a flow

```cangjie
loomCallTool(name, argsJson)          // registered tool or MCP tool
loomCallLlm(model, system, input)     // model call
loomStore(kind, op, payload)          // read/write the six stores
```

| kind | ops | Notes |
|---|---|---|
| `memory` | `add` / `get` / `list` / `search` / `remove` | `search` returns `{id,title,content,kind,score}`; `list` accepts `kind` |
| `experience` | same as `memory` | Alias that forces `kind=experience` |
| `knowledge` | `get` / `docIds` / `search` / `upsert` / `remove` | `search` returns matched chunks with content |
| `skill` | `load` / `get` / `list` / `upsert` / `count` / `remove` | `load` fetches details by title |
| `prompt` | `latest` / `get` / `put` / `remove` | `put` with `version<=0` appends after the latest |
| `character` | `get` / `set` / `reset` | `characterKey` must be predefined (or `custom`) |
| `evolution` | `list` / `by_skill` | **Read-only**: reports are written by the background job |

Payloads are JSON strings:

```cangjie
let mem  = loomStore("memory", "list",
    "{\"userId\":7,\"namespace\":\"work\",\"kind\":\"note\",\"offset\":0,\"limit\":20}")
let hits = loomStore("memory", "search",
    "{\"userId\":7,\"namespace\":\"work\",\"text\":\"release process\",\"topK\":5}")
let one  = loomStore("memory", "get", "{\"userId\":7,\"id\":42}")
let id   = loomStore("memory", "add",
    "{\"userId\":7,\"namespace\":\"work\",\"title\":\"release decision\",\"content\":\"canary 5% first\",\"kind\":\"note\"}")

let exp  = loomStore("experience", "search",
    "{\"userId\":7,\"namespace\":\"work\",\"text\":\"canary\",\"topK\":5}")

loomStore("knowledge", "upsert", "{\"docId\":\"k1\",\"title\":\"release policy\",\"content\":\"canary 5% first\"}")
let doc  = loomStore("knowledge", "get", "{\"docId\":\"k1\"}")
let docs = loomStore("knowledge", "search", "{\"text\":\"canary\",\"limit\":5}")

let skill = loomStore("skill", "load", "{\"title\":\"daily-report-helper\"}")
let all   = loomStore("skill", "list", "{}")
let prm   = loomStore("prompt", "get", "{\"name\":\"reviewer\",\"version\":1}")
let ch    = loomStore("character", "get", "{\"userId\":7}")

let history = loomStore("evolution", "by_skill", "{\"skill\":\"daily-report-helper\",\"limit\":5}")
```

Reference them in the next LLM step:

```cangjie
let ask = StepPlan('ask', 'llm')
ask.model = 'deepseek-flash'
ask.system = 'BASE'
ask.input = 'Reference: {mem.output}\nQuestion: {start.output}'   // multiple references
```

### Persona and character

`FlowPlan.persona` and the user's `character` both end up as the system prefix, resolved in three levels:

```
1. prompt store: prompt.latest(name) hit → use its content
2. built-in persona body: PredefinedCharacters.bodyOf(name) (13 predefined personas, text in code)
3. literal text: neither matched → treat the argument itself as the body
```

```cangjie
// 1) Prompt-store entry (highest priority)
loomStore("prompt", "put", "{\"name\":\"reviewer\",\"content\":\"You are a strict reviewer\"}")
plan.persona = 'reviewer'

// 2) Predefined persona key
plan.persona = 'rigorous'        // default/rigorous/friendly/blunt/…

// 3) Literal text
plan.persona = 'Point out mistakes only, no praise'

// 4) Omit it: fall back to the user's character record
loomStore("character", "set",
    "{\"userId\":7,\"characterKey\":\"rigorous\",\"prompts\":\"Answer in at most 300 characters\"}")
plan.persona = ''
```

`custom` is special: the body comes only from `character.prompts`; when both are empty no persona is injected.
`character.prompts` is appended as user-level extra instructions (language, length, …).
The character record is resolved by `LoomMemoryPolicy.userId` (skipped when `userId <= 0`).

### Skill injection

| Mode | Usage | Notes |
|---|---|---|
| Explicit | `LoomRunner().run(plan, host, start, skills: ['daily-report-helper'])` | Loaded by title, fixed order |
| Automatic | omit `skills` with `autoSkills=true` (default) | Search using plan notes + start input, take `skillTopK` (default 3) |

`SkillCatalog` runs in two modes: vector cosine when an encoder is installed (vectors cached by `title#version`), otherwise keyword fallback (substring, character-overlap ratio, title coverage). **Encoder failures degrade silently**, so check `SkillCatalog.embedFailureDetail()` → `(query-side failures, skill-side failures)`.

### Extraction at flow end

`LoomRunner` does this in `finally` (both success and failure):

| Output | kind | Condition |
|---|---|---|
| Context digest | `note` | `policy.enabled` (default true) and at least one model call |
| Experience | `experience` (`experience_failed` on failure) | same as above |
| Knowledge document | `loom:<flow>:<seq>` | requires `writeKnowledge` |

With `summarize=true` the model returns `{"memory":"…","experience":"…"}`; invalid JSON falls back to rule-based extraction.

Switches in `LoomMemoryPolicy`:

| Parameter | Default | Effect |
|---|---|---|
| `enabled` | `true` | When false, not even the transient context is recorded |
| `userId` / `namespace` | `0` / `'loom'` | Where to write; also selects the character record |
| `maxTurns` | `20` | How many recent turns the digest keeps |
| `summarize` / `model` | `false` / `''` | Model-based extraction |
| `writeKnowledge` | `false` | Also write a knowledge document |
| `autoSkills` / `skillTopK` / `skillMinScore` | `true` / `3` / `0.2` | Automatic skill selection |

### Scheduling

Flows registered by `scheduleCreate` run through `LoomScheduler` (`TicktockScheduler`, backed by `f_ticktock`); JIT steps inside a scheduled run are handled by `JitTicktockTask`. When `LoomSchedules` is not installed, both registration and firing are skipped.

### Third-party channels (email)

Flows go through `channel` instead of calling `f_email` directly:

```bash
export llm_channels='[{"platform":"email","account":"work","from":"bot@example.com",
  "user":"bot@example.com","password":"***","smtpHost":"smtp.example.com","smtpPort":465,
  "imapHost":"imap.example.com","imapPort":993}]'
```

```cangjie
// inside a flow step (JIT or tool loop)
loomCallTool("channelSend",
    '{"platform":"email","account":"work","to":"a@b.c","subject":"report","text":"body",' +
    '"attachments":[{"filename":"report.pdf","path":"/tmp/report.pdf"}]}')
loomCallTool("channelInbox", '{"platform":"email","account":"work","downloadDir":"/tmp/inbox"}')
```

| Capability | Notes |
|---|---|
| Platform / account | Addressed as `(platform, account)`; several accounts per platform; blank account falls back only when the platform has exactly one |
| Adding a platform | Implement `Channel` plus one top-level `let _ = ChannelMediator.registerProvider('xxx', …)` |
| Implemented | `email` (SMTP send / IMAP receive, attachments included); `wechat` / `wecom` / `dingtalk` / `feishu` are reserved names only |
| Attachments | Send takes local paths that must sit under an allowed root (otherwise the whole send fails); receive saves only with `downloadDir`, keeps the last path segment only, conflicts get `-2`, nothing is overwritten |

### Flow routing (Supervisor)

Once there are many flows, callers no longer need to remember which one handles what: turn on `llm_supervisor` and every flow that compiles becomes a routing target, with a model deciding which flow a description belongs to.

```bash
export llm_supervisor=true        # enable routing; each flow maps to a unique event sv/<flow-name>
export llm_loomOnNoUsable=true    # optional: auto-build and run a new flow when none fits (default off)
```

```cangjie
// LoomWiring.wire assembles it when the switch is on: routes seeded from compiled flows, rebuilt from the store on restart
let service = LoomWiring.wire(chat, plannerModel: 'deepseek-flash')

// dispatch: description → routing → execution (the description is the start event data, reaching the first step as {start.output})
let supervisor = Supervisor.current().getOrThrow()
let outcome = supervisor.dispatch('summarise today's commits')
println(outcome.kind)     // dispatched | created | noUsableFlow | clarifying
println(outcome.flow)     // chosen flow (for created: the generated auto-<seconds>)
println(outcome.event)    // the Supervisor event actually used: sv/<flow-name>
println(outcome.message)  // fixed message when nothing can handle it
```

| `outcome.kind` | Meaning | `result` |
|---|---|---|
| `dispatched` | An existing flow matched and finished | `Some(Event)` |
| `created` | A new flow was built, registered and finished | `Some(Event)` |
| `clarifying` | The auto-built flow needs more information | `None` (questions are stored) |
| `noUsableFlow` | Nothing usable (including unusable routing output) | `None` |

The route table can be changed at runtime:

```cangjie
supervisor.routes()          // every route: name / description / event / status
supervisor.routable()        // only compiled ones, i.e. what routing may pick
supervisor.eventOf('daily')  // Some("sv/daily")

let _ = supervisor.register('adhoc', 'temporary flow', status: LoomStatus.COMPILED)
let _ = supervisor.unregister('adhoc')
```

| Behaviour | Notes |
|---|---|
| Registration | `execute` / `confirmFlow` register on commit; `delete` unregisters; `clarifying` is skipped (no source, cannot run) |
| Routing | Only `compiled` flows (name/description/event) go to the model; non-JSON, blank or unknown names count as "no usable flow" |
| Event name | `sv/<flow-name>`, kept apart from the internal tag `loom/<name>#<seq>` |
| No usable flow | `llm_loomOnNoUsable=false` → returns "没有可完成此工作的流程"; `true` → plan, register and run a new flow |
| Store unavailable | Startup continues: `LoomBootstrap.startup(...)` reports `restoreFailed=true`, routes are empty but the flow service still works |
| Disabled | Zero overhead: no registration, no routing, no extra model calls |

---

## Experience → skill evolution

Flow end only writes experience; **every skill change goes through `SkillEvolutionJob`**:

```
trigger → read materials newer than the watermark (experience + knowledge)
  → SkillMatcher: assign to existing skills / cluster into new-skill candidates
  → evolve existing skills first: Policy → model rewrites details → SkillGate A/B → version + 1
  → then create new skills: cluster large enough → SkillNamer (must return samples) → version 1
  → SkillEvolutionLedger records the report → advance the watermark
```

| Component | Default policy |
|---|---|
| `SkillEvolutionPolicy` | ≥ 3 samples, success rate ≥ 0.8, 1-day cooldown; **2 days after a failed gate** |
| `SkillGate` | Runs the skill's own `samples` against old/new details; new must be ≥ old and reach `minScore` |
| `SkillNamer` | Title ≤ 24 chars, **at least one sample required** — otherwise the skill cannot self-evolve |
| Knowledge dedupe | `processedAmong(docIds)` membership check, so a batch is not re-clustered every run |

Register at startup:

```cangjie
LoomWiring.wire(chat, plannerModel: 'chat-pro',
                evolutionCron: '0 0 3 * * * *',      // empty = disabled
                evolutionUserId: 7,
                evolutionNamespace: 'work',
                evolutionNameCandidates: true,
                skillEmbedder: SkillCatalog.embeddingEncoder('bge-m3'))
```

### Multi-process exclusion: daily lease

The job runs once a day; a time-based UUID plus a date-level optimistic lock ensures only one process runs it:

| Vector store (`llm_memoryStore`) | Lease location | Exclusion |
|---|---|---|
| `mysql` / `postgres` | single-row table `llm_evolution_lease` | `UPDATE … WHERE lease_value = old`, a real CAS |
| `f_hydra` | payload of a local all-zero vector record | local storage, single process |
| `fhydra` | payload of a remote all-zero vector record | write-then-read verification |
| others | f_store / in-memory | single process |

An all-zero vector is used because a lease must never surface in semantic search (cosine is 0 with any query).

```
startup → EvolutionLeases.bootstrap(): write a UUID if absent
daily trigger → acquire(now)
  ├─ same day as the lease → empty string → give up
  └─ older than today → new UUID + CAS on the old value
       ├─ success → acquired
       └─ failure (someone changed it first) → give up
```

---

## Retrieval evaluation

Unit tests only verify ranking logic; semantic quality needs the real model (see `doc/retrieval-eval.md`):

| Path | Content |
|---|---|
| `eval/retrieval_corpus.tsv` | 50 documents (10 topics × 5) |
| `eval/retrieval_queries.tsv` | 612 positives (300 templated + 300 hard + 12 multi-label) + 10 negatives |
| `eval/run_eval.sh` | One-shot real-embedding run with a printed report |

```bash
eval/run_eval.sh                          # bge-m3 at 127.0.0.1:8000 by default
fllm_evalMinScore=0.5 eval/run_eval.sh    # adjust the threshold
```

Metrics: `recall@1` / `recall@5` / `MRR` / `nDCG@5` (rank-sensitive, normalised by the ideal ordering for multi-label cases) plus the negative pass rate.
Measured with bge-m3 at `minScore=0.5`: templated ~100%, **hard set recall@1 39.66% / nDCG@5 54.76%**, negatives 90%; character overlap scores only 22% on the same hard set.

Cangjie entry point:

```cangjie
let outcome = RetrievalEvalRunner.run(InMemoryMetaStore(), './eval', 'bge-m3', minScore: 0.5f64)
println(outcome.report)
// outcome.embedFailures must be 0; otherwise the run measured keywords, not vectors
```

---

## Bundled script and DDL

### `deploy_bge_m3.sh`: local BGE-M3 embedding service

Installs BGE-M3 as an OpenAI-compatible `/v1/embeddings` endpoint (dense + sparse + colbert), which is exactly what `llm_embeddingUrl` points at by default.

```bash
sudo ./deploy_bge_m3.sh                    # install or update (idempotent)
sudo ./deploy_bge_m3.sh status             # service / model / port
sudo ./deploy_bge_m3.sh smoke              # one embedding round-trip
sudo ./deploy_bge_m3.sh restart
sudo ./deploy_bge_m3.sh uninstall          # stop service, remove unit (keep model)
sudo ./deploy_bge_m3.sh uninstall --purge  # also delete /opt/bge-m3
```

What it does: system deps + dedicated venv (`/opt/bge-m3/venv`) → install torch(CPU)+transformers+fastapi+uvicorn →
fetch weights from ModelScope (including the `sparse_linear.pt` / `colbert_linear.pt` projections) → serve `/v1/embeddings` →
register a systemd unit and run a health check.

| Env var | Default | Purpose |
|---|---|---|
| `BGE_HOME` | `/opt/bge-m3` | Install root (venv / model / server.py) |
| `BGE_PORT` | `8000` | Listen port, matching `llm_embeddingUrl` |
| `BGE_THREADS` | `8` | torch thread count |
| `BGE_PIP_INDEX` / `BGE_PIP_EXTRA` | Tsinghua mirror / empty | pip index and extra index |
| `BGE_MODEL_BASE` | ModelScope `BAAI/bge-m3` | Weight source |
| `BGE_FORCE_DOWNLOAD` | `0` | Set `1` to re-download weights |

Dense-only still works: point `llm_embeddingUrl` at any OpenAI-compatible endpoint, but missing sparse/colbert marks results
`degraded` and disables reranking (see `doc/known-limitations.md` §2).

### `tables-pg.sql` / `tables-mysql.sql`: schema

The two files mirror each other column by column — only types, identity and index syntax may differ, so **they must be changed together**. 20 tables:

| Group | Tables |
|---|---|
| Model config | `llm_conf` |
| Memory and knowledge | `llm_memory` / `llm_memory_kind` / `llm_memory_event` / `llm_memory_vector` / `llm_memory_token` / `llm_document` / `llm_document_chunk` |
| Metadata | `llm_character` / `llm_character_binding` / `llm_channel_binding` / `llm_prompt` / `skills` / `skill_references` / `llm_skill_version` / `agents` / `memory_summaries` / `agent_todo` |
| Orchestration and usage | `llm_loom_flow` / `llm_token_usage` |

```bash
# PostgreSQL (needs pgvector >= 0.7, extension name "vector")
psql "postgres://fllm_test:fllm_test@127.0.0.1:5432/fllm_test" \
     -c 'CREATE EXTENSION IF NOT EXISTS vector'
psql "postgres://fllm_test:fllm_test@127.0.0.1:5432/fllm_test" -f tables-pg.sql

# MySQL (plain tables 8.0+; VECTOR columns and HNSW indexes need 9.2+)
mysql -h127.0.0.1 -ufllm_test -p fllm_test < tables-mysql.sql
```

| Note | Detail |
|---|---|
| The 4 evolution tables are not here | `llm_skill_evolution` / `llm_skill_evolution_state` / `llm_skill_evolution_knowledge` / `llm_evolution_lease` are created idempotently at startup by `EvolutionStores` / `EvolutionStateStores` / `EvolutionLeases.bootstrap()` |
| Existing tables are not altered | `CREATE TABLE IF NOT EXISTS` only creates; adding a column requires your own `ALTER TABLE` (and keeping both files in sync) |
| Old MySQL / MariaDB | Drop the trailing vector-index statements (and the vector columns for MariaDB); retrieval degrades to "fetch candidates + compute in the app" — same results, just slower |
| Keep in sync with code | Change `tables-pg.sql` first, then `tables-mysql.sql` and the fields in `src/model/po` |

---

## Configuration

All environment variables, read once at startup.

### Storage and embeddings

| Key | Default | Purpose |
|---|---|---|
| `llm_memoryStore` | `f_hydra` | Content family + lease: `f_hydra`/`fhydra`/`postgres`/`mysql`/`inMemory` |
| `llm_metaStore` | `f_store` | Metadata family + evolution report/state |
| `llm_metaStorePath` | `./data/f_llm-meta` | f_store directory |
| `llm_contentStoreUrl` | empty | Remote content store URL (fhydra) |
| `llm_hydraPath` / `llm_hydraUrl` / `llm_hydraSecret` | `./data/f_hydra` / `http://127.0.0.1:18081/rpc` / empty | f_hydra path, remote URL, shared secret |
| `llm_embeddingUrl` | `http://127.0.0.1:8000/v1/embeddings` | BGE-M3 endpoint |
| `llm_embeddingTimeoutMs` / `llm_embeddingRetries` | `3000` / `2` | Timeout and retries |
| `llm_rebuildIndexOnStart` / `llm_rebuildIndexUserId` / `llm_rebuildIndexNamespace` | off / 0 / empty | Rebuild vector indexes at startup |
| `llm_memoryUserId` | 0 | Default memory owner |

### Model access

| Key | Default | Purpose |
|---|---|---|
| `llm_confSource` | empty | Config source: `static` / `file` / `env` / `database` / `store` |
| `llm_confs` | empty | Inline configs (JSON array) |
| `llm_confRefreshSeconds` | none | Config refresh interval |
| `llm_loadBalanceAlgo` | none | Candidate selection algorithm |
| `llm_failureThreshold` / `llm_cooldownSeconds` | none | Circuit-breaker threshold and cooldown |
| `llm_accessTryingCount` / `llm_accessTryingElapsed` | none | Retry count / total retry window |
| `llm_streamIdleTimeout` / `llm_streamMaxLineBytes` | none | Streaming idle timeout and line limit |
| `llm_toolResultMaxBytes` / `llm_fetchMaxBytes` | none | Tool result / fetch size limits |
| `llm_prunerLlmName` / `llm_summarisingLlmName` | none | Model for model-dependent pruners / extraction |
| `llm_balanceLowThreshold` | none | Balance warning threshold |
| `llm_supervisor` | `false` | Enable flow routing (Supervisor): compiled flows auto-register and can be dispatched by description |
| `llm_loomOnNoUsable` | `false` | Auto-build a new flow when Supervisor finds no usable one; effective only with `llm_supervisor=true` |
| `llm_channels` | empty | Third-party accounts (JSON array, one per account; invalid entries are skipped with a warning) |
| `llm_channelSendRoots` | empty | Allowed roots for outgoing attachments (comma separated); falls back to `llm_fileSandboxPath`, otherwise attachments are disabled |

### Others

| Key | Default | Purpose |
|---|---|---|
| `llm_fileSandboxPath` | none | File tools are confined to this directory |
| `llm_faithfulMemoryPath` | none | Faithful memory path |
| `llm_makingMemory` | none | Whether to persist memory (required for experience) |
| `llm_summarisingModel` / `llm_summarisingActionKind` | `glm-4.7-flash` / none | Extraction model and action kind |
| `llm_db` | none | Database connection (SQL deployments) |
| `hydra_filterFields` | `kind,save_day,tags` | Server-side inverted-index allowlist (rebuilt on restart when changed) |
| `fllm_runEval` / `fllm_evalModel` / `fllm_evalMinScore` / `fllm_evalDir` | unset / `bge-m3` / `0.2` / `./eval` | Retrieval evaluation |

Legacy keys `llm_memoryBackend` / `llm_characterBackend` / `llm_memoryPath` / `llm_contentStore` are recognised but ignored, with a warning per key at startup.

---

## Tests

```bash
cjpm test                 # unit tests, no external services
cjpm test                 # DB-backed cases run when reachable, otherwise print SKIP
```

Integration tests probe connectivity and skip themselves when the database is unreachable.

---

## Documentation

| File | Content |
|---|---|
| `doc/f_llm.md` | Design doc: layering, contracts, data layout, key flows, failure handling, test strategy |
| `doc/f_llm-memory-design.md` | Memory, knowledge, skill and persona design with prompts |
| `doc/loom.md` | loom orchestration, store gateway, persona, skill evolution, report table |
| `doc/retrieval-eval.md` | Retrieval evaluation: data format, metrics, baselines, thresholds |
| `doc/content-store.md` | Content-store contract |
| `doc/known-limitations.md` | Known limitations |
| `doc/dev-env.md` | Development environment |
| `doc/todo.md` | Open items |
| `doc/spec/add-loom-supervisor/` | Spec copies for flow routing (proposal / spec / design / tasks) |

---

## Known limitations (summary)

| Item | Note |
|---|---|
| Configuration is read-only | Read once at startup; switching stores or endpoints requires a restart |
| Encoder failures degrade silently | `SkillCatalog` falls back to keywords; use `embedFailureDetail()` to see which path ran |
| Rebuild is a full scan | Rebuilding the inverted index is O(records); prefer off-peak |
| `processedKnowledge` is capped | Only for operations/diagnostics; dedupe uses `processedAmong`, which is unbounded in history |
| Scheduling is per process | `SkillEvolutionJob.schedule` registers in-process; cross-process exclusion relies on the daily lease |

## A2A (Agent-to-Agent)

Disabled by default. With `llm_a2aEnabled=true`, wiring exposes `loom.Supervisor` as an A2A agent:

| Direction | Usage |
|---|---|
| Outside → loom | A2A clients call `a2a.message.send`; the text goes to `Supervisor.dispatch` and the outcome becomes the task state |
| loom → outside | `LoomA2aClient().ask(url, text)`, or the in-flow tool `a2aCall{url, text}` |

Mapping: `dispatched` / `created` → `completed`, `clarifying` → `input-required`, everything else → `failed`.
`dispatch` is synchronous, so long flows make the A2A request wait; use `a2a.message.stream` (SSE) when you need progress events.

---

## Other public API

The declarations below are not expanded above; they are grouped by module level and by type (members declared in `extend` blocks are listed under the extended type). See the corresponding files under `src/` for the full semantics.

- Module level: `public class A2aCallFunction <: FunctionCalling<A2aCallParam>`, `public class A2aCallParam`, `AbstractFileFunction` (class), `public class Agent`, `AgentEvent` (class), `AgentEventData` (class), `AgentTask` (class), `AgentsFinder` (interface), `public class AliyunBalanceQuerier <: BalanceQuerier`, `public class Answer`, `public open class AssistantMessage <: ChatMessage`, `public class AssumptionDto`, `AttachmentSink` (class), `BalanceMediator` (class), `BalancePoster` (type), `BalanceQuerier` (interface), `public class BalanceSnapshot`, `BalanceUnits` (struct), `BalanceUnsupportedException` (class), `CallLog` (struct), `ChannelAccountConf` (class), `public class ChannelAttachmentParam`, `ChannelBootstrap` (class), `ChannelException` (class), `public class ChannelInboxFunction <: FunctionCalling<ChannelInboxParam>`, `public class ChannelInboxParam`, `ChannelInstallReport` (class), `ChannelPlatforms` (struct), `public class ChannelSendFunction <: FunctionCalling<ChannelSendParam>`, `public class ChannelSendParam`, `ChatCompletionsMapper` (struct), `public open class ChatMessage`, `ChatStreamAccumulator` (class), `ClarifyQuestion` (class), `Code` (class), `CodeFinder` (interface), `CodeParam` (class), `ColbertCodec` (class), `ColbertVectors` (class), `public class Command`, `public class ConsoleOutput`, `public class ContentPart`, `public abstract class ContextLLMPruner <: ContextPruner`, `ContextPruner` (interface), `ContextPrunerName` (type), `public open class ContextSummaryPruner <: ContextLLMPruner`, `public class CurrentTimeParams`, `public class DeepSeekBalanceQuerier <: BalanceQuerier`, `public class DeepSeekSearchProvider <: SearchProvider`, `DefaultHttpTransport` (class), `DefaultStreamTransport` (class), `DeployPaths` (class), `public interface DoSample`, `public struct DummyTokenUsageSaver <: TokenUsageSaver`, `EmailChannel` (class), `EmailTransport` (interface), `EmbeddingException` (class), `public class EmbeddingResp`, `EmbeddingResponse` (class), `EmbeddingTransport` (interface), `EvalCase` (class), `EvalDoc` (class), `EvalOutcome` (class), `EvalReport` (class), `EventFinder` (interface), `EvolutionDecision` (class), `EvolutionInput` (class), `EvolutionLease` (interface), `EvolutionSkillState` (class), `EvolutionStateStore` (interface), `EvolutionStore` (interface), `public class ExperienceExtractor <: MemoryExtractor`, `public interface ExperienceFinder <: MemorySummaryFinder`, `ExperienceItem` (class), `FEmailTransport` (class), `FStoreEvolutionLease` (class), `FStoreEvolutionStateStore` (class), `FStoreEvolutionStore` (class), `FStoreLoomStore` (class), `FStoreMetaStore` (class), `FaithfulMemory` (interface), `FetchRejectedException` (class), `public class FetchedPage`, `FhydraContentStore` (class), `public class FileReadingParams`, `public class FileReplacingParams`, `public class FileWritingParams`, `FrequencyPenalty` (interface), `public class Function`, `public class FunctionCall <: Hashable & Equatable<FunctionCall>`, `FunctionCallingException` (class), `FunctionMeta` (struct), `FunctionNotFoundException` (class), `FunctionResult` (struct), `GeneratedFlow` (class), `HeuristicTokenCounter` (class), `HydraContentStore` (class), `HydraEvolutionLease` (class), `HydraMemoryRepository` (class), `IllegalPathException` (class), `InMemoryContentStore` (class), `InMemoryEvolutionLease` (class), `InMemoryEvolutionStateStore` (class), `InMemoryEvolutionStore` (class), `InMemoryKnowledgeStore` (class), `public class InMemoryMemoryStore <: MemoryStore`, `InboundAttachment` (class), `InboundMessage` (class), `public class IndividualityExtractor <: MemoryExtractor`, `public interface IndividualityFinder <: MemorySummaryFinder`, `KindPersistence` (interface), `Knowledge` (class), `KnowledgeChunk` (class), `KnowledgeEntity` (class), `KnowledgeFinder` (interface), `public class KnowledgeIngestFunction <: FunctionCalling<KnowledgeIngestParam>`, `public class KnowledgeIngestParam`, `KnowledgeKind` (type), `KnowledgeParam` (class), `KnowledgeQuery` (class), `LLMApiKind` (enum), `LLMConfCodec` (struct), `public interface LLMConfDAO <: RootDAO`, `public class LLMConfServiceImpl <: LLMConfService`, `LLMConfView` (class), `LLMConfig` (struct), `LLMConfsHolder` (class), `LLMConfsSnapshot` (class), `LLMDelta` (class), `LLMDeltaKind` (enum), `LLMErrorClassifier` (struct), `LLMException` (class), `LLMHooks` (class), `LLMHttpResponse` (class), `public class LLMResp`, `LLMStreamTransport` (interface), `public open class LLMToolParams <: LLMParams`, `LLMTransport` (interface), `LLMType` (type), `public class ListToolsFunction <: FunctionCalling<ListToolsParam>`, `public class ListToolsParam`, `LlmEmbeddingTransport` (class), `LlmTurn` (class), `LoomA2a` (class), `LoomAgent` (class), `LoomCharacterScope` (class), `LoomContextLog` (class), `public class LoomDeleteFunction <: FunctionCalling<LoomDeleteParam>`, `public class LoomDeleteParam`, `LoomException` (class), `public class LoomExecuteFunction <: FunctionCalling<LoomExecuteParam>`, `public class LoomExecuteParam`, `LoomFlow` (class), `LoomHost` (interface), `LoomHostApi` (class), `LoomJitBridge` (class), `LoomMemoryExtractor` (class), `LoomProgram` (class), `LoomRegistry` (class), `LoomResult` (class), `LoomService` (class), `LoomServices` (class), `LoomStatus` (struct), `LoomStoreGateway` (class), `LoomTimeout` (class), `McpClientAdapter` (class), `McpFunctionCalling` (class), `McpToolClient` (interface), `McpToolSource` (class), `Memory` (struct), `public class MemoryCallFunction <: FunctionCalling<MemoryCallParam>`, `public class MemoryCallParam`, `MemoryExtractor` (class), `MemoryKinds` (class), `public class MemoryLoading`, `MemoryLoomStore` (class), `MemoryQuery` (class), `MemoryRecorderTask` (class), `MemoryRepository` (interface), `MemoryRepositoryAdapter` (class), `MemoryStoreAdapter` (class), `public class MemorySummary`, `MemorySummaryFinder` (interface), `MemoryWrite` (class), `MetaStoreAdapter` (class), `ModelCapabilities` (struct), `ModelName` (type), `MySqlContentStore` (class), `public interface MySqlEvolutionDAO <: RootDAO`, `MySqlEvolutionLease` (class), `public interface MySqlEvolutionLeaseDAO <: RootDAO`, `public interface MySqlEvolutionStateDAO <: RootDAO`, `MySqlEvolutionStateStore` (class), `MySqlEvolutionStore` (class), `public interface MySqlKindDAO <: RootDAO`, `MySqlKindPersistence` (class), `public interface MySqlKnowledgeDAO <: RootDAO`, `MySqlKnowledgeStore` (class), `public interface MySqlLoomDAO <: RootDAO`, `MySqlLoomStore` (class), `public interface MySqlMemoryDAO <: RootDAO`, `public class MySqlMemoryRepository <: MemoryRepository & RootService`, `public interface MySqlMetaDAO <: RootDAO`, `public class MySqlMetaStore <: MetaStore & RootService`, `public interface MySqlTokenUsageDAO <: RootDAO`, `public class MySqlTokenUsageSaver <: TokenUsageSaver & RootService`, `public class OptionDto`, `OrganizationFinder` (interface), `OutboundAttachment` (class), `OutboundMessage` (class), `public class Parameters`, `public class PlanDto`, `PlannerResult` (class), `PostgresContentStore` (class), `public interface PostgresEvolutionDAO <: RootDAO`, `PostgresEvolutionLease` (class), `public interface PostgresEvolutionLeaseDAO <: RootDAO`, `public interface PostgresEvolutionStateDAO <: RootDAO`, `PostgresEvolutionStateStore` (class), `PostgresEvolutionStore` (class), `public interface PostgresKindDAO <: RootDAO`, `PostgresKindPersistence` (class), `public interface PostgresKnowledgeDAO <: RootDAO`, `PostgresKnowledgeStore` (class), `public interface PostgresLoomDAO <: RootDAO`, `PostgresLoomStore` (class), `public interface PostgresMemoryDAO <: RootDAO`, `public class PostgresMemoryRepository <: MemoryRepository & RootService`, `public interface PostgresMetaDAO <: RootDAO`, `public class PostgresMetaStore <: MetaStore & RootService`, `public interface PostgresTokenUsageDAO <: RootDAO`, `public class PostgresTokenUsageSaver <: TokenUsageSaver & RootService`, `PredefinedCharacters` (class), `PromptCapabilities` (class), `Prompts` (struct), `public class Property`, `public class QuestionDto`, `ReceivedAttachment` (class), `ReceivedMail` (class), `ReloadResult` (class), `RemoteTokenCounter` (class), `public class ResponseFormat`, `ResponsesMapper` (struct), `ResponsesStreamAccumulator` (class), `ResultType` (enum), `RetrievalEval` (class), `RetrievalScoring` (class), `Role` (type), `RoleException` (class), `public class ScheduleCreateFunction <: FunctionCalling<ScheduleCreateParam>`, `public class ScheduleCreateParam`, `public class ScheduleDeleteFunction <: FunctionCalling<ScheduleDeleteParam>`, `public class ScheduleDeleteParam`, `SearchHttpException` (class), `SearchPoster` (type), `SearchProvider` (interface), `SearchProviderRegistry` (class), `public class SearchResult`, `public class SearchResultItem`, `public class SearchToolsFunction <: FunctionCalling<SearchToolsParam>`, `public class SearchToolsParam`, `SearchUnavailableException` (class), `SendReceipt` (class), `SignUtil` (struct), `public class SiliconFlowBalanceQuerier <: BalanceQuerier`, `SkillAssignment` (class), `SkillCandidate` (class), `SkillDraft` (class), `SkillEntry` (class), `SkillEvolutionLedger` (class), `SkillEvolutionReport` (class), `SkillEvolutionTask` (class), `SkillGateResult` (class), `public class SkillImportFunction <: FunctionCalling<SkillImportParam>`, `public class SkillImportParam`, `SkillImporter` (class), `public class SkillLoading`, `SkillMatchResult` (class), `SkillNotFoundException` (class), `SkillPackage` (class), `public class SkillReference`, `public class SkillReferenceLoading`, `public class SkillReferenceParam`, `SkillSample` (class), `SkillSamples` (class), `SkillType` (type), `SkillsFinder` (interface), `SpecKind` (type), `SpecialAgentId` (type), `Specification` (class), `SpecificationFinder` (interface), `public class SqlMemoryStore <: MemoryStore`, `public class StepDto`, `public class StoreCallFunction <: FunctionCalling<StoreCallParam>`, `public class StoreCallParam`, `StoreSettings` (class), `SummaryActionKind` (type), `SupervisorAgent` (class), `SupervisorOutcome` (class), `SupervisorRoute` (class), `public class SystemMessage <: ChatMessage`, `public class TencentCloudBalanceQuerier <: BalanceQuerier`, `TencentSigner` (struct), `TextClip` (class), `public class Thinking`, `public interface ThinkingBudget`, `ThinkingMode` (enum), `ThinkingPolicy` (struct), `ThinkingSwitch` (type), `TimeUuid` (class), `public class Todo`, `TodoFinder` (interface), `public class TodoListParam`, `public class TodoSaving`, `public class TodoSavingParam`, `TodoStatus` (type), `public class TodoStatusParam`, `TokenCounter` (interface), `public class TokenUsage`, `TokenUsageSaver` (interface), `public class TokenizerParams`, `public class ToolCall`, `public class ToolCallFunction`, `public class ToolCallMessage <: AssistantMessage`, `ToolCatalog` (class), `ToolEntry` (class), `public class ToolMessage <: ChatMessage`, `ToolScope` (class), `ToolType` (type), `TopicStat` (class), `VectorMath` (class), `VolcSigner` (struct), `public class VolcengineBalanceQuerier <: BalanceQuerier`, `public macro WeavedToolCall(input: Tokens): Tokens`, `public class WebFetchParams`, `public class WebSearchParams`, `public class ZhipuBalanceQuerier <: BalanceQuerier`, `createConfSource` (func), `emptySkills` (func), `parseConfJson` (func), `parseDeepSeekBalance` (func), `parseDeepSeekFetch` (func), `parseDeepSeekSearch` (func), `parseTencentBalance` (func), `parseVolcengineBalance` (func), `renderPage` (func), `sanitizeSchema` (func)
- `Agent`: `acceptableEvents` (prop), `prop producingEvents: Array<String>`
- `AgentEventData`: `addFunctions` (func), `let memorySummaries!: ArrayList<MemorySummary> = ArrayList<MemorySummary>()`, `let skillDetails!: ArrayList<(String, String)> = ArrayList<(String, String)>()`
- `AgentTask`: `prop acceptableEvents: Array<String>`, `open func exec(e: Event): Event`, `prop producingEvents: Array<String>`
- `AliyunBalanceQuerier`: `prop provider: String`
- `AliyunDialect`: `decorate` (func), `endpoint` (func), `headers` (func), `prop provider: String`
- `AssumptionDto`: `var field: String =`, `var reason: String =`, `var value: String =`
- `AttachmentSink`: `bareName` (func), `freeName` (func), `save` (func)
- `BalanceMediator`: `static let instance = BalanceMediator()`, `queryAll` (func)
- `BalanceUnits`: `format` (func), `parse` (func), `toYuan` (func), `unitOf` (func)
- `BgeM3Codec`: `static func parse(body: String): EmbeddingResponse`
- `CallLog`: `info` (func), `summary` (func)
- `ChannelAccountConf`: `let extra: HashMap<String, String>`, `let from: String`, `let imapHost: String`, `let imapPort: UInt16`, `let password: String`, `let smtpHost: String`, `let smtpPort: UInt16`, `let tls: String`, `let user: String`
- `ChannelBootstrap`: `install` (func), `installFromConfig` (func)
- `ChannelInstallReport`: `var errors: ArrayList<String> = ArrayList<String>()`, `var installed: Int64 = 0`, `var skipped: Int64 = 0`, `summary` (func)
- `ChannelMediator`: `accounts` (func), `closeAll` (func), `create` (func), `platforms` (func), `providerPlatforms` (func), `receive` (func), `resetAll` (func)
- `ChannelPlatforms`: `isReserved` (func)
- `ChatCompletionsMapper`: `build` (func), `parse` (func)
- `ChatMessage`: `addImage` (func), `addText` (func), `multimodal` (prop)
- `ChatStreamAccumulator`: `feed` (func), `finished` (prop), `isDone` (func)
- `CircuitBreaker`: `cleanup` (func), `isOpen` (func), `recordRetryableFailure` (func), `recordSuccess` (func), `size` (func)
- `ClarifyQuestion`: `let blocking: Bool`, `let defaultValue: String`, `let options: ArrayList<String>`, `let question: String`, `let why: String`
- `Code`: `let code!: String`, `let codeLang!: String`, `let filePath!: String`, `let moduleName!: String`, `let packageName!: String`, `let projectId!: Int64`
- `CodeGen`: `generate` (func), `hasAsync` (func), `stepSource` (func)
- `CodeParam`: `let code!: String =`, `let confidence!: Float64 = 0.0`, `let moduleName!: String =`, `let packageName!: String =`, `let projectId!: Int64 = 0`, `let weight!: Float64 = 0.0`
- `ColbertCodec`: `decode` (func), `encode` (func)
- `ContentPart`: `imageOf` (func), `textOf` (func)
- `ContextPrunerMediator`: `static let instance = ContextPrunerMediator()`
- `ContextSummaryPruner`: `open class ContextKeywordsPruner <: ContextLLMPruner`
- `DeepSeekBalanceQuerier`: `provider` (prop)
- `DeepSeekDialect`: `decorate` (func), `endpoint` (func), `headers` (func), `prop provider: String`
- `DeepSeekSearchProvider`: `fetchEndpoint` (prop), `provider` (prop), `searchEndpoint` (prop)
- `DefaultEmbedder`: `embedColbert` (func), `tokenize` (func)
- `DefaultHttpTransport`: `func post(url: String, headers: HashMap<String, String>, body: String): LLMHttpResponse`
- `DefaultLoomHost`: `callLlm` (func), `callTool` (func), `render` (func)
- `DeployPaths`: `resolve` (func), `root` (func)
- `DialectRegistry`: `providers` (func), `resolve` (func)
- `DummyTokenUsageSaver`: `static let instance = DummyTokenUsageSaver()`, `func saveTokenUsage(usage: TokenUsage): Unit`
- `EdgePlan`: `let from: String`, `let to: String`
- `EmailChannel`: `close` (func), `receive` (func)
- `Embedding`: `getTransport` (func), `parse` (func)
- `EmbeddingParam`: `let dimension!: Int64 = 1024`
- `EmbeddingResponse`: `let colbert: Array<Array<Float64>>`, `let dense: Array<Float64>`, `let sparse: HashMap<Int64, Float64>`
- `EvalCase`: `let expected: ArrayList<String>`, `isNegative` (func), `let topic: String`
- `EvalReport`: `let hitAt1: Int64`, `let hitAtK: Int64`, `let misses: ArrayList<String>`, `mrr` (func), `ndcg` (func), `let ndcgSum: Float64`, `let negativePassed: Int64`, `negativeRate` (func), `let negativeTotal: Int64`, `recallAt1` (func), `recallAtK` (func), `let reciprocalSum: Float64`, `render` (func), `let topics: ArrayList<TopicStat>`, `let total: Int64`
- `EvolutionDecision`: `let reason: String`, `let shouldEvolve: Bool`
- `EvolutionInput`: `let successes: ArrayList<ExperienceItem>`
- `EvolutionLeases`: `byName` (func)
- `EvolutionSkillState`: `lastEvolvedAt` (let), `lastGatePassed` (let)
- `EvolutionStateStores`: `byName` (func)
- `EvolutionStores`: `byName` (func)
- `ExperienceExtractor`: `func extract(jsonobj: JsonObject, overwriter: (String, String) -> Unit): Unit`, `prop systemPrompts: String`, `prop userPrompts: String`
- `FEmailTransport`: `close` (func), `receive` (func)
- `FStoreEvolutionLease`: `ensure` (func)
- `FStoreEvolutionStateStore`: `lastRunAt` (func), `markKnowledge` (func), `markRun` (func), `save` (func)
- `FStoreEvolutionStore`: `bySkill` (func), `save` (func)
- `FStoreLoomStore`: `save` (func)
- `FlowPlan`: `var notes: String =`, `round` (var), `toJson` (func)
- `FunctionCall`: `let function: Function = Function()`, `hashCode` (func)
- `FunctionMediator`: `definition` (func), `getDefinitions` (func)
- `FunctionMeta`: `let callee: (JsonObject) -> FunctionResult`, `let definition: JsonObject`
- `FunctionResult`: `let eventType!: EventType = EventType.Task`, `let resultType!: ResultType = ResultType.Text`
- `GeneratedFlow`: `let planJson: String`
- `HttpEmbedder`: `embedColbert` (func), `tokenize` (func)
- `HydraEvolutionLease`: `ensure` (func), `remote` (func)
- `HydraMemoryRepository`: `colbert` (func), `searchDense` (func), `searchSparse` (func), `upsertColbert` (func), `upsertSparse` (func)
- `InMemoryEvolutionLease`: `ensure` (func)
- `InMemoryEvolutionStateStore`: `lastRunAt` (func), `markKnowledge` (func), `markRun` (func), `save` (func)
- `InMemoryEvolutionStore`: `bySkill` (func), `save` (func)
- `InboundAttachment`: `let error: String`, `let filename: String`, `let saved: Bool`, `let size: Int64`
- `InboundMessage`: `let attachments: ArrayList<InboundAttachment>`, `let from: String`, `let receivedAt: String`, `let subject: String`, `let unread: Bool`
- `IndividualityExtractor`: `func extract(jsonobj: JsonObject, overwriter: (String, String) -> Unit)`, `prop systemPrompts: String`, `prop userPrompts: String`
- `JitTicktockTask`: `create` (func)
- `Knowledge`: `let codeLang!: String =`, `let embedding!: Array<Float64>`, `let entire!: Bool = false`, `let md5!: String =`
- `KnowledgeChunker`: `split` (func)
- `KnowledgeEntity`: `queryConf` (func), `func save(knowledgeSaver!: (Knowledge) -> Unit): ArrayList<String>`
- `KnowledgeIndexRebuilder`: `rebuild` (func), `rebuildAll` (func)
- `KnowledgeParam`: `let embeddingWeight!: Float64 = 0.7`, `let keywords!: String`, `let maxResults!: Int64 = 10`, `let minConfidence!: Float64 = 0.8`
- `KnowledgeSearch`: `occurrences` (func), `rank` (func), `terms` (func)
- `LLM`: `getStreamTransport` (func), `getTransport` (func)
- `LLMCandidateProvider`: `setSupplier` (func)
- `LLMConf`: `prop conf: HashMap<String, String>`, `prop isPlaceholder: Bool`, `option` (func), `optionBool` (func), `optionInt` (func), `setConf` (func), `prop streamable: Bool`, `prop tokenThreshold: Int64`
- `LLMConfCodec`: `fromColumn` (func), `toColumn` (func)
- `LLMConfServiceImpl`: `clear` (func), `findById` (func), `func listEnabled(): ArrayList<LLMConf>`, `save` (func)
- `LLMConfView`: `let actualLlmName: String`, `let alwaysThinking: Bool`, `let auth: String`, `llmUrl` (let), `let provider: String`, `let temperature: Float64`, `let weight: Int64`
- `LLMConfig`: `a2aEnabled` (func), `channelSendRoots` (func), `channelsJson` (func), `getBalanceLowThreshold` (func), `getConfRefreshInterval` (func), `getConfSource` (func), `getCooldownDuration` (func), `getEmbeddingRetries` (func), `getEmbeddingTimeoutMs` (func), `getEmbeddingUrl` (func), `getFailureThreshold` (func), `static func getFaithfulMemoryPath(): Path`, `getFetchMaxBytes` (func), `static func getFileSandboxPath(): Path`, `getIndexRebuildNamespace` (func), `getIndexRebuildUserId` (func), `static func getLLMAccessTryingCount(): Int64`, `static func getLLMAccessTryingElapsed(): Duration`, `getLoadBalanceAlgo` (func), `static func getMakingMemory(): Bool`, `getMemoryUserId` (func), `getPrunerLlmName` (func), `getStreamIdleTimeout` (func), `getStreamMaxLineBytes` (func), `static func getSummarisingActionKind(): String`, `getSummarisingLlmName` (func), `static func getSummarisingModel(): String`, `getToolResultMaxBytes` (func), `isAuto` (func), `isDatabaseEnabled` (func), `isIndexRebuildEnabled` (func), `loomOnNoUsable` (func), `supervisorEnabled` (func)
- `LLMConfs`: `holder` (func), `isConfigured` (func), `setHolder` (func)
- `LLMConfsHolder`: `ensureFresh` (func), `getTokenThreshold` (func), `isCircuitOpen` (func), `peekNext` (func), `recordRetryableFailure` (func), `recordSuccess` (func), `refreshNow` (func), `saturated` (func)
- `LLMConfsSnapshot`: `let byId: HashMap<Int64, LLMConf>`, `let byName: HashMap<String, ArrayList<LLMConf>>`, `let loadedAt: MonoTime`
- `LLMErrorClassifier`: `isFatal` (func), `isRetryable` (func)
- `LLMHooks`: `let onRetryableFailure: (Int64) -> Unit`, `let onSuccess: (Int64) -> Unit`
- `LLMToolParams`: `func addFunction(function: FunctionCall): Unit`, `addFunctions` (func)
- `LoomA2a`: `defaultCard` (func), `server` (func), `startIfEnabled` (func)
- `LoomAgent`: `compile` (func)
- `LoomBootstrap`: `storeFor` (func)
- `LoomCharacterScope`: `install` (func)
- `LoomCompiler`: `compileStep` (func), `compileSteps` (func), `jitSourceOf` (func), `llmSourceOf` (func), `toolSourceOf` (func)
- `LoomContextLog`: `MAX_TURNS` (let), `begin` (func), `clear` (func), `isActive` (func), `snapshot` (func)
- `LoomFlow`: `mark` (func), `var planJson: String =`, `var questionsJson: String =`, `var round: Int64 = 0`
- `LoomHostApi`: `bind` (func), `callLlm` (func), `callStore` (func), `callTool` (func), `clearPersona` (func), `clearSkills` (func), `currentPersonaText` (func), `currentSkillsText` (func), `installStore` (func), `render` (func), `resetStore` (func), `setPersona` (func), `setSkills` (func), `taskEvent` (func), `unbind` (func), `valueOf` (func)
- `LoomJitBridge`: `install` (func)
- `LoomMemoryExtractor`: `extract` (func)
- `LoomMemoryPolicy`: `effective` (func), `install` (func)
- `LoomProgram`: `stepCount` (prop)
- `LoomRegistry`: `compiledFlows` (func), `restore` (func), `size` (func)
- `LoomRequest`: `answers` (let), `let dryRun: Bool`, `onUnresolved` (let)
- `LoomResult`: `needsClarification` (prop), `let planJson: String`
- `LoomRunner`: `runCompiled` (func), `topologicalOrder` (func)
- `LoomSchedules`: `install` (func)
- `LoomServices`: `currentHost` (func), `install` (func), `installHost` (func)
- `LoomStatus`: `valid` (func)
- `LoomWiring`: `evolutionOwner` (func), `lastReload` (func)
- `McpClientAdapter`: `callTool` (func), `listAllTools` (func)
- `McpFunctionCalling`: `definition` (prop)
- `Memory`: `remember` (func)
- `MemoryExtractor`: `func extract(json: JsonObject, overwriter: (String, String) -> Unit): Unit`, `prop systemPrompts: String`, `prop userPrompts: String`
- `MemoryIndexRebuilder`: `rebuild` (func), `rebuildIfConfigured` (func)
- `MemoryKinds`: `static let DOC =`, `EXPERIENCE` (let), `EXPERIENCE_FAILED` (let), `static let FACT =`, `static let KNOWLEDGE =`, `static let NOTE =`, `static let PREFERENCE =`, `static let SESSION =`, `static let TASK =`, `attach` (func), `predefined` (func), `resetForTest` (func), `seed` (func), `weightOf` (func)
- `MemoryLoomStore`: `save` (func)
- `MemoryQuery`: `let kinds: Array<String>`, `let namespaces: Array<String>`, `rerank` (let)
- `MemoryRecorderTask`: `recordWithTimeout` (func)
- `MemoryRepositoryAdapter`: `colbert` (func), `searchDense` (func), `searchSparse` (func), `upsertColbert` (func), `upsertSparse` (func)
- `ModelCapabilities`: `blocksTemperature` (func), `resolve` (func)
- `ModelNames`: `isFlash` (func)
- `MySqlEvolutionLease`: `ensure` (func), `ensureSchema` (func)
- `MySqlEvolutionStateStore`: `ensureSchema` (func), `lastRunAt` (func), `markKnowledge` (func), `markRun` (func), `save` (func)
- `MySqlEvolutionStore`: `bySkill` (func), `ensureSchema` (func), `save` (func)
- `MySqlKindPersistence`: `allCustom` (func), `deleteCustom` (func), `has` (func), `insert` (func), `insertCustom` (func)
- `MySqlLoomStore`: `save` (func)
- `MySqlMemoryRepository`: `colbert` (func), `searchDense` (func), `searchSparse` (func), `upsertColbert` (func), `upsertSparse` (func)
- `MySqlTokenUsageSaver`: `saveTokenUsage` (func)
- `OptionDto`: `var label: String =`, `var value: String =`
- `OutboundAttachment`: `let filename: String`
- `OutboundMessage`: `let attachments: ArrayList<OutboundAttachment>`, `let html: String`, `let subject: String`, `let to: String`
- `Parameters`: `func addProperty(name!: String, `type`!: String, description!: String): Unit`, `addRequired` (func)
- `PlanDto`: `var assumptions: ArrayList<AssumptionDto> = ArrayList<AssumptionDto>()`, `var notes: String =`, `var round: Int64 = 0`
- `Planner`: `parse` (func)
- `PlannerResult`: `let assumptions: ArrayList<String>`, `isPlanned` (prop), `let round: Int64`
- `PostgresEvolutionLease`: `ensure` (func), `ensureSchema` (func)
- `PostgresEvolutionStateStore`: `ensureSchema` (func), `lastRunAt` (func), `markKnowledge` (func), `markRun` (func), `save` (func)
- `PostgresEvolutionStore`: `bySkill` (func), `ensureSchema` (func), `save` (func)
- `PostgresKindPersistence`: `allCustom` (func), `deleteCustom` (func), `has` (func), `insert` (func), `insertCustom` (func)
- `PostgresLoomStore`: `save` (func)
- `PostgresMemoryRepository`: `colbert` (func), `searchDense` (func), `searchSparse` (func), `upsertColbert` (func), `upsertSparse` (func)
- `PostgresTokenUsageSaver`: `saveTokenUsage` (func)
- `PredefinedCharacters`: `isKnown` (func), `static func keys(): ArrayList<String>`
- `PromptCapabilities`: `render` (func)
- `QuestionDto`: `var blocking: Bool = true`, `var defaultValue: String =`, `var options: ArrayList<OptionDto> = ArrayList<OptionDto>()`, `var question: String =`, `var why: String =`
- `ReceivedAttachment`: `let filename: String`, `let read: () -> Array<Byte>`, `let size: Int64`
- `ReceivedMail`: `let attachments: ArrayList<ReceivedAttachment>`, `let from: String`, `let receivedAt: String`, `let subject: String`, `let unread: Bool`
- `Redactor`: `defaultKeys` (func), `mask` (func), `redactJson` (func)
- `ReloadResult`: `var restored: Int64 = 0`, `toString` (func)
- `ResponseFormat`: `static let json: ResponseFormat = ResponseFormat(             )`
- `ResponsesMapper`: `build` (func), `parse` (func)
- `ResponsesStreamAccumulator`: `feed` (func), `finished` (prop), `isDone` (func)
- `RetrievalEval`: `defaultDir` (func), `evaluate` (func), `readCases` (func), `readCorpus` (func)
- `RetrievalEvalRunner`: `loadCorpus` (func), `titleToId` (func)
- `RetrievalScoring`: `LEXICAL_CAP` (let), `LEXICAL_WEIGHT` (let), `MEMORY_DENSE_WEIGHT` (let), `MEMORY_SPARSE_WEIGHT` (let), `RERANK_CONTENT_WEIGHT` (let), `RERANK_TITLE_WEIGHT` (let), `fuseKnowledge` (func), `fuseMemory` (func), `rerank` (func)
- `SendReceipt`: `let error: String`, `let messageId: String`, `let ok: Bool`, `success` (func)
- `SignUtil`: `hmacSha256` (func), `hmacSha256Hex` (func), `sha256Hex` (func), `utcDate` (func), `utcDateTime` (func)
- `SiliconFlowBalanceQuerier`: `prop provider: String`
- `SiliconFlowDialect`: `decorate` (func), `endpoint` (func), `headers` (func), `prop provider: String`
- `Skill`: `prop functionNames: Iterator<String>`
- `SkillAssignment`: `let experiences: ArrayList<ExperienceItem>`
- `SkillCandidate`: `let experiences: ArrayList<ExperienceItem>`
- `SkillCatalog`: `install` (func), `isVectorized` (func)
- `SkillEvolutionJob`: `installSink` (func), `ownedBy` (func), `resetSink` (func)
- `SkillEvolutionLedger`: `write` (func)
- `SkillEvolutionPolicy`: `let cooldownSeconds: Int64`, `decide` (func), `let failedCooldownSeconds: Int64`, `let minSamples: Int64`, `let minSuccessRate: Float64`
- `SkillEvolutionReport`: `let candidateClusters: Int64`, `let evolved: ArrayList<String>`, `materials` (let), `let rejected: ArrayList<String>`, `let skipped: ArrayList<String>`
- `SkillEvolutionTask`: `evolve` (func)
- `SkillGate`: `evaluate` (func)
- `SkillGateResult`: `let newScore: Float64`, `let oldScore: Float64`, `let passed: Bool`, `let reason: String`
- `SkillImporter`: `importInto` (func), `parse` (func)
- `SkillMatchResult`: `assignedCount` (prop), `let assignments: ArrayList<SkillAssignment>`
- `SkillMatcher`: `assign` (func)
- `SkillNamer`: `propose` (func)
- `SkillReferenceParam`: `var reference: ArrayList<String> = ArrayList<String>()`
- `SkillSample`: `let expect: String`
- `SkillSamples`: `of` (func)
- `Specification`: `let codeLang!: String =`, `let projectId!: Int64`
- `SsrfGuard`: `blocked` (func), `check` (func), `hostOf` (func)
- `StandardDialect`: `decorate` (func), `endpoint` (func), `headers` (func), `prop provider: String`
- `StepDto`: `var external: Bool = false`
- `StepPlan`: `var external: Bool = false`, `func toJson(): String`
- `StoreSettings`: `let contentStoreUrl: String`, `deprecated` (let), `memoryStore` (let), `let metaStore: String`, `let metaStorePath: String`
- `Stores`: `containsContent` (func), `containsMeta` (func), `resetForTest` (func)
- `Supervisor`: `eventName` (func), `install` (func), `tap` (func), `untap` (func)
- `SupervisorAgent`: `map` (func)
- `TencentCloudBalanceQuerier`: `provider` (prop)
- `TencentSigner`: `headers` (func)
- `TextClip`: `clip` (func)
- `ThinkingPolicy`: `apply` (func)
- `TicktockScheduler`: `cancel` (func)
- `TimeUuid`: `create` (func), `dayOf` (func), `timestampOf` (func)
- `Todo`: `predecessor` (func)
- `TodoFunction`: `func addTodo(param: TodoSavingParam): FunctionResult`, `func todoList(param: TodoListParam): FunctionResult`, `func updateStatus(param: TodoStatusParam): FunctionResult`
- `ToolCallMessage`: `func addFunctionCall(id!: String, toolType!: ToolType, name!: String, arguments!: String)`, `addToolCall` (func)
- `ToolCatalog`: `entries` (func)
- `ToolScope`: `check` (func), `verifyPlan` (func)
- `TopicStat`: `let hitAt1: Int64`, `let hitAtK: Int64`, `mrr` (func), `ndcg` (func), `let ndcgSum: Float64`, `recallAt1` (func), `recallAtK` (func), `let reciprocalSum: Float64`, `let topic: String`, `let total: Int64`
- `VectorMath`: `cosine` (func)
- `VolcSigner`: `headers` (func)
- `VolcengineBalanceQuerier`: `provider` (prop)
- `VolcengineDialect`: `decorate` (func), `endpoint` (func), `headers` (func), `prop provider: String`
- `ZhipuBalanceQuerier`: `prop provider: String`
- `ZhipuDialect`: `decorate` (func), `endpoint` (func), `headers` (func), `prop provider: String`
