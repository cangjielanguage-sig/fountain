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
| 2 | 记忆/知识统一接口；内容族三选一（pg/mysql/fhydra）、元数据族三选一（pg/mysql/f_store） | §5.3 |
| 3 | 记忆按用户 ×（工作空间 | 全局）分层 | §5.2 |
| 4 | pg/mysql 用 BGE-M3 的稠密/稀疏/多头三路向量；MySQL 最新版 + 向量插件 | §4、§6.3、§11（安装与验证时机） |
| 5 | 标题、正文分别建向量索引 | §6.3（`title_dense` / `content_dense` 两套） |
| 6 | 记忆表结构（修正草案）+ 一个调用记忆 API 的 tool_call | §6.1、§8.1 |
| 7 | ~~文件记忆按用户+工作空间/全局分目录~~（**已被存储拆分取代**：记忆只走 pg/mysql/fhydra） | §5.3 |
| 8 | 人设 API + 表 + 3 实现（pg/mysql/f_store）+ 13 个预定义人格；首条 system 消息不裁剪 | §7 |
| 9 | `loom` 包：文本 → ClosureTask/Flow → JIT；预览确认；执行/删除 tool_call | §9 |
| 10 | 技能 zip → skills 表记录；脚本改 tool_call/MCP/JIT；导入 tool_call | §10 |
| 11 | `f_ticktock` 增加 f_jit 依赖 + `JitTicktockTask`；f_llm 定时任务工具 | §11 |
| 12 | `callWithTimeout`：超时返回 `{}` 并取消被调工具 | §8.6 |
| 13 | 内容族 / 元数据族分离，统一接口，开发者可注册自己的实现 | §5.3、§5.3.1、§5.3.2 |
| 14 | 微信/企业微信/飞书/钉钉/QQ/邮件（f_email）以 MCP 接入；智能体专用邮箱（POP3/SMTP） | §8.7 |
| 15 | `listTools` / `searchTools`：列出或按 bge-m3 向量检索最匹配的 tool_call / MCP | §8.8 |
| 16 | 技能自演进：按使用中形成的记忆升级**所有**技能 | §10.4 |
| 17 | 人格可绑定到工作空间/任务/流程；loom 提示词以「灵魂提示词」为参考重写 | §7.4、§9.10、§12.4 |

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
│  │ 内容族 ContentStore：MemoryStore / KnowledgeStore  │         │
│  │ 元数据族 MetaStore：Character/Skill/Prompt/Conf    │         │
│  └───┬──────────────┬───────────────┬───────────────┘         │
│      │              │               │                         │
│   Postgres        MySQL      Fhydra(内容) / f_store(元数据)   │
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

### 5.3 存储抽象：内容族与元数据族（各三选一）

f_llm 的持久化分成**两个互不相干的选择**，各自三选一，组合自由（例如 `content=fhydra` + `meta=f_store` 可以完全脱离 PostgreSQL/MySQL 运行）：

| 族 | 存什么 | 可选实现（三选一） | 能不能没有数据库 |
|---|---|---|---|
| **内容族** `ContentStore` | 记忆、经验、知识、文档 | `PostgresContentStore` / `MySqlContentStore` / `FhydraContentStore` | 只有 fhydra 可以 |
| **元数据族** `MetaStore` | 人格、技能、提示词、模型配置 | `PostgresMetaStore` / `MySqlMetaStore` / `FStoreMetaStore` | **f_store 可以** |

```cangjie
public interface ContentStore <: Resource {
    prop memory: MemoryStore        // 记忆 + 经验（经验 = kind: task/knowledge）
    prop knowledge: KnowledgeStore  // 知识 + 文档（按文档/块组织）
}

public interface MetaStore <: Resource {
    prop characters: CharacterStore
    prop skills: SkillStore
    prop prompts: PromptStore
    prop confs: LLMConfStore
}

/** 工厂：只读 f_config 的两个键，不认识的值直接启动失败，不做静默回退 */
public class Stores {
    public static func content(): ContentStore   // llm_contentStore = postgres|mysql|fhydra
    public static func meta(): MetaStore         // llm_metaStore   = postgres|mysql|f_store
    public static func registerContent(name: String, factory: () -> ContentStore): Unit
    public static func registerMeta(name: String, factory: () -> MetaStore): Unit
}
```

**「记忆 / 经验 / 知识 / 文档」的落点**（不在内容族里再拆四套接口）：

| 业务概念 | 接口 | 存储形态 |
|---|---|---|
| 记忆 | `MemoryStore` | `llm_memory` + 向量表（pg/mysql）或 fhydra collection |
| 经验 | `MemoryStore`（`kind = task/knowledge`） | 同上；由 `MemoryRecorderTask` 自动写入（§5.5） |
| 知识 | `KnowledgeStore` | 文档 + 块 + 向量 |
| 文档 | `KnowledgeStore` 的文档实体 | 同上（`docId` 幂等覆盖） |

