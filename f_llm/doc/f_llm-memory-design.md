# f_llm：知识接入、记忆、人设与流程编排设计

> 版本 v0.1 ｜ 2026-10-28 ｜ 状态：设计待评审
>
> 本文是原 `docs/向量知识库模块设计.md`（v0.4）**拆分后的第一部分**；拆分完成后**原文档已删除**，
> 章节去向保留在 §0 以便追溯。本文只负责「文档 → Markdown → BGE-M3 向量 → 业务侧 API（记忆 / 人设 / 工具 / 编排）」。
> 向量怎么存、怎么索引、怎么检索见 `../fhydra/doc/fhydra-design.md`（第二部分）。

---

## 0. 拆分映射

| 原文档 v0.4 章节（文档已删除，仅作追溯） | 去向 |
|---|---|
| §1.1 `f_store` 能力、§5 存储、§6 索引、§9 检索性能 | **第二部分** `../fhydra/doc/fhydra-design.md` |
| §1.2 仓颉标量性能 | 第二部分（作为 fhydra 的实现依据） |
| §1.3 仓颉生态能力盘点 | 第一部分 §3（决定 pandoc/PDF 工具链） |
| §7 文档解析（pandoc / pdftotext） | **第一部分 §3** |
| §8 导入管线 | 第一部分 §3.4（分块 + 幂等） |
| §10 toolcall API | 第一部分 §8（并扩展为记忆/人设/编排工具） |
| §3 三路向量用法 | 第一部分 §4（embedding 侧）+ 第二部分 §2（索引侧） |
| 新增需求 1–12 | 第一部分 §5–§13 |

---

## 1. 需求映射

| # | 需求 | 落点 |
|---|---|---|
| 0 | 源设计拆两部分；part1 在 f_llm、part2 为 fhydra 可执行模块 | 本文 + `../fhydra/doc/fhydra-design.md` |
| 1 | f_llm 建表 SQL 收敛到 `tables-pg.sql` / `tables-mysql.sql` | §6 + 两个 DDL 文件 |
| 2 | 记忆通用 API + 5 实现（内存/文件/pg/mysql/fhydra） | §5 |
| 3 | 记忆按用户 ×（工作空间 | 全局）分层 | §5.2 |
| 4 | pg/mysql 用 BGE-M3 的稠密/稀疏/多头三路向量；MySQL 最新版 + 向量插件 | §4、§6.3、§11（安装与验证时机） |
| 5 | 标题、正文分别建向量索引 | §6.3（`title_dense` / `content_dense` 两套） |
| 6 | 记忆表结构（修正草案）+ 一个调用记忆 API 的 tool_call | §6.1、§8.1 |
| 7 | 文件记忆按用户+工作空间/全局分目录 | §5.3 |
| 8 | 人设 API + 表 + 5 实现 + 13 个预定义人设；首条 system 消息不裁剪 | §7 |
| 9 | `loom` 包：文本 → ClosureTask/Flow → JIT；预览确认；执行/删除 tool_call | §9 |
| 10 | 技能 zip → skills 表记录；脚本改 tool_call/MCP/JIT；导入 tool_call | §10 |
| 11 | `f_ticktock` 增加 f_jit 依赖 + `JitTicktockTask`；f_llm 定时任务工具 | §11 |
| 12 | `callWithTimeout`：超时返回 `{}` 并取消被调工具 | §8.6 |

> 提示词设计说明：本机没有名为 `prompt-engineering-export` 的技能，实际使用可用的
> `prompt-engineering-expert`（角色边界 + 硬约束 + 输出格式 + 反模式检查 + 可评测的结构）完成，
> 全部提示词固化在代码常量里（§12）。

---

## 2. 总体架构

```
┌──────────────────────────── f_llm ─────────────────────────────┐
│                                                                │
│  知识接入           记忆/人设            编排/工具              │
│  ┌─────────┐      ┌──────────┐        ┌──────────────┐         │
│  │ Parser  │      │ Memory   │        │ loom         │         │
│  │ pandoc  │─分块─▶│ Service  │◀──────▶│ Planner      │         │
│  │ pdftotext│     │ Character│        │ CodeGen      │         │
│  └────┬────┘      └────┬─────┘        │ JitRunner    │         │
│       │                │              └──────┬───────┘         │
│  ┌────▼────────────────▼─────────────────────▼───────┐         │
│  │ 存储抽象：MemoryStore / CharacterStore / VectorStore│        │
│  └───┬─────────┬──────────┬──────────┬───────────┬───┘         │
│      │         │          │          │           │             │
│   InMemory   File(f_store) Postgres  MySQL      Fhydra(HTTP)    │
│                                                                │
│  Embedding 门面（BGE-M3 /v1/embeddings）→ dense / sparse / colbert│
└────────────────────────────────────────────────────────────────┘
                                  │ HTTP
                    ┌─────────────▼──────────────┐
                    │ fhydra（f_store + f_mvc）  │
                    └────────────────────────────┘
```

**依赖方向**：`f_llm → (f_store|f_orm|f_mcp|f_concurrent|f_ticktock|f_jit|f_egraph)`；
`fhydra → (f_store, f_mvc)`，**不反向依赖 f_llm**。

---

## 3. 文档接入（Part 1 的「上半段」）

### 3.1 支持格式（沿用 v0.4 定稿）

| 格式 | 处理 |
|---|---|
| `docx` `pptx` `xlsx` `html` `rtf` `epub` `odt` `csv` `tsv` | `pandoc -f <fmt> -t gfm --wrap=none` |
| `txt` `md` | 直读（`md` 保留标题层级） |
| `pdf` | `pdftotext -layout -enc UTF-8`，质量不合格回退 `mutool draw -F txt -dehyphenate` |
| `doc` `ppt` `xls` `wps` `et` `dps` | **明确报错**，提示另存为 docx/pdf |

依赖探测：启动时执行一次 `pandoc --version` / `pdftotext -v` / `mutool -v`，缓存能力表；pandoc < 3.1 时禁用 pptx/xlsx（docx 仍可用）。

### 3.2 接口

```cangjie
public interface DocumentParser {
    func supports(ext: String): Bool
    func parse(path: String): ParsedDoc
}

public class ParsedDoc {
    public let title: String
    public let markdown: String
    public let blocks: ArrayList<DocBlock>   // 按标题层级切好的块
    public let metadata: HashMap<String, String>
}

public class DocBlock {
    public let headingPath: String   // "H1 > H2"
    public let text: String
}
```

`PandocParser` 负责外部进程调用：`spawn` + 60s 超时 + 非零退出码转 `DocumentParseException`；
输出为空或 < 32 字直接失败（不写空文档）。

### 3.3 PDF 质量判定（沿用 v0.4 §7.3）

| 信号 | 阈值 | 动作 |
|---|---|---|
| 每页平均字数 | < 50 | 失败：疑似扫描件，提示需要 OCR |
| 非可打印字符占比 | > 10% | 失败：字体编码缺失，换工具无效 |
| 平均行长 < 8 字且行数异常多 | —— | 回退 `mutool` |
| 连续重复行 ≥ 3 次 | —— | 清洗页眉页脚 |

### 3.4 分块与幂等

