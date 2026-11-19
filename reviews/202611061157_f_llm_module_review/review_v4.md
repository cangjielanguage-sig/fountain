# R4：loom 内「总结新经验 / 新记忆」写闭环审查

审查时间：2026-11-06（只读）

## 审查范围

`src/loom/LoomMemoryPolicy.cj`（policy + extractor 全文）、`LoomContextLog.cj`、`LoomRunner.cj:133-240`、`LoomHostApi.cj:112-142`、`LoomStoreGateway.cj:67-150,358-365`、`LoomWiring.cj:55-98,122-148`、`LoomAgent.cj:129-132`、`SkillEvolutionJob.cj:99-118,231-300`；
测试 `LoomContextMemory_test.cj`、`LoomMemoryE2E_test.cj`、`LoomPersona_test.cj`；文档 `doc/loom.md:236-260`、`doc/f_llm.md`、`doc/f_llm-memory-design.md`、`README.md`。

## 结论速览

| 目标 | 结论 |
|---|---|
| 生命周期 begin→record→snapshot→clear→unbind→extract | 已实现（begin 在 try 外的边界瑕疵） |
| 产出格式 / summarize 回落 / writeKnowledge docId | 部分（回落路径失效、中文截断抛异常、docId 重启撞号） |
| policy 十个开关 | 已实现（仅 `skillMinScore` 未进 doc/loom.md 表格） |
| 写入走统一网关 | 已实现（全程 `LoomHostApi.callStore`） |
| 经验→演进消费 | 部分（kind/水位线正确，参数解耦 + 500 上限丢样本） |

## 发现

### [严重] `truncate` 用字节切片，中文正文大概率抛异常，整次提炼静默丢失

- **位置**：`src/loom/LoomMemoryPolicy.cj:223-228`（调用点 `:104` 600、`:184/:186/:187` 300/400/400）
- **证据**：`text[0..limit]`；仓颉 `String[Range]` 是字节区间且要求字符边界，`String.size` 是 UTF-8 字节数。中文 3 字节/字，`limit=400` 命中边界概率约 1/3。
- **影响**：`digestOf` 在两次 write 之前执行，异常使 `extract` 中断 → note 与 experience 都不写；`LoomRunner.cj:227-233` 又 `catch{ () }` 吞掉。
- **同类**：`src/store/KnowledgeChunker.cj:48-50` 同写法，中文长记忆 `knowledge.upsert` 也可能抛，被 `LoomMemoryPolicy.cj:130-135` 吞掉。
- **建议**：改 rune 安全截断（项目内正确写法：`src/tool/WebFetchFunction.cj:83-92`），补中文超长用例。

### [严重] `summarize=true` 且模型返回非法 JSON 时「回落规则提炼」实际不生效

- **位置**：`LoomMemoryPolicy.cj:106-114`、`:194-210`
- **证据**：`parse` 失败返回 `['','']`，`extract` 无条件覆盖 `memory/parsed[0]`、`experience/parsed[1]`；`write` 因内容空返回 false → 两条都不写。模型只给 memory 时经验也丢。
- **文档矛盾**：`doc/loom.md:34`、`README.md`、`doc/f_llm-memory-design.md` 均承诺「非法 JSON 回落规则提炼」。
- **测试缺口**：`LoomContextMemory_test.cj:206-225` 只覆盖合法 JSON。
- **建议**：按字段独立回落（空则用规则提炼结果）。

### [一般] `writeKnowledge` 的 docId 序号是进程内计数器，重启后撞号覆盖

- **位置**：`LoomMemoryPolicy.cj:126`、`:140-151`
- **描述**：`seq` 是 static var，不落库、不按用户分区；重启从 0 开始，`loom:<流程>:1` 与上次同 id，`upsert` 按 docId 覆盖；多用户共用计数器。
- **建议**：docId 带时间戳/runId 或持久化计数器，前缀补 userId/namespace。

### [一般] `LoomMemoryPolicy.current` 是可变态全局单例且无锁