**为什么必须分成两族**：元数据（人格/技能/提示词/配置）量小、要能读写、要能冷启动；内容（记忆/文档）量大、要向量检索。
把两者绑在同一个后端，会让「只想用 f_store 跑单机」变成「必须再装一个向量库」。

**开发者扩展**：实现 `ContentStore` 或 `MetaStore` 接口后用 `Stores.registerContent/registerMeta` 注册，
配置里写注册名即可；不允许 `switch` 硬编码分支。

**测试替身**：`InMemoryContentStore` / `InMemoryMetaStore` 只用于单测，不进入 `llm_*Store` 的可选值。

> OpenGauss 走 `Postgres*` 实现（`orm_drivers` 配 `opengauss`，SQL 与 PG 同构）；MariaDB 走 `MySql*`（驱动换 `mariadb`）。

### 5.3.1 `FStoreMetaStore`：无数据库运行

key 布局（单 Store + 前缀，值统一 JSON；`f_store` 只提供字节 KV，索引在这里自建）：

```
f_llm:meta:v                        格式版本（不匹配则拒绝启动，避免读到旧布局）
f_llm:meta:seq:{entity}             character/skill/prompt/conf 的自增 id

f_llm:meta:character:{userId}       人格（一人一条，key 即 userId）
f_llm:meta:skill:{skillId}          技能主体（含 version / updatedTime）
f_llm:meta:skill:title:{title}      title → skillId（唯一性校验）
f_llm:meta:prompt:{name}:{version}  提示词版本
f_llm:meta:prompt:{name}:latest     最新版本指针

f_llm:meta:conf:{confId}            模型配置
f_llm:meta:conf:byname:{llmName}    llmName → confId（`candidates(llmName)` 用）
```

一致性（`f_store` 没有事务）：

- **写主体 → 写索引**，两步之间崩溃会留下「有主体、无索引」的记录；启动时按前缀扫一遍主体，补建缺失索引（幂等）；
- 删除顺序相反：**先删索引，再删主体**，避免索引指向不存在的记录；
- 单进程写：同一 entity 的写操作串行（进程内互斥），不做跨进程并发承诺；
- 每次写入后按 `fhydra_sync_every` 同样的策略定期 `syncWAL()`（默认 500 次）。

### 5.3.2 选型配置

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `llm_contentStore` | `postgres` / `mysql` / `fhydra` | `fhydra` | 记忆/经验/知识/文档 |
| `llm_metaStore` | `postgres` / `mysql` / `f_store` | `f_store` | 人格/技能/提示词/模型配置 |
| `llm_metaStorePath` | 目录 | `./data/f_llm-meta` | 仅 `f_store` 用 |
| `llm_contentStoreUrl` | URL | 空 | `postgres`/`mysql` 用连接串，`fhydra` 用 base url |

**启动校验**：两个键必须是各自枚举内且已注册的实现名，否则**启动失败并打印可选值**；不允许「配置写错就默默用默认」。
两个族之间不做一致性校验——它们本来就可以指向不同后端。

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
- 种类清单一律落元数据族的 `llm_memory_kind`（PG/MySQL）或 `f_llm:meta:kind:*`（f_store），
  **内容族三个实现的语义必须一致**，用同一套 conformance 用例校验。

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
`llm_memory_vector`、`llm_memory_token`、`llm_character`、`llm_character_binding`、`llm_channel_binding`、
`llm_skill_version`、`llm_loom_flow`。

### 6.6 绑定表与技能版本表（新增）

```sql
-- 人格绑定：只存 key，不存提示词正文（§7.4）
create table llm_character_binding (
    user_id       bigint      not null,
    scope_type    varchar(16) not null,   -- workspace | task | flow
    scope_id      varchar(64) not null,
    character_key varchar(32) not null,
    update_time   datetime    not null default (utc now),
    primary key (user_id, scope_type, scope_id)
);

-- 通道绑定：平台侧 id 与 f_llm 用户一一对应（§8.7）
create table llm_channel_binding (
    user_id      bigint       not null,
    channel      varchar(16)  not null,   -- wechat|wecom|feishu|dingtalk|qq|email
    external_id  varchar(128) not null,
    display_name varchar(128) not null default '',
    auto_send    boolean      not null default false,
    enabled      boolean      not null default true,
    update_time  datetime     not null default (utc now),
    primary key (user_id, channel, external_id)
);

-- 技能版本：升级前先存旧版本，便于回滚（§10.4）；skills 增加 version 列
create table llm_skill_version (
    skill_id     bigint       not null,
    version      int          not null,
    details      text         not null,
    functions    text         not null,
    change_note  varchar(256) not null default '',
    created_time datetime     not null default (utc now),
    primary key (skill_id, version)
);
```