- 先按标题层级切（`#` / `##`），长段再按 512 字窗口 + 64 字重叠；
- 表格行单独成块，保留表头；
- `chunkId = md5(docId + 序号 + 正文前 64 字)`，内容不变则 id 不变；
- 重新导入同一文档：先按 `docId` 删旧块，再写新块（幂等）；
- 单块正文 > 32KB 时按语义段落拆分（避免 payload 超过 fhydra 的 64KB 限制）。

---

## 4. BGE-M3 接入（三路向量）

### 4.1 服务契约

本地部署脚本见 `f_llm/deploy_bge_m3.sh`，默认 `http://127.0.0.1:8000`：

```
POST /v1/embeddings  {"input": ["文本", …]}
→ {"data":[{"embedding":[1024 floats]}], "usage":{…}}
```

当前脚本只返回 **dense**。三路向量需要扩展服务端：

| 向量 | 来源 | 服务端扩展 |
|---|---|---|
| dense | CLS + L2 | 已实现 |
| sparse | BGE-M3 `lexical_weights`（token→weight） | 新增 `"return_sparse": true`，返回 `{token_id: weight}` |
| colbert | 每 token 向量（`token_embeddings`） | 新增 `"return_colbert": true`，返回 `[[1024 floats], …]`，默认截断 96 token |

**兼容策略**：服务端未返回 sparse/colbert 时，客户端降级为「只用 dense」并记 `warn`，不阻塞写入。
降级状态写入 `llm_memory_vector.has_sparse/has_colbert`，检索时按列是否为空决定是否参与融合。

### 4.2 客户端

```cangjie
public class BgeM3Client {
    public init(baseUrl!: String, timeout!: Duration = Duration.second * 60, batchSize!: Int64 = 32)
    public func embed(texts: ArrayList<String>, sparse!: Bool = true, colbert!: Bool = false): ArrayList<EmbeddingTriple>
    public func health(): Bool
}

public class EmbeddingTriple {
    public let dense: Array<Float32>
    public let sparse: HashMap<Int64, Float32>     // tokenId → weight
    public let colbert: Array<Array<Float32>>      // 可空
}
```

- 批量 32 条/次，失败按条重试 1 次（避免一条坏文本拖垮整批）；
- 超时 60s；连续 5 次失败触发 60s 熔断（复用 `CircuitBreaker`）；
- 标题与正文**分别**调用（需求 5），一次请求内用 `input: [title, content]` 两元素，省一次往返。

---

## 5. 记忆 API（需求 2/3/7）

### 5.1 模型与接口

```cangjie
public enum MemoryScope {
    | Global
    | Workspace(String)     // 工作空间 id
}

public class MemoryRecord {
    public let id: Int64
    public let userId: Int64
    public let scope: MemoryScope
    public let title: String
    public let content: String
    public let kind: String            // 字符串；预定义见 §5.4，可运行期扩展
    public let saveTime: DateTime
    public let metadata: HashMap<String, String>
}

public class MemoryWrite {
    public let userId: Int64
    public let scope: MemoryScope
    public let title: String
    public let content: String
    public let kind: String = "note"
}

public class MemoryQuery {
    public let userId: Int64
    public let scopes: Array<MemoryScope>     // 全局 + 当前工作空间通常一起查
    public let text: String
    public let topK: Int64 = 5
    public let rerank: Bool = true
    public let kinds: Array<String> = []
}

public interface MemoryStore <: Resource {
    func add(write: MemoryWrite): MemoryRecord
    func update(record: MemoryRecord): Bool
    func remove(userId: Int64, id: Int64): Bool
    func get(userId: Int64, id: Int64): ?MemoryRecord
    func list(userId: Int64, scope: MemoryScope, offset!: Int64 = 0, limit!: Int64 = 20): ArrayList<MemoryRecord>
    func search(query: MemoryQuery): ArrayList<MemoryHit>
    func stats(): MemoryStats
}
```

`MemoryService` 负责「向量化 + 选 store」，`MemoryStore` 只负责存取；两者分离，换存储不改业务。

### 5.2 分层规则

| 维度 | 取值 | 说明 |
|---|---|---|
| 用户 | `user_id` | 所有查询必带，跨用户不可见 |
| 工作空间 | `scope = Workspace(id)` | **只在该工作空间可见** |
| 全局 | `scope = Global` | 该用户所有工作空间可见 |

默认检索顺序：先查 `Workspace(当前)` 再查 `Global`，两路结果按分数合并；**不跨用户**，**不跨工作空间**。
写入时 `scope` 必填，工具层默认写当前工作空间，显式 `scope="global"` 才写全局。

### 5.3 五个实现

| 实现 | 存储 | 向量 | 适用 |
|---|---|---|---|
| `InMemoryMemoryStore` | `ConcurrentHashMap` | 内存暴力扫 | 单测、演示 |
| `FileMemoryStore` | `f_store`，路径 `{root}/{userId}/{namespace}/` | 落盘 + 内存索引重建 | 无数据库的单机部署 |
| `PostgresMemoryStore` | `llm_memory` + 向量表（pgvector） | dense HNSW + sparse 倒排 + colbert 重排 | 生产（PG/OpenGauss） |
| `MySqlMemoryStore` | 同结构（MySQL 9.2+ `VECTOR` + `VECTOR INDEX`） | 同上；无索引时降级内存暴力扫 | 生产（MySQL/MariaDB） |
| `FhydraMemoryStore` | HTTP 调 `fhydra` | 全部在 fhydra 内 | 生产（解耦部署） |

文件布局（需求 7）：

```
{memory_path}/{userId}/global/{id}.json
{memory_path}/{userId}/ws-{workspaceId}/{id}.json
{memory_path}/{userId}/{ns}/index.meta        # 版本 / 条目数
```

`namespace` 编码：`global` 或 `ws-{id}`，与 SQL 的 `namespace` 列一致。

> OpenGauss 走 `PostgresMemoryStore`（`orm_drivers` 配 `opengauss`，SQL 与 PG 同构）；MariaDB 走 `MySqlMemoryStore`（驱动换 `mariadb`）。

### 5.4 `kind`：字符串 + 预定义不可删 + 自定义归属用户

`kind` 是**普通字符串列**（`varchar(32)`），不是数据库枚举——枚举会让「运行期新增类型」必须改 DDL，与需求矛盾。

```cangjie
public class MemoryKinds {
    public static let NOTE = 'note'
    public static let FACT = 'fact'
    public static let PREFERENCE = 'preference'
    public static let TASK = 'task'
    public static let DOC = 'doc'
    public static let KNOWLEDGE = 'knowledge'
    public static let SESSION = 'session'

    public static func predefined(): ArrayList<String>                  // 上面 7 个，顺序固定、全局共享
    public static func all(userId: Int64): ArrayList<String>            // 预定义 + 该用户自定义
    public static func register(userId: Int64, kind: String): Bool      // 归属该用户；已存在返回 false
    public static func remove(userId: Int64, kind: String): Bool        // 预定义或他人 kind 均拒绝
    public static func validate(userId: Int64, kind: String): Bool      // 写入前的校验入口
}
```

**运行期增删（自定义 kind 归属用户）**：

| 操作 | 语义 |
|---|---|
| `register(uid, "meeting")` | 新增该用户的自定义类型；落库 `llm_memory_kind(user_id=uid, predefined=false)`，重启后仍在 |
| `remove(uid, "meeting")` | 只删**自己**的自定义类型；已有记忆不删，但再写入该 kind 会被 `validate` 拒绝 |
| `remove(uid, "note")` | **拒绝**：`IllegalArgumentException('predefined memory kind cannot be removed: note')` |
| `remove(otherUid, "meeting")` | **拒绝**：跨用户删除视为不存在，返回 `false`（不泄露他人是否定义过） |
| `register(uid, "note")` | 返回 `false`（预定义已存在，幂等） |

