# 记忆、知识、技能与人格设计

> 只描述**当前实现**。存储选型与键布局见 `doc/f_llm.md` §4；编排流程与网关 op 见 `doc/loom.md`；
> 演进的多进程互斥见 `doc/loom.md`「每日租约」。

## 0. 数据分类与边界

| 类别 | 回答什么问题 | 主要 kind / 载体 | 生命周期 |
|---|---|---|---|
| 记忆 | 这次任务发生了什么、确认了什么 | `note` 为主（也含 `fact` / `preference` / `task` / `doc` / `knowledge` / `session`） | 长期，按用户 + 命名空间累积 |
| 知识 | 可被检索的文档内容 | `KnowledgeDoc` + 切块 | 长期，按 `docId` 覆盖 |
| 经验 | 这次做成了没有、下次怎么复用 | `experience` / `experience_failed` | 长期，作为技能演进的素材 |
| 技能 | 可复用的做法（可被注入 system） | `Skill(id/title/details/functions/version)` | 长期，版本递增 |
| 人格 | 用户偏好的说话风格与附加要求 | `Character(userId/characterKey/prompts)` | 每用户一条 |
| 提示词 | 可版本化的正文片段 | `PromptEntry(name/version/content)` | 按 name 累积版本 |

边界规则：

- 记忆与经验共用 `MemoryStore`（经验就是 `kind=experience` 的记忆），不另开接口；
- 知识走 `KnowledgeStore`，带切块与向量，和记忆的检索通道不同；
- 技能是**被演进的对象**，人格与提示词只影响 system 前缀，不参与检索。

## 1. 落点

| 类别 | 契约 | 内容族 / 元数据族 |
|---|---|---|
| 记忆、经验 | `MemoryStore` | 内容族 |
| 知识 | `KnowledgeStore` | 内容族 |
| 技能 | `SkillStore` | 元数据族 |
| 人格 | `CharacterStore` | 元数据族 |
| 提示词 | `PromptStore` | 元数据族 |

内容族与元数据族各自三/五种实现，选型见 `doc/f_llm.md` §4.1。切换后端不改业务代码，只改 `llm_memoryStore` / `llm_metaStore`。

## 2. 记忆

### 2.1 kind 体系

7 个预定义：`note` / `fact` / `preference` / `task` / `doc` / `knowledge` / `session`（`MemoryKinds.predefined()`）。

- 每个 kind 有一个权重（`MemoryKinds.weightOf(kind)`）；SQL 记忆实现检索时把它乘进融合分数，其余后端按自身打分口径处理；
- 自定义 kind 按用户注册：`MemoryKinds.register(userId, kind)`，落 `llm_memory_kind`（`predefined=false`），启动时 `attach(persistence)` 载回；
- 预定义 kind 不可删除（`remove` 抛 `IllegalArgumentException`）；
- 落库失败只告警，不阻断业务。

### 2.2 写入路径

| 路径 | 入口 | 写入内容 |
|---|---|---|
| 流程结束提炼 | `LoomMemoryExtractor.extract` | 标题 `流程 <name> 记忆`，`kind=note` |
| 流程内显式写 | `loomStore("memory","add")` / `memoryCall` | 调用方指定的 title/content/kind |
| 会话摘要 | `Memory.remember(session, summary)` | 默认 `namespace=loom`、`kind=session`，可传参覆盖；优先走装配的存储网关，未装配回落适配器 |
| 内容族 API | `MemoryStore.add(MemoryWrite)` | 同上，不经提炼 |

### 2.3 摘要格式与截断

`note` 的正文是**逐轮摘要**，不是语义压缩（除非开 `summarize`）：

```
结果：success
流程 <name> 的上下文摘要：
[1] model=deepseek-chat
system: …（截断 300 字符）
input:  …（截断 400 字符）
output: …（截断 400 字符）
[2] …
```