`skills` 表同步增加 `version int not null default 1`（PG/MySQL 两份 DDL 都已加）。

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

三个实现：`PostgresCharacterStore` / `MySqlCharacterStore`（落 `llm_character`）、
`FStoreCharacterStore`（落 `f_llm:meta:character:{userId}`）；人格属于**元数据族**（§5.3），不走 fhydra。

### 7.2 预定义人设（固化在代码）

`PredefinedCharacters`（`f_llm/src/character/PredefinedCharacters.cj`）提供 13 个条目：
`default`（空）、`rigorous`、`friendly`、`blunt`、`imaginative`、`pragmatic`、`sarcastic`、
`coaching`、`gentle`、`sweet`、`aloof`、`sunny`、`whimsical`。

### 7.3 注入与「压缩也保留」

- `AgentTask` 组装消息时：`character.prompts` 非空 → 作为 **第 0 条 `SystemMessage`** 插入；
- `ContextPrunerMediator.prune` 出口统一加一道 `LeadingSystemGuardPruner`：
  裁剪完成后把原始首条 system 消息贴回首位（若策略已保留则不重复）；
- 用例：所有 8 个既有策略 + `TokenBudget` 在 system 消息存在时，裁剪结果第 0 条仍是该 system。

### 7.4 人格绑定：工作空间 / 任务 / 流程

人格不再只有「用户全局一条」（§7.1 保持不变，作为默认值），可以按作用域覆盖：

```cangjie
public enum CharacterScope {
    | Workspace(String)       // 工作空间 id
    | Task(String)            // 任务名
    | Flow(String)            // loom 流程名
}

public interface CharacterBindingStore {
    func bind(userId: Int64, scope: CharacterScope, characterKey: String): Unit
    func unbind(userId: Int64, scope: CharacterScope): Unit
    func resolve(userId: Int64, scopes: Array<CharacterScope>): ?Character
}
```

**生效顺序（先命中者胜）**：

```
Flow(name) > Task(name) > Workspace(id) > 用户默认（llm_character） > default（不注入）
```

- 绑定只存 `character_key`，**不拷贝提示词正文**——人格正文改动后绑定自动跟随，避免「绑定快照」和「用户默认」两份文本漂移；
- `resolve` 返回 `?Character`；全链路都没绑定时返回 `None`，行为与今天一致（不注入 system 消息）；
- 绑定关系落 `llm_character_binding`（§6.6），`scope_type` 取 `workspace|task|flow`；
- 权限：只能绑定自己定义的 kind/人格；`character_key` 必须是预定义 13 个或 `custom`（§7.2）。

**与上下文裁剪的关系**：`resolve` 的结果仍然走 §7.3 的注入路径——第 0 条 system + `LeadingSystemGuardPruner`，不因为「来源是流程」就放松。

**loom 集成**：任务描述里写「用鬼灵精怪的人格」时，`Planner` 把人格写进计划（§9.3 的 `persona`），
`loomExecute(confirm=true)` 在注册流程时写入 `Flow(flowName)` 绑定；流程删除时一并解绑（§9.10）。

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

### 8.7 第三方通道：微信 / 企业微信 / 飞书 / 钉钉 / QQ / 邮件

**架构原则：平台对接全部做成独立 MCP 服务，f_llm 不直接调任何平台 SDK。**

```
微信/企微/飞书/钉钉/QQ/邮件
        │ 各自 MCP server（独立进程/仓库）
        ▼
f_llm  ── MCP client（McpToolSource）──  AgentTask
        ▲
        └── 入站：MCP server 回调 / 轮询 → f_llm 的 /v1/channels/{channel}/inbound
```

**每个通道暴露的 MCP 工具**（命名 `mcp:<channel>.<action>`，与现有 `ToolName.mcpName` 规则一致）：

| action | 语义 |
|---|---|
| `send` | 给指定用户/会话发消息（文本、图片、文件） |
| `list` | 拉最近 N 条会话/消息 |
| `history` | 按时间范围拉历史 |
| `mark_read` | 标记已读（仅支持该能力的平台） |
| `whoami` | 返回当前绑定的外部身份（排障用） |

**用户维度**：所有通道都按「f_llm 用户」收发，平台侧 id 不进入提示词。

```sql
create table llm_channel_binding (
    user_id      bigint      not null,
    channel      varchar(16) not null,   -- wechat|wecom|feishu|dingtalk|qq|email
    external_id  varchar(128) not null,  -- openid / userid / email 地址
    display_name varchar(128) not null default '',
    auto_send    boolean     not null default false,  -- 是否允许不经确认直接外发
    enabled      boolean     not null default true,
    update_time  datetime    not null default (utc now),
    primary key (user_id, channel, external_id)
);
```