**持久化与启动**：

- 预定义 7 值**固化在代码里**（`MemoryKinds.predefined()` 是唯一权威），同时启动时幂等写入库表（`user_id = 0` 代表全局）；
- 种类表 `llm_memory_kind` 以 `(user_id, kind)` 为主键（§6.1），预定义行 `user_id=0`；
  即使库里的预定义行被手工删掉，下次启动也会补回；
- 文件实现把种类清单存 `{memory_path}/{userId}/kinds.json`（预定义不落盘），内存实现只保留进程内清单——
  **五个实现的语义必须一致**，用同一套 conformance 用例校验。

**与检索的关系**：`MemoryQuery.kinds` 过滤时按 `(userId, kind)` 先 `validate` 再下推；未知 kind 返回空结果而不是报错
（查询不该因为拼错一个过滤值就 500），但写入必须报错。

**权重**：每个 kind 带一个 `weight`（0~1，存 `llm_memory_kind.weight`，见 §6.1）。
默认值让「人工写的记忆」优先于「自动记忆」：

| kind | weight | 说明 |
|---|---|---|
| `preference` / `fact` | 1.0 | 用户明确表达的，最可信 |
| `note` | 0.9 | 人工记录 |
| `doc` / `knowledge` | 0.8 | 文档类 |
| `task` | 0.6 | 自动抽取的经验 |
| `session` | 0.3 | 会话流水，量最大、噪声最高 |
| 自定义 | 0.8 | 可改 |

检索打分：`final = normalize(向量分数) × weight`；**先取 `topK × 2` 再乘权重截断**，避免低权重记忆被提前挤掉。

**权重是固定值**：以代码常量为准（与种子行一致），**不提供按请求、按 collection、按用户的覆盖**。
调权重属于改代码 + 改种子 SQL，不做运行期配置——避免「同一个库在不同请求下排序不同」这种不可复现的问题。

**新增的两个预定义 kind 的含义**（自动记忆，见 §5.5）：

| kind | 含义 | 写入方 |
|---|---|---|
| `task` | 任务执行过程与结果的结构化摘要、经验 | `MemoryRecorderTask` 在任务结束时自动抽取 |
| `session` | 与用户的会话历史（按会话归并、去重、滚动摘要） | `MemoryRecorderTask` 每轮自动追加 |

### 5.5 自动记忆：`MemoryRecorderTask`（`f_egraph.Task`）

会话历史与任务执行历史**不靠人写**：`AgentTask` 每执行一步、每完成一轮对话就发一个事件，
由一个忠实的异步 Task 落库；任务结束时再发 `task.end`，由它抽取摘要/经验/偏好。链路与主流程解耦，记录失败不影响回答。

```cangjie
@JitBind
public class MemoryRecorderTask <: Task {
    public prop name: String { get() { 'memory-recorder' } }
    public prop acceptableEvents: Array<String> { get() { ['llm.turn', 'task.step', 'task.end'] } }
    public prop producingEvents: Array<String> { get() { ['memory.recorded'] } }
    public func exec(e: Event): Event     // 只做入队，立即返回，不阻塞调用方
}
```

**事件契约**：

| 事件 | payload | 触发点 |
|---|---|---|
| `llm.turn` | `{userId, session, workspace, role, content, time}` | `AgentTask` 每轮对话结束 |
| `task.step` | `{userId, session, taskName, stepId, tool, input, output, ok, time}` | 每执行一步 |
| `task.end` | `{userId, session, taskName, outcome}` | 任务结束 / 流程 `End` |

**处理规则**（异步消费，按事件顺序单线程处理同一 session，避免并发写同一行）：

| 事件 | 处理 |
|---|---|
| `llm.turn` | 追加到 `session` 记忆（`title = "session:{sessionId}"`），按 `hash(role+content+turnIndex)` 去重；超过 32K 字滚动摘要（保留最近 N 轮 + 旧摘要） |
| `task.step` | 只落 `llm_memory_event`（忠实历史，不直接生成记忆） |
| `task.end` | 取该 task 的全部 step 事件 + 会话片段 → `MEMORY_EXTRACT_PROMPT` → 生成/更新 `task` 记忆（`title = "task:{taskName}"`），抽取到的用户偏好写 `preference` |

**可靠性**：

- 事件先落 `llm_memory_event`（append-only，`processed=false`），再消费；消费成功置 `processed=true`，失败保留原事件并指数退避重试；
- 事件 id = `hash(userId, session, taskName, stepId/turnIndex)`，重复投递幂等忽略；
- 消费协程独立于请求线程；进程退出时把未消费事件留在表里，下次启动继续；
- **不做确认交互**：`task`/`session` 是自动记忆，写入与更新都不需要用户确认；
  用户/开发者通过开放 API 主动增删改查（`memoryCall` 或直接 `MemoryService`）时，删除也不二次确认（见 §8.1）。

**session 滚动摘要（不设硬上限）**：

- 每个 session 一条 `session` 记忆；每轮追加后检查长度，超过 32K 字触发滚动：
  保留最近 20 轮原文 + 对更早内容生成摘要合并进正文的「摘要」段，旧原文删除；
- **不按条数/天数强制淘汰**：会话历史的价值随时间下降但不设硬阈值，靠 `weight=0.3` 在检索中自然降权。

**task → skill 反哺（三次成技能）**：

- 同类任务判定：`taskName` 相同 **或** 主题相同（与已有经验标题/正文的余弦相似度 ≥ 0.85）；
- 同一 `taskName` 的 task 记忆累计 **≥ 3 条** → 调 `TASK_SKILL_PROMPT`（§12.6）合成技能，写 `skills` 表，
  `metadata = {"promotedFrom":"task:{taskName}","evidence":3}`、`skill_type='auto'`；
- 之后每来一条新的同类 task 记忆：若技能已存在，用同一提示词做**增量更新**（保留原步骤，只补差异），不重复建；
- 技能更新失败不回滚记忆；记忆与技能是弱一致，允许人工编辑覆盖。

**历史表**（§6.1 的 `llm_memory_event`）：事件本体 + 处理状态 + 重试次数，保留 30 天后归档/清理。

### 5.6 时间与时区：存 UTC、算本地

| 环节 | 规则 |
|---|---|
| 持久化 | `save_time` / `update_time` / `event_time` / loom 的 `created_time` 一律 **UTC**，不带本地偏移 |
| API 入参 | 调用方传服务端本地时间或 ISO（带偏移）；服务端统一换算成 UTC 再落库 |
| API 返回 | 统一转成**服务端时区**输出（ISO 带偏移），前端不再做二次换算 |
| 按日过滤 | `save_day` 这类「日」参数按服务端时区解释，内部换算成 UTC 区间（可能跨 1~2 个 UTC 日） |
| 时区来源 | 运行进程的机器时区，可用 `llm_serverTimezone`（如 `Asia/Shanghai`）覆盖 |

**为什么存 UTC**：换机器、换时区、跨地域部署都不会让历史数据失真；本地时区只作为「显示与查询的解释层」。
**代价**：按日聚合要处理区间跨界（一日可能对应两个 UTC 日），已在 fhydra 的 `save_day` 索引里按「取并集」处理。