- 只取最近 `maxTurns` 轮（默认 20）；
- 只记 LLM 交互（`callLlm`），工具调用不进摘要；
- 截断统一用 `truncate(text, limit)`：超长时保留前 `limit` 字符并追加 `…`。

### 2.4 检索与融合

`MemoryStore.search(MemoryQuery)` → `ArrayList<MemoryHit>`：

| 字段 | 含义 |
|---|---|
| `record` | 命中的记忆（含 `saveTime`） |
| `score` | 融合分数，降序 |
| `degraded` | `true` 表示某一路向量缺失，分数只由剩余通路融合 |

融合是 dense + sparse 两路；某一路为空时结果仍返回但标记 `degraded`，调用方据此判断可信度。
`f_hydra` 部署下 `kind` 过滤下推到服务端（记录写入时把 `kind` 写进 `filters`，查询走倒排）。

## 3. 知识

### 3.1 写入与切块

`knowledge.upsert(docId, title, content)`：

1. 落 `KnowledgeDoc`（按 `docId` 覆盖）；
2. `KnowledgeChunker.split(content, maxChars: 400, overlap: 50)` 按字符滑窗切块，`overlap` 必须落在 `[0, maxChars)`；
3. 逐块编码并落块表（`llm_document_chunk`）。

切块单位是**字符**（rune）而非字节：同一段中文按字节切会落在字符中间并抛异常。历史数据若按旧的字节口径切过，建议按 `known-limitations.md` §5 重建索引后再检索。

### 3.2 检索

`KnowledgeStore.search(KnowledgeQuery)` 是**块级**召回，返回 `KnowledgeHit`（块内容 + 所属 `docId` + 分数）：

| 后端 | 召回方式 |
|---|---|
| `postgres` | pgvector 距离 + 词面候选加权 |
| `mysql` | MyVector `MYVECTOR_IS_ANN` + 词面候选加权（需先 `myvector_index_build`） |
| `f_hydra` / `fhydra` / `inMemory` | 进程内/本地向量比对 + 词面加权 |

词面加分是常量（`0.1 × 命中加权`），没有调参入口——见 `known-limitations.md` §8。

### 3.3 重建

`KnowledgeIndexRebuilder.rebuild(...)` 按 `docIds` 分页重算块向量；`MemoryIndexRebuilder` 重算记忆的 sparse / colbert。
两者都不会自动触发，需要显式调用或开 `llm_rebuildIndexOnStart`。

### 3.4 与记忆的边界

| 维度 | 记忆 | 知识 |
|---|---|---|
| 粒度 | 一条一条的记录 | 文档 → 块 |
| 写入者 | 流程提炼、显式写 | `knowledge.upsert`、`knowledgeIngest` |
| 检索返回 | 整条记录 | 命中块（同文档可能多块） |
| 用途 | 让模型知道「上次怎么做」 | 让模型知道「资料怎么写的」 |

同一份内容不要两边都写：进知识库的文档不必再写一条记忆，反之亦然。

## 4. 经验

### 4.1 kind 与内容

| kind | 何时写 |
|---|---|
| `experience` | 流程成功 |
| `experience_failed` | 流程失败（`outcome=failed`） |

正文很短：

```
结果：success
流程 <name> 执行了 N 次模型交互，
最后一次输出：
…（截断 600 字符）
```

取「最后一次输出」而不是全量摘要，是因为它通常就是流程产物，对「下次怎么做」参考价值最高。

### 4.2 到技能的链路

经验在写入时**不绑定技能**（那时还不知道属于谁，技能也可能尚不存在）。绑定发生在演进阶段：
`SkillEvolutionJob` 按水位线取新增经验与知识 → `SkillMatcher` 归属 → 演进或新建。详见 `doc/loom.md` §7。

## 5. 技能

### 5.1 数据

`Skill(id, title, details, functions, version)`，五个字段都不可变，改一次就是一条新版本记录。