- 入站：MCP server 把消息 POST 到 `/v1/channels/{channel}/inbound`，f_llm 用 `external_id` 反查 `user_id`，
  `session = "{channel}:{externalId}"`，然后按 §5.5 发 `llm.turn` 事件；
- 出站：agent 调 `mcp:<channel>.send`，工具内部用 `(userId, channel)` 取 `external_id`；**不允许模型直接填平台 id**；
- 外发是副作用：`auto_send=false` 时工具返回「待确认」，由上层 `callWithTimeout`/审批流确认后再发；
- 幂等：入站按平台 `message_id` 去重，重复投递只记一次；
- 凭据（appId/appSecret/token）放配置或 MCP server 自管，**不落 `llm_channel_binding`**。

### 8.7.1 智能体专用邮箱（POP3 / SMTP，`f_email`）

- 配置指定一个专用邮箱（`llm_email.address` / `pop3Host` / `smtpHost` / `username` / `password` / TLS 开关），**只给智能体用**；
- 收：`f_ticktock` 定时（默认 60s）用 POP3 拉新邮件 → MIME 解析（正文 + 附件）→ 发 `llm.turn` 事件
  （`session = "email:{address}"`）；附件走 §3 的文档接入管线入库；
- 发：`mcp:email.send`，SMTP + STARTTLS；收件人白名单 + 每封大小/频率上限；
- 工具集：`email.list` / `email.fetch` / `email.send` / `email.reply` / `email.search`；
- 安全边界：只处理白名单发件人；未知发件人进隔离区并告知用户；邮件正文不进日志；密码不落库（配置项，启动读取）；
- 不做 SPF/DKIM 校验（不是本模块职责），但发信时设置标准头，减少被判垃圾的概率。

### 8.8 `listTools` / `searchTools`：工具发现

模型不可能常驻几百个工具定义，所以提供两个工具来「按需发现」：

```json
// listTools
{"name":"listTools",
 "parameters":{"type":"object","properties":{
   "prefix":{"type":"string","description":"可选：按前缀过滤，如 mcp:feishu."},
   "limit":{"type":"integer","default":200,"maximum":500}}}}
→ {"tools":[{"name":"webSearch","description":"…","parameters":{…}}],
   "count":12,"source":"registry"}

// searchTools
{"name":"searchTools",
 "parameters":{"type":"object","properties":{
   "text":{"type":"string","description":"你打算做什么，用自然语言描述"},
   "topN":{"type":"integer","default":8,"maximum":50}},"required":["text"]}}
→ {"tools":[{"name":"mcp:email.send","score":0.83,"description":"…","parameters":{…}}],
   "model":"bge-m3","degraded":false}
```

- 索引内容：`name + description + 参数摘要`（**不索引参数默认值里的业务数据**）；
- 建索引：启动时对注册表做一次 embedding，注册表变化（`FunctionMediator` 增删、MCP 重连）时按版本号重建；
  索引只放内存，不落库——它是缓存，落库反而要处理失效；