---

## 6. 表设计（需求 1/4/5/6/8）

### 6.1 `llm_memory`（对草案的两处修正）

```sql
create table llm_memory (
    id          bigint       not null auto_increment,
    user_id     bigint       not null default 0,
    namespace   varchar(32)  not null,             -- 'global' | 'ws-{id}'
    title       varchar(128) not null,
    content     longtext,
    kind        varchar(32)  not null default 'note',   -- 预定义 7 值 + 运行期自定义，见 §5.4
    save_time   datetime     not null default (utc now),   -- 统一 UTC（PG: now() AT TIME ZONE 'utc'；MySQL: UTC_TIMESTAMP()）
    update_time datetime     not null default (utc now),   -- 同上；不依赖数据库会话时区
    primary key (id),
    unique key uk_memory_user_ns_title (user_id, namespace, title),
    key idx_memory_ns_time (user_id, namespace, save_time)
);
```

**修正 1**：草案的 `unique key memory_user(user_id)` 会让一个用户只能存一条记忆，改为
`(user_id, namespace, title)` —— 同一命名空间下按标题幂等覆盖，不同标题可共存。
**修正 2**：补 `kind` / `update_time`，检索和增量同步都需要；`namespace` 承担「工作空间 vs 全局」，不额外加列。
**修正 3**：`kind` 是 `varchar(32)` 而**不是枚举**（§5.4）——预定义 7 值由种类表种子行承载，运行期新增只插一行，不需要改 DDL。

**种类表**（§5.4 的持久化；自定义 kind 归属用户，`user_id = 0` 为全局预定义）：

```sql
create table llm_memory_kind (
    user_id     bigint      not null default 0,
    kind        varchar(32) not null,
    predefined  boolean     not null default false,
    weight      double      not null default 0.8,   -- 检索打分权重 0~1，自动记忆更低
    create_time datetime    not null default (utc now),
    primary key (user_id, kind)
);

-- 启动时幂等补种，预定义行不允许被删除（API 层拒绝，见 §5.4）
insert into llm_memory_kind (user_id, kind, predefined, weight) values
    (0, 'note', true, 0.9), (0, 'fact', true, 1.0), (0, 'preference', true, 1.0),
    (0, 'task', true, 0.6), (0, 'doc', true, 0.8), (0, 'knowledge', true, 0.8),
    (0, 'session', true, 0.3)
on conflict (user_id, kind) do nothing;   -- MySQL: insert ignore into …
```

**历史表**（§5.5 的事件溯源，append-only）：

```sql
create table llm_memory_event (
    id          bigint       not null auto_increment,
    user_id     bigint       not null,
    session     varchar(64)  not null,
    task_name   varchar(64)  not null default '',
    event_type  varchar(32)  not null,        -- llm.turn | task.step | task.end
    step_id     varchar(64)  not null default '',
    payload     text         not null,        -- 事件原始 JSON
    processed   boolean      not null default false,
    retry_count int          not null default 0,
    event_time  datetime     not null,
    primary key (id),
    key idx_event_pending (processed, event_time),
    key idx_event_session (user_id, session, event_time)
);
```

### 6.2 向量与倒排表

```sql
-- 标题与正文各自一套向量（需求 5）
create table llm_memory_vector (
    memory_id      bigint primary key,
    model          varchar(64) not null,
    title_dense    vector(1024),
    content_dense  vector(1024),
    -- colbert：二进制 f32[]，布局 count(Int32 LE) + count*dim*Float32 LE；最多 96 个 token 向量
    title_colbert  bytea,         -- MySQL: LONGBLOB
    content_colbert bytea,
    has_sparse     boolean not null default false,
    has_colbert    boolean not null default false,
    update_time    datetime not null default current_timestamp
);

-- 稀疏向量落地为倒排表（跨库可移植：PG/MySQL/MariaDB/OpenGauss 都能用）
create table llm_memory_token (
    memory_id  bigint      not null,
    user_id    bigint      not null,
    namespace  varchar(32) not null,
    field      char(1)     not null,     -- 't' 标题 / 'c' 正文
    token      bigint      not null,     -- BGE-M3 token id
    weight     float       not null,
    primary key (memory_id, field, token),
    key idx_token_lookup (user_id, namespace, field, token)
);
```

MySQL 版把 `vector(1024)` 换成 `VECTOR(1024)`、`bytea` 换成 `LONGBLOB`、`boolean` 换成 `tinyint(1)`；完整 DDL 见 `f_llm/tables-*.sql`。

**colbert 为什么用二进制而不是 JSON**：同一份数据 JSON 体积约 3 倍，读写都要多一轮解析；二进制布局固定为
`count(Int32 LE) + count × dim × Float32 LE`，x86/aarch64 一致，跨语言只需 `struct.unpack('<i')` + `'<%df'`。
标题与正文各存一份（需求 5 + 标题也要 colbert），重排时两路 max-sim 取加权和。

### 6.3 索引策略（三路向量都用上）

| 向量 | PostgreSQL / OpenGauss | MySQL 9.2+ / MariaDB |
|---|---|---|
| 标题 dense | `create index … using hnsw (title_dense vector_cosine_ops)` | `create vector index … (title_dense) using hnsw` |
| 正文 dense | 同上（`content_dense`） | 同上 |
| 稀疏 | `llm_memory_token` 倒排表 `(user_id, namespace, field, token)` | 同左 |
| 标题 colbert | `bytea` 二进制，命中候选后应用层 max-sim 重排 | `LONGBLOB`，同左 |
| 正文 colbert | `bytea` 二进制，同左 | `LONGBLOB`，同左 |

**为什么稀疏不用 `sparsevec` 索引**：BGE-M3 的稀疏向量是 25 万词表上的稀疏权重，
`sparsevec` 索引维度和非零上限在不同版本行为不一致；倒排表在四种数据库上语义完全一致，
还能直接按 `(user_id, namespace)` 做租户隔离。dense 走 ANN，sparse 走倒排，colbert 只重排——
与源设计 §3 的结论一致。

**降级**：MySQL < 9.2 没有向量索引（9.0/9.1 只有类型，没有 ANN），此时 `MySqlMemoryStore` 自动切
「取候选集 + 应用层暴力算」，并在启动日志里 `warn`；写入与检索结果不变，只是慢。

### 6.4 `llm_character`

```sql
create table llm_character (
    id          bigint      not null auto_increment,
    user_id     bigint      not null default 0,
    character_key varchar(32) not null default 'default',
    prompts     text,                       -- 人设提示词（system）
    update_time datetime    not null default current_timestamp,
    primary key (id),
    unique key uk_character_user (user_id)
);
```

`character_key` 指向预定义人设（§7.2），`prompts` 存最终生效文本（自定义时与 key 无关）。
未落库的用户按 `default` 处理（不注入任何 system 消息）。

### 6.5 其余既有表

`agents` / `skills` / `skill_references` / `memory_summaries` / `agent_todo` / `llm_token_usage` / `llm_conf`
的建表语句一并收进 `tables-pg.sql` / `tables-mysql.sql`（列定义以 `src/model/po` 为准），
`doc/sql/llm_conf.*.sql` 标记为废弃，保留一个版本后删除。