- **位置**：`LoomMemoryPolicy.cj:68-80`；装配 `LoomWiring.cj:82-85`
- **描述**：`current` 静态 var，install/reset/effective 未加锁（对比 `LoomContextLog`/`LoomHostApi` 都用 Mutex）；两服务共存时后装覆盖；并发/定时触发存在数据竞争；测试靠全局改状态、顺序敏感。
- **建议**：作为 LoomRunner/LoomService 字段传入，或至少加锁 + 文档写明进程级单例。

### [一般] 演进读端与写端归属参数完全解耦，闭环易断

- **位置**：写端 `LoomMemoryPolicy.cj:38-39`；读端 `LoomWiring.cj:57-58,143-146`
- **描述**：memoryPolicy(userId 7/work) + evolutionUserId 默认 0/loom → 演进永远读不到经验，无告警。
- **建议**：未显式给 evolutionUserId 时从 memoryPolicy 派生，或启动校验一次。

### [一般] 演进素材 `limit=500` 硬上限 + 水位线无条件推进，超量样本永久跳过

- **位置**：`SkillEvolutionJob.cj:258-263`、`:231-234`
- **描述**：每 kind 最多 500 条，结束后无条件 `markRun(now)`；超出部分从未读取且水位线已越过。另有 `at` 退化为 id（`:290-291`）时会被 `fresh()` 判旧丢弃。
- **建议**：按 at 升序取 N 且水位线推进到「已处理最大 at」。

### [一般] 知识侧素材不按用户/命名空间过滤，跨租户知识进入某用户演进

- **位置**：`SkillEvolutionJob.cj:262,299-302`
- **描述**：`knowledgeOf` 只按 offset/limit 取全部 docId；`KnowledgeDoc` 无 userId/namespace；`writeKnowledge` 写的记忆内容进全局知识库，进而进所有人演进池。
- **建议**：知识文档补 owner 字段，或按 docId 前缀过滤。

### [一般] 提炼失败全程静默，无观测点

- **位置**：`LoomMemoryPolicy.cj:163-169`、`:130-135`、`LoomRunner.cj:227-233`
- **描述**：三层 catch 吞异常，`extract` 的 written 计数被丢弃；上述两个严重缺陷正被此设计藏住。
- **建议**：至少记录 written 与异常计数日志或写入流程结果元数据。

### [轻微] `outcome` 归一化是空操作

- **位置**：`LoomMemoryPolicy.cj:101`
- **描述**：两分支等价于直接 outcome；任何非 success 都落 experience_failed 且原串入正文。
- **建议**：直接赋值或显式白名单。

### [轻微] `begin()` 在 try 之外，异常时活动标志残留

- **位置**：`LoomRunner.cj:204-209`
- **描述**：`begin()` → `bind()` → `try{}`；bind 抛异常则 active 保持 true、turns 已重置；begin 无条件重置全局 turns，嵌套/并发互相清空。
- **建议**：bind/begin 进 try，finally 统一清理，或 begin 前断言未激活。

### [轻微] 测试覆盖缺口

- **已有**：`LoomContextMemory_test.cj`（note+experience+answer-2、success、failed、disabled、writeKnowledge、summarize、flow-end 不演进）、`LoomMemoryE2E_test.cj:387`、`LoomPersona_test.cj:230-248`。
- **缺口**：① summarize 非法 JSON 回落；② maxTurns 与 `[n]` 序号；③ 标题字面与 kind 双条断言；④ writeKnowledge 二次执行不覆盖；⑤ 中文超长正文；⑥ skillTopK/skillMinScore 边界；⑦ enabled=false 时 autoSkills 行为。

## 统计

| 严重 | 一般 | 轻微 |
|---|---|---|
| 2 | 6 | 3 |

**总评**：生命周期骨架扎实（finally 收尾、catch 先置 failed 再重抛、先清空再提炼），写入也统一走网关；两个严重项都在打磨层但后果同为静默丢数据（中文截断异常、非法 JSON 不回落），且被三层 catch 掩盖，现有 7 条用例未捕获。