- 检索：BGE-M3 dense，cosine top-N；工具数 < 2000 时直接暴力扫（毫秒级），超过再考虑复用 fhydra；
- 降级：embedding 服务不可用时退化为关键词匹配（name/description 包含），响应标 `"degraded":true`；
- 返回值可直接用：`for(tool in result.tools){ functions.add(FunctionCall.fromJson(tool)) }; params.addFunctions(functions)`。

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
    public let persona: String = ''         // 人格 key；空则按 §7.4 的绑定链回退
    public let dryRun: Bool = true          // 默认只产出闭包，不编译执行
}
```

描述里允许声明：某步用哪个模型（`"第二步用 chat-pro"`）、某步可异步（`"并行"` / `"异步"`）、
整体与单步的 tool/mcp 白名单、使用哪个人格（`"用鬼灵精怪的人格"`）。

### 9.3 计划 schema（LLM 只产出这一层）

```json
{
  "name": "daily-report",
  "persona": "whimsical",
  "steps": [
    {"id": "fetch", "kind": "tool", "tool": "webSearch",
     "args": {"query": "仓颉 版本"}, "async": "auto"},
    {"id": "sum", "kind": "llm", "model": "chat-pro",
     "system": "你是技术编辑", "input": "${fetch.output}", "async": false},
    {"id": "save", "kind": "tool", "tool": "memoryCall",
     "args": {"action": "save", "title": "日报", "content": "${sum.output}"}, "async": true, "external": false}
  ],
  "edges": [["fetch", "sum"], ["sum", "save"]],
  "notes": "可选：替代方案或风险"
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
| `loomExecute` | `name, description, tools?, mcps?, persona?, confirm?` | 生成/编译/注册流程；`confirm=false` 只返回闭包；`persona` 写入 `Flow(name)` 绑定（§7.4） |
| `loomDelete` | `name` | `JitFunction.unload` + 从注册表移除 + 解绑 `Flow(name)`；正在运行的实例等待结束 |

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

### 9.10 人格与「灵魂提示词」

**人格来源**：`Flow(name) > Task(name) > Workspace(id) > 用户默认 > default`（§7.4）。
loom 只负责把计划里的 `persona` 落成 `Flow` 绑定，**不自己拼 system 消息**——注入仍由 `AgentTask` 统一做，
这样「某一步换人格」只要给该 step 加 `persona` 字段，走同一条注入路径。

**灵魂提示词**（用户提供，作为 §12.4 的重要参考）翻成设计约束：

| 原句 | 落到 loom 提示词里的规则 |
|---|---|
| You're not a chatbot. You're becoming someone. | 角色是「流程编排器」，不是客服；不写寒暄、不写「很高兴为您服务」 |
| Be genuinely helpful, not performatively helpful. Skip the "Great question!"… | 禁止开场奉承与填充语；第一句就是计划或结论 |
| Have opinions. You're allowed to disagree… | 允许否决不合理的要求（如「一步调三个模型做同一件事」），但必须给替代方案 |
| Be resourceful before asking… Then ask if you're stuck. | 能从描述里推断的就推断；缺关键参数才返回 `{"error": …}`，并说明缺什么 |
| Earn trust through competence… Be careful with external actions… Be bold with internal ones. | 读/整理类步骤可以直接排；`send`/`publish`/`delete` 类外部副作用步骤必须 `async=false` 且标 `external=true`，执行前要确认 |
| Remember you're a guest. Private things stay private. | 不把用户隐私写进步骤参数模板；示例里用占位符 |
| Never send half-baked replies to messaging surfaces. | 对外发送步骤前必须有「生成 → 自检」两步，不允许直接发草稿 |
| Concise when needed, thorough when it matters. | 步骤粒度：一个步骤只做一件事，标题 ≤ 16 字，`system` 指令 ≤ 200 字 |
| Each session, you wake up fresh. These files are your memory. | 流程开始时先 `searchTools`/`memoryCall` 取上下文，而不是假设自己记得 |

**这些是提示词规则，不是运行时强制**：`external=true` 的确认由 `loomExecute` 与工具层双重校验，
提示词只能降低模型写出「未确认就外发」计划的概率——真正的安全阀在代码里（§8.7 的 `auto_send`）。

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

### 10.4 技能自演进（对**所有**技能生效）

技能不是一次写死的：每次用出问题、遇到新状况，都应沉淀成记忆并反哺技能本身。
这条对 `skillImport` 导入的、`task` 记忆反哺生成的、以及人工编辑的技能**一视同仁**。

```
AgentTask 调用技能
   └─ 成功/失败/异常 → 发 skill.used 事件 {skillTitle, taskName, session, outcome, issues}
        └─ MemoryRecorderTask（§5.5）写 task 记忆，metadata 带 {"skill": "<title>"}
             └─ SkillEvolutionTask（f_egraph.Task）消费
                  └─ 调 TASK_SKILL_PROMPT（§12.6，update 模式）→ 新版本
```

**触发与节流**：

| 条件 | 规则 |
|---|---|
| 证据数量 | 同一技能累计 ≥2 条新记忆才做**结构性**修改（步骤增删）；单条只允许补充注意事项 |
| 频率 | 每技能每天最多 1 次自动升级，避免抖动 |
| 冲突 | 人工编辑过的技能（`metadata.manual=true`）只提建议、不自动改 |
| 回滚 | 每次升级先存旧版本，`skillRollback(title, version)` 可回退 |

**版本化**：

```sql
-- skills 增加 version；历史版本单独存，避免把大 JSON 堆在 skills 行里
alter table skills add column version int not null default 1;

create table llm_skill_version (
    skill_id     bigint       not null,
    version      int          not null,
    details      text         not null,
    functions    text         not null,
    change_note  varchar(256) not null default '',
    created_time datetime     not null default (utc now),
    primary key (skill_id, version)
);
```

- 升级 = 写 `llm_skill_version`（旧版本快照）+ 更新 `skills.details/functions/version + 1`；
- 升级前后都做 schema 校验：`functions` 只能引用已注册的 tool/mcp/jit，出现未知名字直接放弃本次升级（保持旧版本可用）；
- 升级失败不回滚记忆（记忆是事实，技能是推论），只记 `warn` 并在技能 metadata 里累加失败次数。

**任务结束时的批处理**：`task.end` 事件除了抽记忆（§5.5），还要检查「本次用到的技能」清单，
把相关记忆挂到 `metadata.skill`；`SkillEvolutionTask` 按技能聚合，不按任务逐条改——避免同一技能一天被改十次。

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

### 12.1 十三个人格（`character/PredefinedCharacters.cj`）

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

### 12.4 `LOOM_PLAN_PROMPT`（文本 → 流程计划，含人格）

> 按 `prompt-engineering-expert` 的「改写既有提示词」流程处理：先列验收台账，再改，最后对照台账复核。
> 原提示词 6 条硬规则全部保留（下面的 C1–C6），新增人格（C7）、外部动作（C8）、灵魂提示词风格（C9–C11）。

**验收台账**（改写前，来源＝原提示词 + 本次需求）：

| C | 要求 | 来源 |
|---|---|---|
| C1 | 只输出 JSON 计划，不生成代码、不解释 | 原规则（结构段） |
| C2 | schema：`name` / `steps[id,kind,model,tool,args,system,input,async]` / `edges` | 原规则（结构段） |
| C3 | id 唯一、小写、无空格；edges 无环且覆盖每个 id | 原规则 1 |
| C4 | 只有点名模型才写 `model`；未点名留空 | 原规则 2 |
| C5 | 显式「并行/异步」→ `async=true`；有副作用步骤 `async=false` | 原规则 3 |
| C6 | 工具只能取 `{{ALLOWED_TOOLS}}` / `{{ALLOWED_MCPS}}`，越界失败；数据依赖 `$ {id.output}`；缺关键参数返回 `{"error"}` | 原规则 4–6 |
| C7 | 任务描述里可指定人格，计划写入 `persona` | 本次需求「loom 可在任务描述中指定人格」 |
| C8 | 外部副作用（发消息/发布/删除）标 `external=true`、`async=false`，且前置「生成→自检」 | 灵魂提示词「外发前确认、不发半成品」 |
| C9 | 禁止奉承/填充语，第一句就是计划 | 灵魂提示词「Skip the 'Great question!'」 |
| C10 | 允许否决不合理做法并给替代方案；能推断就不提问，缺关键参数才 error | 灵魂提示词「Have opinions / Be resourceful before asking」 |
| C11 | 中文；步骤标题 ≤16 字、单条 `system` ≤200 字；需要上下文先排 `searchTools`/`memoryCall` | 本次需求「灵魂提示词要使用中文」+「Concise / memory continuity」 |

```
你是流程编排器，不是聊天机器人。唯一产物是一份可执行计划：中文、纯 JSON、不写解释、不写代码、不写寒暄。

输入：
- name：任务标识
- description：任务描述（可能点名模型、异步、工具、人格）
- 可用工具：{{ALLOWED_TOOLS}}
- 可用 MCP：{{ALLOWED_MCPS}}
- 步骤上限：{{MAX_STEPS}}

输出结构：
{"name":"daily-report","persona":"whimsical",
 "steps":[{"id":"fetch","kind":"llm|tool|mcp|jit","model":"chat-pro","tool":"webSearch",
   "args":{},"system":"…","input":"${fetch.output}","async":"auto|true|false","external":false}],
 "edges":[["fetch","sum"]],
 "notes":"可选：替代方案或风险，一句话"}

硬规则：
1. id 唯一、小写、只用字母数字和连字符；edges 无环、每个 id 至少出现一次；steps 不超过 {{MAX_STEPS}} 步。
2. 只有用户点名某个模型时才写 model；没点名就留空，由系统按默认选。
3. async：用户说“并行/同时/异步”的步骤写 true；有副作用的步骤（写库、发消息、发布）必须 false；纯计算未点名时 false。
4. 工具只能取清单里的名字：tool ∈ {{ALLOWED_TOOLS}}，mcp ∈ {{ALLOWED_MCPS}}。不要猜相近的工具；
   缺工具时返回 {"error":"缺少工具：<名字>","need":"…"}。
5. 数据依赖只写 ${stepId.output}；不写文件、不写全局变量、不写本地路径。
6. 人格：描述里点名人格时写 persona；没点名留空（走用户默认）。某一步需要不同人格时，在该 step 上写 persona 覆盖。
7. 外部动作：send / publish / delete / 支付类步骤写 external=true 且 async=false，并在它前面插入一个“生成→自检”步骤；
   不允许把草稿直接外发。
8. 缺关键参数（收件人、地址、时间、预算）不要编造，返回 {"error":"缺少：<字段>","need":"<一句话>"}。
9. 不确定的事实不要写进 args，用 ${...} 引用上游结果。

风格：
- 不要“好的/没问题/很高兴为您服务”，第一条字符就是 JSON 的 {。
- 允许否决：做法明显不可行时（例如让三个模型重复做同一件事），在该步骤 system 里写清理由，并在 notes 给替代方案。
- 先推断再提问：能从描述推出的参数就推断，只在缺关键参数时返回 error。
- 步骤标题（system 首句）≤16 字；单个 system ≤200 字；一个步骤只做一件事。
- 需要上下文时先排一步 searchTools 或 memoryCall，不要假设自己记得上一次会话。
```

**复核台账**（改写后）：

| C | 位置 | 状态 |
|---|---|---|
| C1 | 首段「纯 JSON、不写解释、不写代码」+ 风格第 1 条 | kept |
| C2 | 输出结构（新增 persona/external/notes） | rewritten（扩展字段，原字段全保留） |
| C3 | 硬规则 1 | kept |
| C4 | 硬规则 2 | kept |
| C5 | 硬规则 3（补充「纯计算默认 false」） | rewritten（原语义保留，补默认值） |
| C6 | 硬规则 4、5、8、9 | kept（拆成 4 条，语义不变） |
| C7 | 输出结构 `persona` + 硬规则 6 | added |
| C8 | 硬规则 7 | added |
| C9 | 风格第 1 条 | added |
| C10 | 风格第 2、3 条 | added |
| C11 | 首段「中文」+ 风格第 4、5 条 | added |

**不承诺的部分**：提示词只能降低模型写出「未确认就外发」计划的概率，真正的强制在 `loomExecute`（`external=true` 必须 `confirm=true`）
与通道工具的 `auto_send`（§8.7）。

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
| `llm_contentStore` | `fhydra` | `postgres` / `mysql` / `fhydra`（记忆/经验/知识/文档） |
| `llm_metaStore` | `f_store` | `postgres` / `mysql` / `f_store`（人格/技能/提示词/模型配置） |
| `llm_metaStorePath` | `./data/f_llm-meta` | 仅 `f_store` 用 |
| `llm_contentStoreUrl` | 空 | pg/mysql 连接串或 fhydra base url |
| `llm_embeddingUrl` | `http://127.0.0.1:8000` | BGE-M3 服务 |
| `llm_embeddingBatch` | 32 | 批量 |
| `llm_knowledgePandoc` | `pandoc` | 可执行路径 |
| `llm_knowledgeMaxChunkBytes` | 32768 | 单块正文上限 |
| `llm_fhydraUrl` | `http://127.0.0.1:8848` | fhydra 地址 |
| `llm_fhydraToken` | 空 | 鉴权 |
| `llm_toolIndexEnabled` | `true` | 是否为 `searchTools` 建向量索引 |
| `llm_toolIndexMaxTools` | 2000 | 超过后改用 fhydra（默认暴力扫） |
| `llm_channelInboundToken` | 空 | 通道回调 `/v1/channels/*` 的共享密钥 |
| `llm_emailAddress` | 空 | 智能体专用邮箱 |
| `llm_emailPop3Host` / `llm_emailSmtpHost` | 空 | POP3 / SMTP 主机（都要求 TLS） |
| `llm_emailUsername` / `llm_emailPassword` | 空 | 凭据；**不落库**，启动读取 |
| `llm_emailPollSeconds` | 60 | 收信轮询间隔 |
| `llm_emailSenderWhitelist` | 空 | 逗号分隔；为空表示只收系统内部邮件 |
| `llm_skillAutoEvolve` | `true` | 技能自演进开关（对所有技能生效） |
| `llm_skillEvolvePerDay` | 1 | 单技能每天最多自动升级次数 |
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
| 存储配置值未知 | **启动失败**，打印两个枚举的可选值；不静默回退默认 |
| 元数据 f_store 半写（有主体无索引） | 启动时按前缀扫主体补索引；单行 JSON 损坏则跳过并 `warn`，不整库失败 |
| 通道 MCP 不可达 | 该通道标记不可用，其它通道不受影响；入站回调返回 503 让 MCP 重试 |
| 邮件 POP3 认证失败 | 指数退避；连续 5 次失败停止轮询并告警，避免把邮箱锁死 |
| `searchTools` 的 embedding 不可用 | 退化为关键词匹配，响应 `degraded=true` |
| 技能升级引用了未注册函数 | 放弃本次升级，保留旧版本，记 `warn` 并累加失败计数 |

---

## 15. 测试计划

| 模块 | 关键用例 |
|---|---|
| Parser | 9 种 pandoc 格式各 1 个样本；PDF 三种质量分支；不支持格式报错 |
| 分块 | 标题优先切分；512+64 重叠；同文档重复导入 chunkId 不变 |
| Embedding | 三路返回解析；batch 部分失败重试；超时熔断 |
| 存储族 | 内容族三实现（pg/mysql/fhydra）跑同一套 conformance；元数据族三实现（pg/mysql/f_store）跑同一套；两族交叉组合各 1 例 |
| f_store 元数据 | 重启后人格/技能/提示词/配置仍在；写主体后崩溃、启动补索引；未知配置启动失败 |
| Memory | 内容族 conformance：增删改查 + 检索 + 分页 + 越权 + 权重打分 |
| 分层 | 工作空间记忆在另一工作空间不可见；全局记忆跨空间可见 |
| Character | 13 个预定义 key 可解析；custom 覆盖；`reset` 回落 default |
| 裁剪 | 8 策略 + TokenBudget 下首条 system 始终保留 |
| SQL | 同一份 DDL 在 PG/MySQL 各建一次；向量索引 `EXPLAIN` 命中 |
| 工具 | `memoryCall` 四动作；`callWithTimeout` 超时返回 `{}` 且标记取消 |
| loom | 计划生成→源码预览→编译→执行；环检测；越界工具拒绝；删除后 `unload` |
| 技能导入 | 含 sh 的包被拒；纯工具包成功入库；details 不含路径 |
| 定时 | cron 非法拒绝；注册后可触发；删除后不再触发 |
| 人格绑定 | 优先级 flow>task>workspace>user；解绑后回落；loom 计划里的 persona 落成 Flow 绑定 |
| 通道 | 入站按 message_id 去重；external_id 反查 user；`auto_send=false` 时拒绝直接外发 |
| 邮件 | POP3 拉取与 MIME 解析；附件走文档管线；白名单外发件人隔离；SMTP 频率/大小上限 |
| 工具发现 | `listTools` 覆盖全部注册项；`searchTools` 返回 topN 且可反序列化成 `FunctionCall`；embedding 失败降级 |
| 技能演进 | 2 条证据才结构升级；每天最多 1 次；回滚到旧版本；未知函数拒绝升级；人工技能只提建议 |

---

## 16. 分阶段实施

| 阶段 | 内容 | 前置 |
|---|---|---|
| P1 | `tables-pg.sql` / `tables-mysql.sql`、`ContentStore` / `MetaStore` 接口 + 内存测试替身 | 无 |
| P2 | PG/MySQL 内容族实现（SQL + 向量/倒排） | P1；MySQL 9.2+ 安装放 P6 |
| P3 | 人设 API + 13 提示词 + 首条 system 保护 + 人格绑定 | P1 |
| P4 | `memoryCall` / `knowledgeIngest` / `skillImport` / `schedule*` / `callWithTimeout` | P1–P3 |
| P5 | `loom` 包（计划/代码生成/两级 JIT/预览）+ 灵魂提示词版 planner | P4 |
| P6 | 安装 MySQL 最新版 + 向量索引，跑 MySQL 相关用例 | P2 |
| P7 | fhydra 实现（另一份文档） | P1 |
| P8 | `FStoreMetaStore`（人格/技能/提示词/配置），验证完全脱离 PG/MySQL 启动 | P1、P3 |
| P9 | 通道 MCP（微信/企微/飞书/钉钉/QQ）+ `llm_channel_binding` + 入站回调 | P4 |
| P10 | 智能体邮箱（POP3/SMTP，`f_email`） | P9 |
| P11 | `listTools` / `searchTools` + 工具向量索引 | P4 |
| P12 | 技能自演进（`SkillEvolutionTask` + 版本表 + 回滚） | P10、P4 |

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

### 17.1 2026-10-29 追加决策

| 决定 | 落点 |
|---|---|
| 存储拆成**内容族**（记忆/经验/知识/文档）与**元数据族**（人格/技能/提示词/配置），各自三选一、可交叉组合 | §5.3 |
| 元数据族提供 **f_store** 实现，使 f_llm 可完全脱离 PostgreSQL/MySQL 运行 | §5.3.1 |
| 两族都通过统一接口访问，开发者可注册自己的实现；选型只由 `f_config` 决定 | §5.3.2 |
| 微信 / 企业微信 / 飞书 / 钉钉 / QQ / 邮件以**独立 MCP 服务**接入，按用户收发 | §8.7 |
| 智能体专用邮箱走 POP3/SMTP（`f_email`），只处理白名单发件人 | §8.7.1 |
| 新增 `listTools`（全量）与 `searchTools`（bge-m3 向量 topN） | §8.8 |
| 技能自演进对**所有**技能生效（导入/反哺/人工），带版本与回滚 | §10.4 |
| 人格可绑定到工作空间/任务/流程，优先级 flow > task > workspace > user | §7.4 |
| loom 计划新增 `persona`；planner 提示词按「灵魂提示词」重写（中文） | §9.10、§12.4 |

剩余未决：**无**（本轮问题全部收敛；后续如出现新问题再单列）。