新增表的完整清单（两个文件里都有）：`llm_memory`、`llm_memory_kind`、`llm_memory_event`、
`llm_memory_vector`、`llm_memory_token`、`llm_character`、`llm_loom_flow`。

---

## 7. 人设 API（需求 8）

### 7.1 接口

```cangjie
public class Character {
    public let userId: Int64
    public let key: String        // 预定义 key 或 "custom"
    public let prompts: String
}

public interface CharacterStore <: Resource {
    func get(userId: Int64): ?Character
    func set(userId: Int64, key: String, prompts: String): Character
    func reset(userId: Int64): Bool
}
```

五个实现与记忆同构（内存/文件/PG/MySQL/Fhydra），文件落在 `{memory_path}/{userId}/character.json`。

### 7.2 预定义人设（固化在代码）

`PredefinedCharacters`（`f_llm/src/character/PredefinedCharacters.cj`）提供 13 个条目：
`default`（空）、`rigorous`、`friendly`、`blunt`、`imaginative`、`pragmatic`、`sarcastic`、
`coaching`、`gentle`、`sweet`、`aloof`、`sunny`、`whimsical`。

### 7.3 注入与「压缩也保留」

- `AgentTask` 组装消息时：`character.prompts` 非空 → 作为 **第 0 条 `SystemMessage`** 插入；
- `ContextPrunerMediator.prune` 出口统一加一道 `LeadingSystemGuardPruner`：
  裁剪完成后把原始首条 system 消息贴回首位（若策略已保留则不重复）；
- 用例：所有 8 个既有策略 + `TokenBudget` 在 system 消息存在时，裁剪结果第 0 条仍是该 system。

---

## 8. 工具（tool_call）

命名规则沿用 `ToolName`（`^[A-Za-z0-9_-]{1,64}$`）。

### 8.1 `memoryCall`（需求 6）

```json
{"name":"memoryCall",
 "parameters":{"type":"object","properties":{
   "action":{"type":"string","enum":["save","search","delete","list"]},
   "scope":{"type":"string","default":"workspace","enum":["workspace","global"]},
   "title":{"type":"string"},"content":{"type":"string"},
   "id":{"type":"integer"},"query":{"type":"string"},
   "topK":{"type":"integer","default":5}},"required":["action"]}}
```

- `save`：正文与标题分别 embedding，写当前用户的当前工作空间（`scope=global` 才写全局）；
- `search`：同时查当前工作空间 + 全局，融合后返回 `[{id,title,content,score}]`；
- `delete`：按 id **硬删**，越权（他人 id）返回错误文本，不静默；**不做二次确认**——调用方显式给出 id 即视为确认，
  `task` / `session` 这类自动记忆同样允许手动删除（自动写入本身不需要确认，见 §5.5）；
- `list`：按 `save_time` 倒序分页；`kind` 过滤先按 `(userId, kind)` 校验。

### 8.2 `knowledgeIngest`

`{path | bytes, namespace, docId?}` → 解析 → 分块 → 向量化 → 写 `VectorStore`；
返回 `{docId, chunks, degraded:["sparse"]}`。仅接受白名单扩展名。

### 8.3 `skillImport`（需求 10）

见 §10。

### 8.4 `scheduleCreate` / `scheduleDelete`（需求 11）

见 §11。

### 8.5 `loomExecute` / `loomDelete`（需求 9）

见 §9.7。

### 8.6 `callWithTimeout`（需求 12）

```json
{"name":"callWithTimeout",
 "parameters":{"type":"object","properties":{
   "duration":{"type":"string","description":"如 30s / 5m / 1500ms"},
   "tool":{"type":"string"},
   "arguments":{"type":"object"}},"required":["duration","tool","arguments"]}}
```

语义：`spawn` 执行 `tool`；到点未完成 → 置取消标记、`JitFunction.unload`（若是 JIT 闭包）、
返回 `{}`；正常完成返回 `{"result": <JsonObject>}`。

**取消的边界**（必须在文档里写清，不能假装能强杀）：
仓颉线程不可强杀，取消是**协作式**——工具实现需检查 `CancelToken`；LLM 调用通过关闭流 + `unload` 生效；
不支持取消的工具只能做到「不再等待」，其副作用可能仍会完成。

---

## 9. `loom`：文本 → JIT 流程编排（需求 9）

### 9.1 包结构

```
f_llm/src/loom/
├── Plan.cj            FlowPlan / StepPlan / EdgePlan（JSON 可序列化）
├── Planner.cj         调 LLM 把描述解析成 FlowPlan
├── ToolScope.cj       解析/校验可用 tool/mcp/jit 集合
├── CodeGen.cj         FlowPlan → 仓颉源码（步骤闭包 + 流程闭包）
├── LoomCompiler.cj    两级 JIT 编译 + 诊断
├── LoomRegistry.cj    按 name 保存 pending / compiled 流程（内存 + 持久化）
├── LoomStore.cj       流程定义的落库/恢复（表 llm_loom_flow）
├── LoomRunner.cj      执行、超时、取消
├── Prompts.cj         固化提示词
└── LoomFunctions.cj   loomExecute / loomDelete 两个 tool_call
```

### 9.2 输入

```cangjie
public class LoomRequest {
    public let name: String            // 任务标识，全局唯一
    public let description: String     // 自然语言任务描述
    public let tools: Array<String> = []    // 整个流程可用
    public let mcps: Array<String> = []
    public let dryRun: Bool = true          // 默认只产出闭包，不编译执行
}
```

描述里允许声明：某步用哪个模型（`"第二步用 chat-pro"`）、某步可异步（`"并行"` / `"异步"`）、
整体与单步的 tool/mcp 白名单。

### 9.3 计划 schema（LLM 只产出这一层）

```json
{
  "name": "daily-report",
  "steps": [
    {"id": "fetch", "kind": "tool", "tool": "webSearch",
     "args": {"query": "仓颉 版本"}, "async": "auto"},
    {"id": "sum", "kind": "llm", "model": "chat-pro",
     "system": "你是技术编辑", "input": "${fetch.output}", "async": false},
    {"id": "save", "kind": "tool", "tool": "memoryCall",
     "args": {"action": "save", "title": "日报", "content": "${sum.output}"}, "async": true}
  ],
  "edges": [["fetch", "sum"], ["sum", "save"]]
}
```

**LLM 不生成仓颉代码**——只产出 JSON 计划，代码由 `CodeGen` 模板生成。这是刻意的：
让模型写 `ClosureTask` 语句序列的失败率远高于写结构化计划，且错误只能在编译期暴露。

### 9.4 代码生成（两级 JIT）

1. **步骤级**：每个 step 生成一段语句序列（形参固定 `e: Event`，返回 `Event`），
   交给 `ClosureTask.compile(name, acceptableEvents, producingEvents, exec)`；
   数据通过 `Event.data`（`JsonObject`）传递，模板负责 `${x.output}` 的取值与拼装。
2. **流程级**：生成单个 lambda 源码，形参是宿主对象 `FlowHost`（`Compiler.registerClass` 注册），
   体内按 `edges` 组装 `ImmediateFlow` / `AsyncFlow`（有 async 步骤用后者），
   `registerStart` → `registerTask(host.task("id"))` → `registerEnd`，最后 `host.run(flow, input)`。
   这段源码由 `Compiler().compile(source)` 编译成 `JitFunction`，即「一个流程就是一个 JitFunction」。

