# f_llm

A large-model engineering library for Cangjie, part of the [fountain](../) repository. Six capabilities:

| Capability | Entry point |
|---|---|
| Model access (multi-provider, candidates, circuit breaking, streaming) | `fountain::f_llm.llm.LLM` |
| Storage (content / metadata / evolution families) | `fountain::f_llm.store.Stores` |
| Memory, knowledge, skills, personas, prompts | `MemoryStore` / `KnowledgeStore` / `MetaStore` |
| loom orchestration (text → flow → execution) | `fountain::f_llm.loom.LoomWiring` |
| Skill evolution (experience → skill, with A/B gate) | `fountain::f_llm.loom.SkillEvolutionJob` |
| Retrieval quality evaluation | `fountain::f_llm.loom.RetrievalEvalRunner` |

- Version: `1.3.17`, `output-type = "dynamic"`
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
├── loom/           flow orchestration, store gateway, skill evolution, retrieval evaluation
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

Built-in tools:

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
FLLM_DB_TEST=1 cjpm test  # also run postgres / mysql integration tests
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

---

## Known limitations (summary)

| Item | Note |
|---|---|
| Configuration is read-only | Read once at startup; switching stores or endpoints requires a restart |
| Encoder failures degrade silently | `SkillCatalog` falls back to keywords; use `embedFailureDetail()` to see which path ran |
| Rebuild is a full scan | Rebuilding the inverted index is O(records); prefer off-peak |
| `processedKnowledge` is capped | Only for operations/diagnostics; dedupe uses `processedAmong`, which is unbounded in history |
| Scheduling is per process | `SkillEvolutionJob.schedule` registers in-process; cross-process exclusion relies on the daily lease |