| 字段 | 用途 |
|---|---|
| `title` | 唯一标识，也是 `skill.load` 的入参 |
| `details` | 正文，注入 system 的那段 |
| `functions` | 技能包的附加元数据（含 `samples`，供 A/B 门禁用） |
| `version` | 每次演进 +1 |

### 5.2 写入

| 方式 | 结果 |
|---|---|
| `skill.upsert`（网关） | `id<=0` 视为新建，取当前最大 id + 1 |
| `SkillImporter` | 导入技能包目录：`skill.json`（title/acceptedEvent/returnedEvent/metadata/version）+ `details.md`，同名 title 幂等 |
| `SkillEvolutionJob` | 改正文，版本 +1；新技能 `version=1` |

### 5.3 检索与注入

`SkillCatalog.search(query, topK, minScore)`：

- 装了编码器 → 向量余弦（技能向量按 `标题#版本` 缓存，正文变了自然失效）；
- 未装或编码失败 → 关键词（词面包含 / 字符命中比例 / 标题覆盖比例）。

选中的技能拼进 system：

```
可用技能：
- 日报助手：先列三段式，再给数据
- 代码评审：只挑错，不给出修改建议
```

编码失败会静默降级，读 `SkillCatalog.embedFailureDetail()` 判断实际走向。

### 5.4 演进（摘要）

策略：样本 ≥ 3、成功率 ≥ 0.8、冷却 1 天（门禁失败后 2 天）。
门禁：用 `functions.samples` 分别跑旧版/新版，`新版 ≥ 旧版` 且 ≥ `minScore`（默认 0.6）才放行；无样例直接拒绝。
命名：标题 ≤ 24 字、至少 1 条样例、不与已有冲突。

完整流程见 `doc/loom.md` §7。

## 6. 人格与提示词

### 6.1 character 记录

`Character(userId, characterKey, prompts)`，每用户一条：

| 字段 | 含义 |
|---|---|
| `characterKey` | 必须是 13 个预定义之一，或 `custom` |
| `prompts` | 用户级附加要求（语言、篇幅等），非空时追加在人格正文之后 |

写入前校验 `characterKey`：未知值抛 `unknown character key`。

### 6.2 13 个预定义人格

正文固化在 `PredefinedCharacters.bodyOf(key)`（`store/PredefinedCharacters.cj`），此处只列定位：

| key | 名称 | 定位 |
|---|---|---|
| `default` | 默认 | 空字符串，不注入 |
| `rigorous` | 专业严谨 | 先结论后依据，术语准确，不确定要标注，禁止编造 |
| `friendly` | 亲和友善 | 先回应感受，再给可执行建议，口语化 |
| `blunt` | 直言不讳 | 直接指问题，不礼貌性肯定，只评价方案不评价人 |
| `imaginative` | 天马行空 | 三个以上非常规思路，标可行性，区分事实与推测 |
| `pragmatic` | 高效务实 | 最短可执行路径，步骤必须可直接执行 |
| `sarcastic` | 毒舌吐槽 | 可吐槽方案，之后必须给正确做法 |
| `coaching` | 启发引导 | 用问题帮用户澄清，不直接给答案 |
| `gentle` | 温柔体贴 | 语气柔和，分小步给建议，先共情 |
| `sweet` | 软萌甜妹 | 语气活泼，技术内容不因萌化而省略 |
| `aloof` | 高冷御姐 | 话少、笃定、不寒暄，追问才展开 |
| `sunny` | 阳光开朗 | 先肯定可做之处，鼓励要具体 |
| `whimsical` | 鬼灵精怪 | 刁钻角度切入，玩笑后必须给准确结论 |

`custom` 不在表内：正文只来自 `character.prompts`，两者都空就等于不设置人格。

修改人格文案只改 `PredefinedCharacters.bodyOf` 一处，文档不复制正文，避免两处漂移。

### 6.3 提示词库