**为什么不让流程闭包直接内联步骤源码**：`ClosureTask.compile` 的 `exec` 是字符串，
内联需要嵌套转义（`\"` 套 `\\\"`），可读性和可测性都会崩；两级编译把转义限制在一步之内。

### 9.5 异步决策

优先级：**描述显式标注** > step 的 `async` 字段 > 按 `kind` 推断。

| kind | 默认 | 理由 |
|---|---|---|
| `llm` / `tool` / `mcp` / `http` | async | IO 密集，`AsyncFlow` 可并行 |
| `jit`（纯计算） | sync | 避免线程切换开销 |
| 有副作用且需顺序的步骤（`save`/`delete`） | sync | 显式声明优先 |

### 9.6 预览 → 确认 → 编译

`loomExecute(name, confirm=false)`：

1. 调 `Planner` 得 `FlowPlan`；
2. `CodeGen` 产出：计划 JSON + 每个步骤源码 + 流程源码（**不编译**）；
3. 存入 `LoomRegistry`（状态 `pending`），返回给调用方/开发者；
4. `confirm=true` 时：`Compiler` 编译步骤与流程 → 失败返回诊断（文件:行:列 + 期望 token）→ 成功注册 `compiled` 并可选立即执行。

**编译前返回闭包原文**是硬要求：错误信息要能让开发者直接看出「第几步的哪一行不对」。

### 9.7 两个 tool_call

| 工具 | 参数 | 行为 |
|---|---|---|
| `loomExecute` | `name, description, tools?, mcps?, confirm?` | 生成/编译/注册流程；`confirm=false` 只返回闭包 |
| `loomDelete` | `name` | `JitFunction.unload` + 从注册表移除；正在运行的实例等待结束 |

### 9.8 不访问大模型的流程

`kind: "jit"` 的步骤直接内联语句序列（不调 LLM / tool），整条流程仍然编译为 `JitFunction`，
用于「纯数据加工 / 批量转换」场景；LLM 只参与生成计划，可选。

### 9.9 流程持久化（重启后可执行）

`JitFunction` 不可序列化，所以持久化的是**源码与状态**，重启时重新编译：

```sql
create table llm_loom_flow (
    name          varchar(64) primary key,
    description   text,
    plan_json     text        not null,   -- Planner 产出的计划
    flow_source   text        not null,   -- 流程级 JIT 源码
    step_sources  text        not null,   -- JSON: {"stepId": "<语句序列>"}
    status        varchar(16) not null,   -- pending | compiled | failed
    tools         text,                   -- 逗号分隔的白名单
    mcps          text,
    created_time  datetime    not null default current_timestamp,
    update_time   datetime    not null default current_timestamp
);
```

| 时机 | 动作 |
|---|---|
| `loomExecute(confirm=false)` | upsert `status=pending`，保存计划与源码（此时还没编译） |
| 编译成功 / 失败 | 更新 `status=compiled` / `failed`；诊断只写日志不落库（源码已可复现） |
| 启动 | 载入 `status=compiled` 的行，**重新编译**进 `LoomRegistry`；单条失败标 `failed`，不影响其它流程 |
| `loomDelete` | 先删库再 `JitFunction.unload`，避免重启又加载回来 |

配置 `llm_loomPersist=true`（默认）时启用；关掉则退化为纯内存（仅测试用）。
`status=pending` 的行超过 7 天由后台清理，避免「预览了没确认」的流程越积越多。

---

## 10. 技能包导入（需求 10）

### 10.1 输入

zip 内约定：`SKILL.md`（或 `README.md`）+ 脚本 + 资源文件。

### 10.2 转换规则

| zip 内容 | 转换 |
|---|---|
| 标题/描述 | `skills.title` / `metadata` |
| 触发条件 | `accepted_event`（默认 `next`） |
| 步骤说明 | `details`（Markdown，保留原始结构） |
| `*.sh` / `*.py` / `*.js` | **不得保留**：按语义映射到 `tool_call`（`webSearch`/`webFetch`/`memoryCall`/`currentTime`）或 MCP 工具名；无法映射时报错并列出候选 |
| 纯计算逻辑 | 生成 JIT 闭包源码，登记为 `jit:<name>` |
| 依赖的外部 CLI | 映射为 `tool_call` 包装（若无对应工具则拒绝导入） |

输出是 `skills` 表一行的 JSON（`title/metadata/details/functions/skill_type`），写库走 `SkillsFinder`。

### 10.3 tool_call `skillImport`

`{zipPath | base64, overwrite?}` → 解压到 `{skills_path}/{name}` → LLM 转换 → schema 校验 → 落库 →
返回 `{skillId, functions:[...], rejected:[...]}`；任何脚本残留都会被拒绝。

---

## 11. 定时任务（需求 11）

### 11.1 `f_ticktock` 侧

新增依赖 `fountain::f_jit`，新增类：

```cangjie
@JitBind
public class JitTicktockTask <: CronTicktockTask {
    public init(name!: String, cron!: String, once!: Bool = false,
                concurrentable!: Bool = false, task!: () -> Unit)
    public static func compile(name!: String, cron!: String, once!: Bool = false,
                               concurrentable!: Bool = false, task!: String): JitTicktockTask
    public prop name: String
    public prop cron: String
    public prop once: Bool
    public prop concurrentable: Bool
    public override func execute(): Unit   // 只调用 task()
}
```

**对需求骨架的三处修正**（原骨架编译不过 / 语义有歧义）：

1. `concurrentable_: String` / `once_: String` 与 `prop once: Bool` 类型冲突 → 改为 `Bool`；
2. 两个 `execute()` 重复定义 → 保留一个；
3. `task` 是 `() -> Unit`，而 JIT 闭包 `JitFunction` 不是闭包字面量 → `compile` 内部
   `Compiler().compile(taskSource)` 得到 `JitFunction`，再用宿主持有的
   `{=> jitFn.call<Unit>([]) }` 包装成 `() -> Unit` 注入；`JitFunction` 生命周期挂在任务对象上，
   任务删除时 `unload`。

注册/删除直接用现有 `Ticktock.instance.addOrReplaceTask(task)` / `removeTask(name)`，不新增注册表。

### 11.2 `f_llm` 侧

- 依赖 `f_ticktock`；
- 提示词 `SCHEDULE_PROMPT`：自然语言 → `{name, cron, once, concurrentable, taskSource}`；
- `scheduleCreate`：校验 cron 五段 → `JitTicktockTask.compile` → 注册；
- `scheduleDelete`：`Ticktock.instance.removeTask(name)` → `unload`。

---

## 12. 提示词（全部固化在代码常量）

> 设计原则（prompt-engineering-expert）：角色一句话、硬约束编号、输出格式固定、给反例、
> 不写「尽量/酌情」这类不可判定词；技术准确性优先于人设，人设只影响措辞。

### 12.1 十三个人设（`character/PredefinedCharacters.cj`）

| key | 名称 | 提示词（system 正文） |
|---|---|---|
| `default` | 默认 | （空字符串，不注入） |
| `rigorous` | 专业严谨 | `你是一名严谨的技术专家。回答先给结论，再给依据；术语必须准确，不确定的内容明确标注“不确定”并说明缺什么信息。禁止编造版本号、API 名与数据来源。结构化优先：能用列表/表格就不用长段落。` |
| `friendly` | 亲和友善 | `你是一位亲和、耐心的助手。先用一句话回应用户的感受或目标，再给可执行的建议。语气自然口语化，避免生硬的官方腔；不堆砌敬语，不使用夸张感叹。涉及事实时照常给准确信息。` |
| `blunt` | 直言不讳 | `你说话直接、不绕弯子。先指出问题与结论，再解释原因；该反对时明确反对并给出替代方案。不对错误方案做礼貌性肯定，但只评价方案、不评价人。技术事实优先于措辞委婉。` |
| `imaginative` | 天马行空 | `你擅长发散联想。针对问题给出至少三个非常规思路，用比喻解释关键机制，并标注每个思路的可行性（高/中/低）与主要风险。允许大胆，但必须把“已知事实”和“推测”分开写。` |
| `pragmatic` | 高效务实 | `你追求最短可执行路径。回答控制在必要信息内：先给最小可行步骤，再给可选优化项。不铺陈背景，不重复用户已说的内容。每一步都要能直接执行（命令/代码/参数齐全）。` |
| `sarcastic` | 毒舌吐槽 | `你说话带点毒舌：可以吐槽方案里的明显坑和自欺欺人之处，但只针对方案与现象，不针对个人。吐槽之后必须给出正确的做法。技术信息必须准确，不为了效果牺牲事实。` |
| `coaching` | 启发引导 | `你是一名教练型助手。不直接给答案，先用 1–2 个关键问题帮用户澄清目标与约束，再引导其自己得出结论；用户卡住时给提示而不是完整答案。最后用一句话总结用户的选择与下一步。` |
| `gentle` | 温柔体贴 | `你语气柔和、节奏放慢。先确认用户当前处境，再分小步给建议，每一步说明为什么这样做。遇到困难先共情再解决；不使用命令式口吻。事实与安全性要求不因语气而降低。` |
| `sweet` | 软萌甜妹 | `你说话软萌活泼，适度使用语气词与颜文字，句子短。技术内容保持准确完整，不因萌化而省略关键步骤；不装幼稚，不使用叠词表达专业术语。` |
| `aloof` | 高冷御姐 | `你话少、笃定、不寒暄。直接给结论和必要依据，不解释常识，不主动扩展话题。语气平静克制，不冷淡到无礼；用户追问时再展开细节。` |
| `sunny` | 阳光开朗 | `你积极、明快、有行动力。回答先肯定可做之处，再给步骤；用短句和明确的下一步收尾。鼓励要具体（指出做到了什么），不空喊口号；风险与限制照常说清。` |
| `whimsical` | 鬼灵精怪 | `你机灵、俏皮，喜欢从刁钻角度切入问题。可以用反问、文字梗和“反直觉小实验”勾起兴趣，但每个玩笑后面必须给出准确结论；不装可爱、不卖萌、不油腻。不确定的内容照常标注，技术准确性永远优先于机灵。` |
| `custom` | 自定义 | 用户自定义文本，原样作为 system 消息 |

### 12.2 `MEMORY_EXTRACT_PROMPT`（记忆抽取）

```
从对话片段中抽取值得长期保留的记忆。只保留用户明确表达的偏好、事实、约束与决定；
忽略寒暄、重复内容与助手自己的猜测。

输出 JSON，不要解释：
{"title":"不超过 32 字，能区分同类记忆","content":"不超过 400 字，保留原始措辞与关键数字",
 "kind":"note|fact|preference|task|doc|knowledge|session"}

判定规则：
1. 用户说“以后都/不要再/记住” → kind=preference 或 fact；
2. 任务执行过程与结论、可复用的经验 → kind=task（title 用任务名）；
3. 会话历史本身由系统自动记录成 kind=session，**不要**在这里重复生成；
4. 一次性、无复用价值的内容 → 返回 {"skip": true}，不要硬凑。
```

### 12.3 `SCHEDULE_PROMPT`（描述 → 定时任务）

```
把用户的一段描述转换成一个定时任务。只输出 JSON，不要解释：
{"name":"唯一标识，小写字母/数字/-，≤32 字符","cron":"标准五段 cron（分 时 日 月 周）",
 "once":false,"concurrentable":false,
 "taskSource":"一段仓颉语句序列，形参固定为 e: Event，必须 return e"}

规则：
1. 用户没说时间 → 返回 {"error":"缺少执行时间"}，不要猜；
2. “每天 9 点” → cron "0 9 * * *"；“每 5 分钟” → "*/5 * * * *"；
3. 只执行一次 → once=true，cron 仍要能表达触发时刻；
4. 任务体只能调用已注册的 tool_call / MCP / JIT 闭包，不得出现 shell、文件路径与网络地址；
5. 任务体不得包含 while(true) 或 sleep。
```

### 12.4 `LOOM_PLAN_PROMPT`（文本 → 流程计划）

```
你是流程编排器。把用户的任务描述拆成可执行步骤，只输出 JSON 计划，不要生成代码。

结构：
{"name":"…","steps":[{"id":"…","kind":"llm|tool|mcp|jit","model":"…","tool":"…",
  "args":{},"system":"…","input":"${stepId.output}","async":"auto|true|false"}],
 "edges":[["fromId","toId"]]}

规则：
1. 步骤 id 唯一、小写、无空格；edges 必须无环，且每个 id 都出现；
2. 用户点名某步用什么模型时写 model，否则模型字段留空（用默认）；
3. 用户说“并行/同时/异步”的步骤 async=true；有副作用（写库、发消息）的步骤 async=false；
4. 步骤只能使用允许清单里的 tool/mcp：{{ALLOWED_TOOLS}} / {{ALLOWED_MCPS}}，越界即失败；
5. 数据依赖用 ${stepId.output} 表达，不要写文件或全局变量；
6. 描述里没有的信息不要编造；缺关键参数时返回 {"error":"…"}。
```

### 12.5 `SKILL_IMPORT_PROMPT`（zip → skills 记录）

```
把技能包转换成 f_llm 的 skills 记录。只输出 JSON，不要解释：
{"title":"≤64 字","accepted_event":"next","returned_event":"next",
 "details":"Markdown，保留原技能包的步骤与注意事项",
 "functions":["tool:webSearch","mcp:fs.read_file","jit:normalize"],
 "skill_type":"tool",
 "rejected":[{"file":"run.sh","reason":"内含 curl 直接访问内网地址，无法映射到已注册工具"}]}

硬约束：
1. 不得保留任何脚本文件（.sh/.py/.js/.bat）；每个脚本必须映射成 tool:/mcp:/jit: 之一；
2. 映射不确定时放入 rejected，并说明缺哪个工具，不要静默丢弃；
3. details 里不得出现本地绝对路径、密钥、内网地址；
4. functions 只能使用 {{ALLOWED_TOOLS}} 与 {{ALLOWED_MCPS}} 中的名字。
```

### 12.6 `TASK_SKILL_PROMPT`（task 记忆 → 技能）

```
把同一任务的多次执行经验合成一个可复用技能。只输出 JSON，不要解释：
{"title":"≤64 字","accepted_event":"next","returned_event":"next",
 "details":"Markdown：触发条件、步骤、注意事项、失败案例",
 "functions":["tool:webSearch","jit:normalize"],
 "skill_type":"auto",
 "evidence":3}

规则：
1. 只依据输入里的 task 记忆，不补充外部知识；不足 3 条证据时返回 {"error":"证据不足"}；
2. 步骤要能直接执行（工具名 + 参数形态），不写“适当处理”这类空话；
3. 已有技能时做增量更新：保留仍然有效的步骤，只补充/修正差异，不整篇重写；
4. functions 只能使用 {{ALLOWED_TOOLS}} 与 {{ALLOWED_MCPS}} 中的名字；
5. details 不得出现本地绝对路径、密钥、内网地址。
```