`PromptEntry(name, version, content)`：

- `prompt.put`：`version<=0` 表示接在最新版本之后（自动 +1）；
- `prompt.latest`：取最新；
- `prompt.get(name, version)`：按版本取；
- `prompt.remove(name, version)`：删除后重算最新指针。

### 6.4 解析优先级

```
plan.persona 非空？
 ├─ 是 → 1) prompt.latest(persona) → 2) PredefinedCharacters.bodyOf(persona) → 3) 字面文本
 └─ 否 → character.get(userId).characterKey → 同一条三级链
              ↓
      追加 character.prompts（非空时）
              ↓
      拼在步骤自己的 system 之前
```

要点：

- 第 2 级必须有：预定义 key 的正文不在 prompt 库里，跳过这一级会把 `rigorous` 这个单词当人格；
- `custom` 是特例，直接置空再靠 `prompts` 填充；
- 角色记录按 `LoomMemoryPolicy.userId` 取，`userId<=0` 跳过，不查库。

### 6.5 注入位置

```
<人格正文>

<character.prompts>

可用技能：
- …

<步骤自己的 system>
```

人格与技能都是「前缀」，不进入用户消息；裁剪策略作用于消息列表，这层前缀由 `LoomHostApi` 在调用模型前拼接。

## 7. 提炼提示词

`summarize=true` 时用模型提炼，提示词在 `LoomMemoryExtractor` 内联：

```
以下是流程「<name>」执行过程的模型交互摘要：
<digest>

输出 JSON，不要解释：
{"memory":"这次任务用到了哪些事实与结论","experience":"下次可复用的做法或踩过的坑"}
```

- system 为空，只发 user；
- 返回值用 `Planner.stripFence` 去掉代码围栏后解析；
- 解析失败或两字段皆空 → 回落规则提炼（不写空记录）。

各环节的提示词位置：

| 环节 | 位置 |
|---|---|
| 记忆/经验提炼 | `LoomMemoryPolicy.cj` 内联 |
| 技能正文改写 | `SkillEvolutionJob.cj` 内联（`现有技能正文：…\n近期使用情况：…`） |
| 技能命名 | `SkillNamer.cj` 内联（要求返回 `{title, details, samples}`，title ≤ 24 字） |
| 门禁评分 | `SkillGate.cj` 内联（system = `按以下技能正文完成任务：\n<details>`，命中 `expect` 记 1 分） |

## 8. 失败与观测

| 场景 | 行为 | 观测点 |
|---|---|---|
| 记忆写入失败 | 跳过，不影响流程 | `warn` 日志 |
| 编码器失败 | 技能检索退关键词 | `SkillCatalog.embedFailureDetail()` |
| 某路向量缺失 | 用剩余通路融合 | `MemoryHit.degraded` |
| 提炼模型返回非法 JSON | 回落规则提炼 | 无异常抛出 |
| 人格 key 非法 | 写入时抛错 | `unknown character key` |
| 知识块索引未建（MySQL） | ANN 召回不可用 | 需手工 `myvector_index_build` |

## 9. 数据流总览

```
流程执行
 ├─ 每次 callLlm → LoomContextLog（临时）
 ├─ 显式写 → memory.add / knowledge.upsert（立即生效）
 └─ 结束（finally）
      ├─ note        「流程 X 记忆」
      ├─ experience  / experience_failed
      └─ 可选 knowledge「loom:X:N」

每日演进（SkillEvolutionJob）
 ├─ 读水位线后的 experience + knowledge
 ├─ SkillMatcher 归属 → 演进 / 新建
 ├─ SkillGate A/B → 通过则版本 +1
 └─ 写报告 + 推进水位线 + 标记知识已消费

下一次执行
 ├─ character → prompt/内置正文 → persona
 ├─ SkillCatalog 检索 → 技能注入
 └─ 检索记忆 / 知识 → 拼进 input
```