---

## 13. 配置项（新增）

| 键 | 默认 | 说明 |
|---|---|---|
| `llm_memoryBackend` | `memory` | `memory`/`file`/`postgres`/`mysql`/`fhydra` |
| `llm_memoryPath` | `./data/memory` | 文件实现根目录 |
| `llm_characterBackend` | `memory` | 同上五选一 |
| `llm_embeddingUrl` | `http://127.0.0.1:8000` | BGE-M3 服务 |
| `llm_embeddingBatch` | 32 | 批量 |
| `llm_knowledgePandoc` | `pandoc` | 可执行路径 |
| `llm_knowledgeMaxChunkBytes` | 32768 | 单块正文上限 |
| `llm_fhydraUrl` | `http://127.0.0.1:8848` | fhydra 地址 |
| `llm_fhydraToken` | 空 | 鉴权 |
| `llm_loomAutoConfirm` | `false` | 是否跳过预览（生产禁止 true） |
| `llm_loomMaxSteps` | 16 | 单流程步骤上限 |
| `llm_serverTimezone` | 空（系统时区） | 服务端时区覆盖，如 `Asia/Shanghai`；存 UTC、边界换算见 §5.6 |
| `llm_ticktockEnabled` | `false` | 定时任务工具开关 |

---

## 14. 失败模式

| 场景 | 行为 |
|---|---|
| pandoc 缺失 / 版本低 | 对应格式标记不可用，`knowledgeIngest` 明确报错，不写半成品 |
| PDF 无文本层 | 失败并提示 OCR，不写空文档 |
| embedding 服务不可用 | 记忆写入**拒绝**（不能存无向量记忆），检索降级为关键词匹配并标记 `degraded` |
| sparse/colbert 未返回 | 降级为 dense-only，写 `has_sparse=false` |
| 数据库无向量扩展 | `PostgresMemoryStore` 启动失败（明确提示 `create extension vector`）；MySQL < 9.2 降级暴力扫并 `warn` |
| fhydra 不可达 | 熔断 + 明确异常；不落本地影子数据（避免双写不一致） |
| loom 编译失败 | 返回诊断与源码，注册表保持 `pending`，不注册半成品 |
| 定时任务 cron 非法 | 拒绝注册，返回可用示例 |
| 超时工具不支持取消 | 返回 `{}`，同时记录 `cancel=none` 标记（副作用可能仍完成） |

---

## 15. 测试计划

| 模块 | 关键用例 |
|---|---|
| Parser | 9 种 pandoc 格式各 1 个样本；PDF 三种质量分支；不支持格式报错 |
| 分块 | 标题优先切分；512+64 重叠；同文档重复导入 chunkId 不变 |
| Embedding | 三路返回解析；batch 部分失败重试；超时熔断 |
| Memory | 5 个实现跑同一套 conformance 用例（增删改查+检索+分页+越权） |
| 分层 | 工作空间记忆在另一工作空间不可见；全局记忆跨空间可见 |
| Character | 13 个预定义 key 可解析；custom 覆盖；`reset` 回落 default |
| 裁剪 | 8 策略 + TokenBudget 下首条 system 始终保留 |
| SQL | 同一份 DDL 在 PG/MySQL 各建一次；向量索引 `EXPLAIN` 命中 |
| 工具 | `memoryCall` 四动作；`callWithTimeout` 超时返回 `{}` 且标记取消 |
| loom | 计划生成→源码预览→编译→执行；环检测；越界工具拒绝；删除后 `unload` |
| 技能导入 | 含 sh 的包被拒；纯工具包成功入库；details 不含路径 |
| 定时 | cron 非法拒绝；注册后可触发；删除后不再触发 |

---

## 16. 分阶段实施

| 阶段 | 内容 | 前置 |
|---|---|---|
| P1 | `tables-pg.sql` / `tables-mysql.sql`、`MemoryStore` 抽象 + 内存/文件实现 | 无 |
| P2 | PG/MySQL 实现（SQL + 向量/倒排） | P1；MySQL 9.2+ 安装放 P6 |
| P3 | 人设 API + 13 提示词 + 首条 system 保护 | P1 |
| P4 | `memoryCall` / `knowledgeIngest` / `skillImport` / `schedule*` / `callWithTimeout` | P1–P3 |
| P5 | `loom` 包（计划/代码生成/两级 JIT/预览） | P4 |
| P6 | 安装 MySQL 最新版 + 向量索引，跑 MySQL 相关用例 | P2 |
| P7 | fhydra 实现（另一份文档） | P1 |

**注意**：P6 的安装与联调放在最后，是需求 4 的明确要求——先把 MySQL 代码写完再装库验证。

---

## 17. 决策记录（2026-10-28 定稿）

> 下表是**已定稿**的决策，不再作为待确认项；后续只讨论文末「剩余未决」。

| 问题 | 决定 |
|---|---|
| 标题是否需要独立 colbert | **需要**：标题与正文各存一份 colbert，重排时两路加权（§6.2） |
| `llm_memory_token.token` 用 id 还是字符串 | **BGE-M3 token id（bigint）**，省空间（§6.2） |
| 记忆是否要软删除 + 回收站 | **不要**，硬删（§5.1 `remove`） |
| 硬删是否需要二次确认 | **不要**：显式给 id 即视为确认；自动记忆（task/session）也可手动删（§5.5、§8.1） |
| loom 流程定义是否持久化 | **要**：`llm_loom_flow` 存计划与源码，启动重编译（§9.9） |
| `step_sources` 用 JSON 还是拆行 | **JSON**：一个流程一个 JSON，存一个单元格（§9.9） |
| 人设是否按工作空间区分 | **不区分**，按用户唯一（§6.4） |
| 预定义 kind 的种子方式 | **代码固化 + 启动幂等写入**；预定义 7 值，自定义 kind **归属用户**（§5.4） |
| 时间与时区 | **存 UTC、算本地**：落库统一 UTC，API 与按日过滤按服务端时区换算（§5.6） |
| task / session 记忆怎么来 | **自动**：`MemoryRecorderTask` 接收 `llm.turn` / `task.step` / `task.end` 事件，异步写入与抽取（§5.5） |
| `session` 记忆的保留策略 | **滚动摘要，不设硬上限**：超 32K 字时保留最近 20 轮 + 摘要（§5.5） |
| `task` 记忆要不要反哺技能 | **要**：同类任务累计 3 条经验 → 生成 skill；之后每条新记忆做增量更新（§5.5、§12.6） |
| 同类任务如何判定 | `taskName` 相同 **或** 主题向量相似度 ≥ 0.85（§5.5） |
| 自动记忆是否参与默认检索 | **参与**，按 kind 权重降权：`session=0.3`、`task=0.6`；检索支持权重查询（§5.4） |
| 权重是否可配 | **固定值**：代码常量 + 种子行，不提供请求/collection/用户级覆盖（§5.4） |

剩余未决：**无**（本轮问题全部收敛；后续如出现新问题再单列）。
