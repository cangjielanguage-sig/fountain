# f_llm 模块审查报告

> **模块第 18/25 部分**（本报告只覆盖 `files/f_llm.part18.txt` 列出的 20 个文件：`src/loom/{Supervisor_test,ToolCatalog,ToolFunctions,ToolFunctions_test,ToolScope}.cj`、`src/macros/ToolCall.cj`、`src/mcp/{McpToolSource,McpToolSource_test}.cj`、`src/memory/{FaithfulMemory,Memory,MemoryExtractor,MemoryRemember_test,imports}.cj`、`src/model/{Code,CodeParam,Knowledge,KnowledgeParam,SkillReferenceParam,Specification}.cj`、`src/model/entity/KnowledgeEntity.cj`。全部为 `.cj`，本部分不含 `.md`。其余 24 部分由主 Agent 合并。）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个 `.cj` + 0 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 全部问题记「存量」）
- **审查重点**：LLM 客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG（本部分实际覆盖面：`memory` 包的后台摘要定时器与落盘、`ToolCatalog`/`ToolFunctions` 工具检索、`ToolScope` 白名单、`mcp` 适配、`model` DTO）
- **报告版本**：v1（第 18/25 部分）

## 发现

### [严重][存量] #1 `FaithfulMemoryImpl.summarise` 把"按 session 主序"的键序当成"按时间序"，`break` 让字母序靠后的会话永远不被摘要

- **位置**：`f_llm/src/memory/FaithfulMemory.cj:77-79`（`if(time >= earlierThan){ break }`）、`:68-70`（前缀遍历）、`:72-76`（键解析）、`:100-102`（循环结束，无收尾 flush）；键构造在 `:42-44`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「逻辑错误 / 边界」、§6.4（已知结构却按错误假设做提前退出）
- **证据**：静态确定 —— 内容键格式是 `'FaithfulMemory:${session}:${time}:${role}'`（`:43`），前缀遍历的底层是 `ConcurrentSkipListMap`（`f_store/src/MemTable.cj:20`）经 `PrefixIterator` 归并（`f_store/src/PrefixIterator.cj:19-45`，比较器 `mergeHeapCmp` 见 `f_store/src/SSTableMerger.cj:30-35`，注释明确"全局有序输出（按 key 字典序升序）"），所以遍历顺序是 **session 主序、session 内时间序**，不是全局时间序。举 4 条键：
  `A:01-01`、`A:01-02`、`B:01-01`、`B:01-02` → 遍历顺序即此。若 `earlierThan = now-8h`，处理到 `A:01-02`（新于阈值）就 `break`，**整个 B 会话一条都读不到**，即使 `B:01-01` 早已超过阈值。结论：一次运行只覆盖到「第一个含新消息的 session」为止，该 session 之后的字母序会话在任何一次运行里都达不到。
- **描述**：`break` 的语义前提（"后面都更新"）只在全局时间序下成立。实际后果有两层：
  1. **功能静默丢失**：每次运行只处理到"字母序最靠前、且其内部出现第一条新消息"的那个 session 为止，它之后的会话一条都读不到（只有当前面若干会话全部是旧消息时，它们才会被依次处理）；读不到就没有任何日志，因为 `fn` 只在 `else if` 分支才被调用。
  2. **末批永不 flush**：循环体内只在"session 变化"时 flush（`:86-99`），循环结束后（`:100-102`）没有对 `messages` 再 flush 一次，因此触发 `break` 的那个 session 已累积的消息既没摘要、也没清理，只能等下一次运行重新读一遍（叠加 #2 的清理失效 ⇒ 每天重复调用 LLM）。
- **建议**：把"时间窗"判断改成"跳过而不终止"（`if(time >= earlierThan){ continue }` 语义上仍不对，因为同一 session 内新旧混排）；正确做法是先按 session 分组（遍历完整个前缀、把 `session → [(time, role, msg)]` 收进内存，或用两级键 `FaithfulMemory:{time}:{session}:...` 让时间成为主序），再对每个"全组都早于阈值"的 session 调 `fn`；循环结束补一次收尾 flush。分组实现要给出 session 数量上限，避免把整库拉进内存（见 §5）。

### [严重][存量] #2 摘要成功后按"当前条目的时间"删内容键 —— 旧内容键永不删除，存储无界增长且每天重复摘要

- **位置**：`f_llm/src/memory/FaithfulMemory.cj:86-92`（关键在 `:90` `store.remove(contentKey(timeStr, session, m.role))`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「读了不用 / 用错变量」、§5「无界容器 / 全局集合只增不减」
- **证据**：静态确定 —— `timeStr` 在 `:74` 取自**当前这一条**键（即"下一个 session 的第一条"），而 `messages` 里装的是**上一个 session** 各条消息；`contentKey(time: String, session, role)`（`:42-44`）把三者拼成键。于是 `remove` 拼出的键是"旧 session + 新时间"，这个键从不存在，`Store.remove` 是幂等空操作（`f_store/src/Store.cj:136-146`，写一条 tombstone，不报错）。同一循环里 `duplicateKey` 用的是 `m.content`，是对的（`:89`），只有内容键删错。
- **描述**：会话被"摘要"之后，内容键全部留在 `llm_faithfulMemoryPath` 指向的 LSM 存储里，只有重复键（`DuplicateMemory:*`）被删。后果：
  1. 存储只增不减（`#1` 修好之后就是全量会话累积）；
  2. 这些内容键下次运行仍满足 `time < earlierThan`，会被再次读出来、再次调 LLM、再次 `remember(session, jsonstr)`（`Memory.cj:81`）写一条 `kind=session` 的记忆 —— **重复的记忆数据 + 重复的 token 成本**；
  3. 因为没有正确删除，`add` 的"重复内容"保护只对 `duplicateKey` 生效，对摘要侧完全不起作用。
- **建议**：把每条消息自己的时间一起带进 `messages`（改成 `ArrayList<(String, Role, String)>` 或一个小 struct），flush 时用该条自己的 `time` 删；或者反过来把 `time` 编进 `ChatMessage` 的附属结构。补一条用例：同一 session 写入 3 条消息 → 触发 summarise → 断言 `store.prefix('FaithfulMemory'.unsafeBytes())` 已空（或只剩未到阈值的条目）。

### [严重][存量] #3 内容键只精确到毫秒且包含 role —— 同毫秒同角色的两条消息互相覆盖，记忆永久丢失

- **位置**：`f_llm/src/memory/FaithfulMemory.cj:36-38`（`FULL_DATE_FORMAT = 'yyyyMMddHHmmssSSS'`，`current(now)`）、`:53`（`contentKey(DateTime.now(), ...)`）、`:55-58`（`contains` 后 `add`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 数据丢失」、§12.1「检查-然后-写入」
- **证据**：静态确定 —— 键 = `session + 毫秒时间戳 + role`，对 `(session, role)` 相同、时间戳落同一毫秒的两条消息，键完全相同；`Store.add` 是覆盖写（`f_store/src/Store.cj:97-107` 返回旧值、`MemTable.add` 直接 `ConcurrentSkipListMap.add` 覆盖），所以后写的一条把前一条的 value 直接替换掉，前一条消息在存储里不存在。触发路径现成：`Memory.add(session, all!)`（`Memory.cj:145-151`）在**一个紧循环**里连续写同一事件的全部消息，`messages` 里连续出现同 role（多个 `tool` 消息、多段 `assistant` 消息）很常见，两次 `store.add` 落在同一毫秒并不需要极端条件。
- **描述**：除了覆盖，`:55-58` 的 `contains(duplicateKey)` → `add` 也是非原子的"检查-然后-写入"：两个事件并发写同一条内容时会各写一条内容键 + 一条重复键（重复键相同，第二次互相覆盖，无害；内容键不同毫秒则产生两条重复记忆）。**碰撞发生率需实测**（把 `add` 的时间戳与内容打点统计同毫秒同 role 的比例），但"键不唯一 ⇒ 必丢一条"是静态成立的。
- **建议**：键里加单调序号或内容哈希（例如 `...:${time}:${role}:${md5(content)[0..8]}`），并在 `Store` 之上不再依赖"毫秒级时间戳唯一"；或直接把消息写成 `add` 返回的 `sequence`（`Store.add` 内部有 `AtomicInt64` 序列号，但未暴露）。同时把接口注释里的"同 session 同 role 同毫秒只保留最后一条"写清楚，或改成 `ArrayList` 值追加。

### [严重][存量] #4 每日摘要跑在 `Timer` 任务里且没有任何异常保护 —— 一次失败就让摘要功能永久失效

- **位置**：`f_llm/src/memory/Memory.cj:26-29`（`timer = Timer.after(nextSummarisingTime()) { faithful.summarise(Memory.summarise); nextSummarisingTime() }`）；异常源：`Memory.cj:70`（`.messages[0]`）、`:78`（`JsonValue.fromStr(jsonstr)`）、`:42-45`（`lookup` 未命中即抛）、`FaithfulMemory.cj:55/89`（`Store` 抛 `StoreClosedException` 等）、`MemoryExtractor.cj:28/38/41`（`asObject`/`asString`/`asArray` 抛 `JsonException`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「异步语义：`Future` 异常被吞 / 定时任务」、§3「静默失效」，依据标准库文档 `std/sync/sync_package_api/sync_package_classes.md:10750-10792`（`Timer.after`）与 `:10726-10748`（`class Timer` 注意事项）
- **证据**：静态确定 —— 文档原文：「[Timer] 不会主动捕获关联 Task 抛出的异常。只要 Task 有未被捕获的异常，[Timer] 就会失效。」`Memory.summarise` 内部没有任何 `try`，`FaithfulMemoryImpl.summarise` 也没有，异常会直接穿出 lambda，`Timer` 从此不再调度，进程不重启就再也不同步摘要，且**没有任何日志**（`atExit(timer.cancel)` 只是退出时取消，不会重建）。
  可达的抛出点按概率排序：`LLM.chatByName(...)` 网络/鉴权失败抛 `LLMException`；模型返回里没有代码围栏时 `indexOf/lastIndexOf` 走 `None` 分支是安全的，但围栏内不是合法 JSON 时 `JsonValue.fromStr` 抛 `JsonException`；`respmsg` 的 `messages` 为空时 `[0]` 抛越界；`llm_summarisingActionKind` 配成 `experience`/`individuality` 时 `lookup<ExperienceFinder>()` 抛 `BeanException`（见 #9）。
- **描述**：这是"后台功能静默死亡"型缺陷：白天一切正常，第二天发现经验/摘要不再更新，也没有告警可查。
- **建议**：把任务体包成 `try { ... } catch(e: Exception) { LoggerFactory...warn(...) }`，并把"是否继续调度"与"本轮是否成功"解耦（失败也返回下一次延迟）；`Memory.summarise` 内部再按阶段细化：LLM 调用失败只 warn、JSON 解析失败只 warn 并返回 `false`（让 `FaithfulMemoryImpl` 保留消息）。同时把 `.messages[0]` 改成 `match` 取首条，`:78` 的 `JsonValue.fromStr` 包 `try`。

### [一般][存量] #5 用会抛异常的 `asString` / `asArray` / `asObject` 解析模型输出，形状稍偏就整条链路抛错

- **位置**：`f_llm/src/memory/MemoryExtractor.cj:26-29`（`json.asObject()`）、`:38`（`jsonobj.get(key)?.asString().value`）、`:41-47`（`?.asArray().getItems()`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「空值 / 类型不符未处理」、§10 正确性（外部输入未校验）
- **证据**：静态确定 —— 语义以 `f_data/src/json/JsonValue.cj:53-67` 为准：`asString` / `asArray` / `asObject` 在类型不符时 **`throw JsonException`**（不是返回 `Option`）。而这里的 `jsonobj` 完全来自 LLM 结构化输出的 `JsonValue.fromStr`（`Memory.cj:78`），字段缺失走 `?? ''` 是安全的，字段类型不符（`"steps": "..."`、`"purpose": 1`、`lessons: [ "字符串" ]`）则直接抛。叠加 #4 就是"模型偶尔不按 schema 输出 ⇒ 当天之后摘要永久停止"。
- **描述**：提示词（`MemoryExtractor.cj:99-123`）已声明"严格按照 JSON 格式返回"，但没有强约束（非 `response_format` 校验），实际模型抖动很常见。
- **建议**：改成 `jsonobj.get(key)` + `match(item){ case Some(x: JsonString) => x.value; case _ => '' }` 的形态（参照 `f_llm/src/loom/ToolCatalog.cj:104-119` 的 match 风格），`extractArray` 用 `match` 判 `JsonArray` 后逐项过滤非字符串。

### [一般][存量] #6 模型回答里找不到代码围栏时 `summarise` 仍返回 `true`，消息被当作"已摘要"丢弃

- **位置**：`f_llm/src/memory/Memory.cj:71-83`（`if (let Some(start) <- ... && let Some(end) <- ...)` 之后无条件 `true`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3「空实现 / `case None => ()` 把错误吃掉」、§11「失败路径当成功」
- **证据**：静态确定 —— `respmsg` 只有 1 个 ` ``` `（模型没按格式输出）时 `lastIndexOf('```', start+3)` 返回 `None`（文档 `std/core/core_package_api/core_package_structs.md:7448-7463`：从 `fromIndex` 起找不到即 `None`），整个 `if` 不成立，跳过 `extractor.extract` 与 `remember`，函数仍 `return true`。调用侧 `FaithfulMemory.cj:86` `else if(fn(...))` 为真 ⇒ 直接进入"删除内容键"分支（虽然键删错了，见 #2）。
- **描述**：失败被表示为成功，且比 #5 更隐蔽（不抛异常、不打日志）。同类小问题：`sub.startsWith('json')` 后 `sub[4..]`（`:73-77`）在 `sub == 'json'` 时得到空串，`JsonValue.fromStr('')` 抛异常（回到 #4 的链路上）。
- **建议**：解析失败返回 `false` 并 `warn` 一条带 `session` 与回复前 200 字符的日志；`sub[4..]` 加 `sub.size > 4` 判断。

### [一般][存量] #7 `ToolScope` 白名单校验没有任何生产调用点 —— 文档承诺的"只能收窄，不能凭空引入"未接线

- **位置**：`f_llm/src/loom/ToolScope.cj:36-55`（`check`）、`:57-82`（`verifyPlan`）；承诺源 `f_llm/doc/f_llm.md:195-196`、`f_llm/README.md:1063`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「接线缺失」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— 全仓 `grep ToolScope`（排除 `.worktrees`）只命中 3 处：定义文件、`f_llm/src/loom/Plan_test.cj`、以及本文件自身；`LoomRunner`/`LoomService`/`Planner` 里没有任何 `ToolScope.` 调用，也没有等价的 `flow.tools` 白名单过滤（`grep 'flow.tools'` 仅命中 `LoomService.cj:81,95` 的写入与存储层）。文档却写：「流程计划里用 `tools` / `mcps` 声明可用集合，`ToolScope.check(kind, requested, available)` 做白名单校验：**只能收窄，不能凭空引入**——声明了未注册的名字直接抛 `LoomException`」。
- **描述**：`ToolScope` 是 public API（README 已登记），测试也覆盖了三条分支，但运行期没有任何一处调用它，于是"计划里写了未注册工具"不会在编排/执行阶段被拦下，只能等模型真的调用该工具时由 `FunctionMediator` 抛 `FunctionNotFoundException`。这是"安全阀装了但没接管路"。
- **建议**：在 `LoomService.confirmFlow`/`Planner.plan` 的校验段落里接一次 `ToolScope.check('tool', request.tools, FunctionMediator.names())` 与 `ToolScope.check('mcp', request.mcps, <mcp 名单>)`，对已编译计划在 `dispatch` 前跑 `verifyPlan`；若设计上是"由宿主应用自行接线"，则在 README 与 doc 里写明调用时机，避免被当成已生效的保障。

### [一般][存量] #8 `McpToolSource.load()` 中途失败会留下半张工具表，重试又全部撞重名

- **位置**：`f_llm/src/mcp/McpToolSource.cj:65-73`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源/状态不对称」、§14.1「半成品」、fountain-baseline §4（同名注册直接失败，不做隐式优先级）
- **证据**：静态确定 —— 循环里逐个 `FunctionMediator.register(...)`，`register` 对重名直接抛 `FunctionCallingException`（`f_llm/src/tool/FunctionMediator.cj:55-64`）。假设第 3 个工具名超 64 字符（`ToolName.mcp` → `validate` 抛，`ToolName.cj:51-55`），前 2 个已经进了全局表，`load()` 抛出，调用方拿不到任何"已注册了几个"的信息；下一次对同一 alias 重试时第 1 个就撞重名，永远起不来。
- **描述**：同名注册"启动直接失败"是对的（符合 baseline §4），但缺"失败即回滚"，把一次配置错误变成了不可自愈的全局状态污染（同进程内无法补救）。测试 `McpToolSource_test.cj:126-136` 正好只覆盖了"抛异常"，没有断言"表里没有残留"。
- **建议**：先在局部 `ArrayList` 里把全部 `(name, calling)` 准备好（名字冲突在本地判），再逐个 `register` 并记录已注册名字，`catch` 时把它们 `unregister`（需要新增 `FunctionMediator.unregister`）或干脆改成"一次注册一批"的原子接口。至少把已成功的数量写进异常消息。

### [一般][存量] #9 `llm_summarisingActionKind` 的两个取值在仓内没有任何 `MemorySummaryFinder` 实现，配了就抛 `BeanException`（且落在定时任务里）

- **位置**：`f_llm/src/memory/Memory.cj:40-46`；承诺源 `f_llm/README.md:800`、`f_llm/doc/f_llm.md:573`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「配置项被读取却无人实现」、§3「开关打开后走进失败分支」
- **证据**：需实测 / 待确认 —— `grep '< ExperienceFinder|< IndividualityFinder|< MemorySummaryFinder'`（排除 `.worktrees`）在本仓零命中：三个接口（`f_llm/src/finder/MemorySummaryFinder.cj:20-27`）只有声明，没有实现类；而 `lookup<T>()` 未命中即抛 `BeanException`（`f_bean/src/lookup.cj:26-30`）。缺的信息：是否有下游仓库（应用侧）提供这些 bean。若没有，则 `llm_summarisingActionKind=experience|individuality` 一定抛异常，并经 #4 使定时器失效。
- **描述**：README 只写"经验总结模型与动作类型"，既没写合法取值，也没写"需要宿主提供 `MemorySummaryFinder` 实现"，按文档配置无法用起来。
- **建议**：README / doc 补"取值：空（关闭）、`experience`、`individuality`、或任意 bean 前缀；前两者要求宿主注册对应 `*Finder` 实现"；`Memory.extractor()` 改用 `lookupOption` 并在缺失时 `warn` + 返回 `None`（不要让配置错误升格为定时器死亡）。

### [一般][存量] #10 `KnowledgeEntity.queryConf` 对可能为空的数组直接取 `[0]`

- **位置**：`f_llm/src/model/entity/KnowledgeEntity.cj:41`（`conf = finder([LLM_TYPE_SEARCH])[0]`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「空集合未处理 / 直接取 `[0]`」
- **证据**：静态确定 —— `finder` 是调用方注入的 `(Array<LLMType>) -> ArrayList<LLMConf>`，返回值没有任何"非空"约束；`[0]` 在空 `ArrayList` 上抛越界。同文件 `:40` 的 `if(list.size < params.maxResults)` 只说明"还需要查配置"，不保证 `finder` 有候选（模型配置缺失/全部熔断时就是空的）。
- **描述**：知识检索路径上，候选模型表为空会让整个 `KnowledgeEntity` 构造链抛越界而不是走"无配置"降级。
- **建议**：先 `let found = finder([LLM_TYPE_SEARCH])`，再 `if(!found.isEmpty()){ conf = found[0] }`（或 `match(found.first())`）；无候选时 `conf` 保持 `None`，由 `save`/调用方按"没有可用模型"处理。

### [一般][存量] #11 `KnowledgeEntity.save` 与 `search` 的完成判据不一致（`==` vs `<`），`list.size > maxResults` 时 `remoteResults.getOrThrow()` 必抛

- **位置**：`f_llm/src/model/entity/KnowledgeEntity.cj:52`（`if(list.size == params.maxResults)`）、`:46-48`（`search` 只在 `list.size < maxResults` 时才赋值）、`:55`（`remoteResults.getOrThrow()`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 空值未处理」、§2「近似重复但一块少了边界判断」
- **证据**：待确认 —— `list` 来自构造时的 `searchExecutor(params, keywordsEmbedding)`（`:32`），类内**没有任何**"截断到 `maxResults`"的代码，所以 `list.size > maxResults` 是可达状态；此时 `search()` 不会设置 `remoteResults`（判据是 `<`），`save()` 也不会早退（判据是 `==`），于是 `None.getOrThrow()` 抛 `NoneValueException`。缺的信息：`searchExecutor` 的实现是否保证 `<= maxResults`（本仓内 `KnowledgeEntity` 无构造点，无法从调用方取证）。
- **描述**：同一"是否还需要外部检索"的语义在两处用了不同比较符，属于典型的近似重复导致的行为漂移。
- **建议**：抽一个 `private prop needMore: Bool { list.size < params.maxResults }`，`search`/`queryConf`/`save` 三处统一用它；`save` 内对 `remoteResults` 用 `match` 处理 `None`（返回 `list` 并 `warn`）。顺带把 `:63` 的 `let params = EmbeddingParam(...)` 改名（它遮蔽了成员 `params`，`:85` 又靠作用域回指成员，读起来极易误判）。

### [一般][存量] #12 `listTools` 不校验 `offset`/`limit`，模型给负偏移直接越界

- **位置**：`f_llm/src/loom/ToolFunctions.cj:54-73`（`:55-56` 解析、`:60-62` 循环条件与 `all[index]`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」、§10 安全性（外部输入未校验）
- **证据**：静态确定 —— `Int64.tryParse(params.offset.trimAscii()) ?? 0` 对 `"-1"` 返回 `-1`；`while(index < Int64(all.size) && taken < limit)` 在 `index = -1` 时成立，`all[-1]`（`ToolFunctions.cj:57` 从 `ToolCatalog.entries()` 取到的 `ArrayList`）抛 `IndexOutOfBoundsException`。`limit` 为负则循环不执行、返回 `'[]'`（静默空结果）；`limit` 为超大值则返回全部（无上限，`ToolFunctions.cj:73` 的字符串随之膨胀）。
- **描述**：参数来自模型生成的 tool-call 实参，属不可信输入。当前后果是"工具抛错 → 由 `LLMToolLoop` 回填错误文本"，不会崩进程，但错误信息是越界栈而不是"参数非法"，模型很可能反复重试同一个负偏移。
- **建议**：`offset = max(0, offset)`、`limit` 夹到 `[1, 200]`，非法值直接返回 `FunctionResult(event: params.nextEvent, result: '...invalid offset/limit...')`，与 `:105-107` 的 `requires query` 风格一致。

### [一般][存量] #13 记忆开关关闭（默认）时仍为每个事件 `spawn` 线程并拼装全部消息文本

- **位置**：`f_llm/src/memory/Memory.cj:145-151`（`spawn { for (m in all) { add(session, m.role, generateContent(m)) } }`）、`:22-34`（关闭时 `faithful = DummyMemory()`）、`:86-114`（`generateContent`）；调用点 `f_llm/src/agents/AgentTask.cj:510`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「开关只在一处判断，另一处仍走旧逻辑」、§5「一次提交全量任务」、§12.1「有界性」
- **证据**：静态确定 —— `llm_makingMemory` 默认 `false`（`f_llm/src/config/LLMConfig.cj:254-256`），此时 `faithful` 是 `DummyMemory`，三个方法都是空体（`FaithfulMemory.cj:23-28`）。但 `Memory.add(session, all!)` 无条件 `spawn`，并在循环里先算 `generateContent(m)`（每个消息一次字符串拼装，`ToolCallMessage` 还要遍历 `tool_calls`）再调用空实现；`AgentTask` 每个事件都调一次（`:510`），即每个事件一个游离线程 + 一次全量文本拼装，成果全部丢弃。
- **描述**：开关关掉只是"不落盘"，没有"不干活"。同一个 `spawn` 还带来两个次生问题：线程无上限（每个事件一个，无 join、无队列、无背压），以及异常被彻底吞掉（`spawn` 内的 `faithful.add` 抛 `StoreException` 时无人感知，因为 `Future` 被丢弃）。
- **建议**：在 `Memory.add` 入口判 `LLMConfig.getMakingMemory()`（或给 `FaithfulMemory` 加 `prop enabled: Bool`，`DummyMemory` 返回 `false`）后直接返回；需要异步时改成有界提交（固定 worker + 队列上限），并保留 `Future` 至少记录失败日志。

### [轻微][存量] #14 `McpToolSource` 的类注释与实现相反（`additionalProperties`、64 字符规则）

- **位置**：`f_llm/src/mcp/McpToolSource.cj:49-53`（注释）vs `:132-155`（`sanitizeSchema` 只剥 `$` 前缀键）vs `:158-174`（`firstTypeOf`）；测试侧 `McpToolSource_test.cj:75-76` 明确断言"必须保留 `additionalProperties`"
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与注释不符」
- **证据**：静态确定 —— 注释说「`$schema` / `$ref` / `$defs` / `additionalProperties` 一律剥掉」，实现只跳过 `key[0] == b'$'`，`additionalProperties` 既不剥也没特判，`sanitizeSchema` 自己的注释（`:128-130`）还写着"**保留**"。长度规则同样：注释说"别名或工具名超 64 字符 ⇒ 注册失败"，实际校验的是拼好的 `mcp__{alias}__{tool}` 总长（`ToolName.mcp` → `validate(name)`，`ToolName.cj:36-38`），alias 40 + tool 30 会失败，而两者各自都 < 64。
- **描述**：注释是维护者判断"该剥什么"的第一手依据，写反了会把后续改动带向错误方向（本次测试用例写的是正确语义，说明注释是旧版遗留）。
- **建议**：注释改为"剥掉所有 `$` 开头的元信息键；`additionalProperties` 保留；总长 `mcp__{alias}__{tool}` ≤ 64"。

### [轻微][存量] #15 `ToolScope.verifyPlan` 注释声称校验"工具/模型"，实现只校验工具

- **位置**：`f_llm/src/loom/ToolScope.cj:57`（`/** 校验计划里 step 引用的工具/模型都在白名单内 */`）、`:69-81`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与注释不符」
- **证据**：静态确定 —— 函数签名只有 `tools: Array<String>` 与 `availableTools`，循环里只对 `step.kind == 'tool' || 'mcp'` 判 `step.tool`，`step.model` 从未被读取。
- **建议**：要么改注释为"只校验工具/MCP"，要么补 `models`/`availableModels` 参数并按 `step.model` 判（`llm` 步骤也需要模型白名单时，这是当前唯一缺失的一环）。

### [轻微][存量] #16 `MemoryExtractor` 用"去掉 key 末尾一个字节"派生 kind，`individualities` 变成 `individualitie`

- **位置**：`f_llm/src/memory/MemoryExtractor.cj:31`（`let kind = key[0 .. key.size - 1]`）、`:53-54`/`:136`（传入 `'lessons'`/`'experiences'`/`'individualities'`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「读了不用/派生逻辑脆弱」、§2「字面量复制」、§11「语义与命名不符」
- **证据**：静态确定 —— `'individualities'` 去尾是 `'individualitie'`（漏了 `y`），而 `MemoryKinds`（`f_llm/src/store/MemoryKinds.cj:43-53`）里根本没有 `lesson`/`individualitie` 这些值；`'lessons' → 'lesson'`、`'experiences' → 'experience'` 也是另一套命名，与 `MemoryKinds.EXPERIENCE` 只是"碰巧同字"。
- **描述**：`kind` 会随 `overwrite(kind, content)`（`f_llm/src/finder/MemorySummaryFinder.cj:21`）落到记忆记录里，下游 `listByKind('individuality')` 永远查不到；同时"去尾一个字节"对任何新增的合法 JSON key 都会静默产出错误 kind。
- **建议**：把 kind 显式写死成常量（如 `MemoryKinds.LESSON` / `INDIVIDUALITY`），不要靠字符串截断；`extract(key, jsonobj, overwriter)` 改成收 `(key, kind)` 两个参数。

### [轻微][存量] #17 `Memory.remember` 把命名空间与 kind 的默认值写成字面量，与 `MemoryKinds` 常量脱钩

- **位置**：`f_llm/src/memory/Memory.cj:121`（`namespace!: String = 'loom', kind!: String = 'session'`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「字面量复制」
- **证据**：静态确定 —— `MemoryKinds.SESSION = 'session'`（`f_llm/src/store/MemoryKinds.cj:49`）已存在，`'loom'` 在 `loom` 包内多处出现，这里两处都是裸字面量；常量改名后签名默认值不会跟着变。
- **建议**：默认值改用 `MemoryKinds.SESSION`，命名空间常量提到 `loom` 包的公共常量（`LoomNamespaces.DEFAULT`）。

### [轻微][存量] #18 §2 重复逻辑（5 组，均为"同语义不同写法"）

- **位置与形态**：
  1. **`textOf(FunctionResult)` 同形多处（本部分 3 处）**：`f_llm/src/loom/ToolFunctions_test.cj:73-78`、`f_llm/src/mcp/McpToolSource_test.cj:104-107` 与 `:118-121`（同一文件内两段一模一样的 `match(result.result){ case json: JsonString => json.value; case _ => '' }`）；范围外另有两份（`loom/SkillImport_test.cj:57`、`loom/StoreFunctions_test.cj:47`）。
  2. **JSON 数组手工拼装两处**：`f_llm/src/loom/ToolFunctions.cj:58-72` 与 `:110-121`——`var text = '['` + `first` 标志 + `text += '{...}'` + `text + ']'` 的骨架逐行对齐，差异只有"是否带 `score` 字段"和"是否分页"。
  3. **空白校验跨层重复**：`ToolFunctions.cj:105-107`（`params.query.trimAscii().isEmpty()` → 返回 `requires query`）与 `ToolCatalog.cj:57-61`（`query.trimAscii().toAsciiLower()` 后再判 `isEmpty` → 返回空表）。同一份输入被两层各 trim 一次，错误语义不同（一个是文本提示、一个是空数组）。
  4. **"集合转 HashMap 做成员判定"两处**：`ToolScope.cj:38-41`（`available`）与 `:61-68`（`tools` + `availableTools`），且都用了 `HashMap<String, Bool>` 而不是 `HashSet<String>`。
  5. **MD5 → hex 两处**：`model/entity/KnowledgeEntity.cj:71-75`（`content.unsafeBytes() |> md5.write; md5.finish() |> toHexString`）与 `memory/FaithfulMemory.cj:46-48`（`md5.write(...); md5.finish() |> toHexString`）。
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2（换控制流 / 只改类型名 / 字面量复制）
- **证据**：静态确定 —— 逐行比对函数体骨架与字面量。
- **描述**：第 1 组是纯测试样板（抽取落点建议放测试公共文件而不是产品代码）；第 2、3 组有真实的"行为漂移"风险（分页版与检索版的字段、空值语义已经不同）；第 5 组建议抽 `f_util` 的 `md5Hex(String): String`，现有 `f_util/src/uuid.cj:318` 已有第三份 `MD5()` 用法。
- **建议**：2 → `ToolCatalog.toJson(entries)`；3 → 只在上层校验，`ToolCatalog.search` 收到空串直接返回空（保留但加注释说明这是防御）；4 → `private func toSet(items: Collection<String>): HashSet<String>`；5 → `f_util` 公共函数。合并时必须保留的语义差异：`searchTools` 的空查询回文本、`ToolCatalog` 的回空数组。

### [轻微][存量] #19 `Knowledge.cj` 尾部粘着的 psql 表结构注释与类字段已不一致，且混用数据库方言类型名

- **位置**：`f_llm/src/model/Knowledge.cj:30-49`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「注释与实现不符」、fountain-baseline §2（代码里不出现方言名）；review-checklist §13 的同类判据（注释即文档）
- **证据**：静态确定 —— 注释列出 13 列（`id` / `code_lang` / `kind` / `md5` / `source` / `entire` / `title` / `content` / `used_count` / `save_time` / `update_time` / `embedding` / `search_vector`），`Knowledge`（`:18-29`）只有 8 个字段，`used_count`/`save_time`/`update_time`/`search_vector` 完全没有对应成员；注释右侧被截断（`>` 结尾），已不可读；类型名 `bigint` / `character varying` / `tsvector` 正是 baseline §2 明令不要出现在代码里的方言名。
- **建议**：注释改成"表结构以 `f_llm/src/store/**/KnowledgeStore.cj` 的建表语句为准"，或补齐缺失字段并改成仓颉类型名；无用的 `\d` 输出直接删掉。

### [轻微][存量] #20 `MemoryRemember_test.cj` 的 `Config` 导入未使用

- **位置**：`f_llm/src/memory/MemoryRemember_test.cj:22`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— 该文件内 `Config` 只出现在第 22 行的 import 上（`grep -n "Config"` 仅命中该行）。
- **建议**：删除该 import。

### [轻微][存量] #21 `sanitizeSchema` 对 MCP 提供的 schema 做无深度上限的递归

- **位置**：`f_llm/src/mcp/McpToolSource.cj:132-155`（`$` 前缀剔除时对每个 value 递归）、`:158-174`（`firstTypeOf` 不递归）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归：深度由输入决定」
- **证据**：待确认 —— 递归深度完全由 `tool.inputSchema` 的 JSON 嵌套层数决定，代码无深度计数；实际可达到的上界取决于 `f_data` 的 JSON 解析器是否对嵌套深度设限（未在本次范围内取到该常量），因此按"与解析器等深"估计而不是断言具体层数。MCP server 由外部配置引入，属可信度较低的一方。
- **建议**：加 `depth` 参数并在超过（如 32 层）时直接返回原值 + `warn`，避免"清洗 schema 时爆栈"这种难定位的崩溃。

### [轻微][存量] #22 测试大量共享进程级单例，用例之间互相污染且无法并行

- **位置**：`f_llm/src/loom/Supervisor_test.cj:159-178`（`boot()` 每次 `Supervisor.reset()` + `LoomServices.reset()` + `LoomHostApi.unbind()`，`:244-246`、`:283-286`、`:363-365`、`:434-436` 又各写一遍）、`f_llm/src/mcp/McpToolSource_test.cj:81-87`（`catch(error: Exception){ () }` 吞掉注册失败）、`:139-150`（注册 `dup` 后不清理）、`f_llm/src/memory/MemoryRemember_test.cj:55-57`（`finally` 里把手写假网关装回全局）、`f_llm/src/loom/ToolFunctions_test.cj:81-87`（`ensureFake` 吞异常）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3「`catch {}` 静默吞异常」、§12.1「共享可变状态」、§2「测试准备代码重复」
- **证据**：待确认 —— `Supervisor.current()` / `LoomServices` / `LoomHostApi` / `FunctionMediator` / `LoomHostApi.storeGateway` 都是进程级 static；`std.unittest` 提供 `KeyParallel`（`std/unittest/unittest_package_api/unittest_package_structs.md:1239-1261`），默认是否并行需按 `cjpm test` 的实际配置确认。若并行，这些用例必然互相覆盖状态；若串行，`catch{ }` 仍会把"重名注册"这类真实失败吞掉。
- **建议**：`ensureFake` 改成先 `try` 注册、失败时校验已注册的是不是同类工具（而不是无条件忽略）；`McpToolSource_test` 结束清理 alias；`MemoryRemember_test` 的 `finally` 恢复成"无网关"（`unbind` 语义）而不是装一个永真假网关；`boot()` 的 reset 样板抽成 `@BeforeEach`。

## 优化可行性方案

> 不是缺陷，是"还能更好"。以下三条都没有改前基线，**均为待验证假设**，不进 `tasks.md`。

### [CPU] 关掉 `llm_makingMemory` 时跳过整个 `add` 路径

- **现状**：`Memory.add(session, all!)`（`f_llm/src/memory/Memory.cj:145-151`）每个事件 `spawn` 一次，循环内对每条消息调 `generateContent`（字符串模板 + `StringBuilder`，`ToolCallMessage` 还要遍历 `tool_calls`），默认配置下结果全部丢弃（`DummyMemory` 空实现）。
- **方案**：入口判 `LLMConfig.getMakingMemory()`（或 `FaithfulMemory` 暴露 `enabled`）后直接返回；同时把"每事件一个 `spawn`"改成有界 worker + 队列。
- **预期**：省掉每事件 1 次线程创建 + O(消息数) 次字符串拼装；具体降幅需 profile，无法先验给出。
- **代价**：`Memory.add` 从"永远异步"变成"配置关闭时同步返回"，语义无变化；worker 化引入队列上限与丢弃策略。
- **验证**：`cjprof record` 跑一段典型 agent 会话（N 事件 × M 消息），对照 `generateContent` 自耗时占比与线程创建次数（`/proc/<pid>/status` 的 `Threads` 峰值）；`cjpm bench -O2` 对照 `Memory.add` 单次耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ToolCatalog` 每次检索重复小写化与 JSON 解析

- **现状**：`entries()`（`ToolCatalog.cj:47-53`）每次调用都对每个工具跑一遍 `descriptionOf`（4 层 `match` + `toData`/`asObject` 解析，`FunctionMediator.definition` 每次新建 `JsonObject`）；`search()`（`:62-67`）再对每条 `name`/`description` 各做一次 `toAsciiLower()`。`listTools`/`searchTools` 由模型调用触发，`topK` 只需 5 条却要全量解析。
- **方案**：在 `FunctionMediator` 注册时缓存 `(name, descriptionLower)`，`ToolCatalog` 只读缓存；`search` 先按缓存匹配再构造 `ToolEntry`。
- **预期**：单次检索的分配量与 CPU 从 O(工具数 × JSON) 降到 O(工具数) 字符串比较；工具数几十时绝对收益不大。
- **代价**：多一份常驻缓存（工具名 + 小写描述，量级 KB），注册路径要同步失效。
- **验证**：`cjpm bench -O2` 对 `ToolCatalog.search` 做 1k 次调用的中位数对照；同时确认 `FunctionMediator` 注册后不再变更（当前无 `unregister`，缓存不会失效，但 #8 的修复会引入）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 摘要输入按会话上限截断，避免整段会话一次拼进 prompt

- **现状**：`Memory.summarise`（`Memory.cj:56-65`）把 `messages` 全量拼成一个 `content` 字符串（每条消息 + `'---'` 分隔），再交给 `LLM.chatByName`；`messages` 由 `FaithfulMemoryImpl.summarise` 按 session 累积（`FaithfulMemory.cj:67,85`），无条数/字节上限。
- **方案**：给单次摘要设消息条数与字节上限（如末尾 N 条 / 64KB），超限时先分段摘要再合并；`FaithfulMemoryImpl` 侧改为按批 flush 而不是整段累积。
- **预期**：峰值内存与 LLM 请求体从"会话长度线性"变为常数上界；具体收益依赖真实会话长度分布。
- **代价**：分段摘要会损失跨段上下文，摘要质量需评估；实现复杂度上升。
- **验证**：构造 1k/10k 条消息的会话跑 `summarise`，对照 `getAllocatedHeapSize()` 峰值与 RSS，并人工比对摘要质量（分段 vs 全量）。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每事件 `spawn` 的线程创建 + `Store` WAL 写放大是记忆路径的主要开销 | `f_llm/src/memory/Memory.cj:145-151`、`FaithfulMemory.cj:50-59` | 单次 `add` 耗时分布、WAL 每秒写入条数 | `cjprof record` 跑 10 分钟稳态会话负载；统计 `Store.add` 调用次数与 `wal.append` 自耗时 |
| 2 | 同一毫秒同 role 的消息碰撞（#3）实际发生频率 | `f_llm/src/memory/FaithfulMemory.cj:36-38,53` | 碰撞次数 / 总写入次数 | 在 `add` 里对 `contentKey` 做命中计数埋点，跑真实会话 1 天 |
| 3 | `StoreWiring.wire()` 的全局 `Mutex` + `StoreSettings.load()` 在每次 `remember` 上成为串行点 | `f_llm/src/memory/Memory.cj:124`、`f_llm/src/wiring/StoreWiring.cj:52-73` | 单次 `wire()` 耗时、并发写记忆时的等待时长 | 分段计时包一层 `wire()`，多线程并发 `remember` 压测，看 P99 |
| 4 | `ToolCatalog` 的 `toAsciiLower` + 逐条 JSON 解析在工具数上百时成为检索热点 | `f_llm/src/loom/ToolCatalog.cj:47-88` | 工具数 → 单次 `search` 耗时曲线 | `cjpm bench -O2` 对 10/100/1000 个注册工具各跑 10k 次，取中位数 |
| 5 | `sortDesc` 的插入排序与 `check` 的 `result.contains` 在规模放大后成为 O(n²) 瓶颈 | `ToolCatalog.cj:90-100`、`ToolScope.cj:50-52` | n 到多大开始显著 | 同上 bench，n = 10/100/1000 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/loom/Supervisor_test.cj` | .cj | ✅ | 622 行测试；见 #22（全局单例）、`SpyHost` 被同包另一测试文件使用（非死代码） |
| 2 | `f_llm/src/loom/ToolCatalog.cj` | .cj | ✅ | 见 #12（调用方边界）、#18-2、优化方案 2、待验证假设 4/5 |
| 3 | `f_llm/src/loom/ToolFunctions.cj` | .cj | ✅ | 见 #12、#18-2/3 |
| 4 | `f_llm/src/loom/ToolFunctions_test.cj` | .cj | ✅ | 见 #18-1、#22（`ensureFake` 吞异常） |
| 5 | `f_llm/src/loom/ToolScope.cj` | .cj | ✅ | 见 #7（未接线）、#15（注释）、#18-4 |
| 6 | `f_llm/src/macros/ToolCall.cj` | .cj | ✅ | `@ToolCall` 被 `tool/TodoFunction.cj:70` 使用；`@WeavedToolCall` 仓内零引用但 README 登记为 public 宏 ⇒ 不算死代码 |
| 7 | `f_llm/src/mcp/McpToolSource.cj` | .cj | ✅ | 见 #8、#14、#21 |
| 8 | `f_llm/src/mcp/McpToolSource_test.cj` | .cj | ✅ | 见 #18-1、#22 |
| 9 | `f_llm/src/memory/FaithfulMemory.cj` | .cj | ✅ | 见 #1、#2、#3，待验证假设 2 |
| 10 | `f_llm/src/memory/Memory.cj` | .cj | ✅ | 见 #4、#6、#13、#17，优化方案 1/3 |
| 11 | `f_llm/src/memory/MemoryExtractor.cj` | .cj | ✅ | 见 #5、#16 |
| 12 | `f_llm/src/memory/MemoryRemember_test.cj` | .cj | ✅ | 见 #20、#22 |
| 13 | `f_llm/src/memory/imports.cj` | .cj | ✅ | 18 条 `internal import`；`internal import` 对子包可见（语言文档 `docs/dev-guide/source_zh_cn/package/import.md:294`），符号均被同包文件使用（`Role` 来自 `constant.*`） |
| 14 | `f_llm/src/model/Code.cj` | .cj | ✅ | 纯 DTO，无逻辑 |
| 15 | `f_llm/src/model/CodeParam.cj` | .cj | ✅ | 与 `Code` 字段差异属业务（`weight`/`confidence`/`codeLang`）⇒ 不判重复 |
| 16 | `f_llm/src/model/Knowledge.cj` | .cj | ✅ | 见 #19 |
| 17 | `f_llm/src/model/KnowledgeParam.cj` | .cj | ✅ | 纯 DTO |
| 18 | `f_llm/src/model/SkillReferenceParam.cj` | .cj | ✅ | `@DataAssist` 生成 props，字段均有用途 |
| 19 | `f_llm/src/model/Specification.cj` | .cj | ✅ | 纯 DTO |
| 20 | `f_llm/src/model/entity/KnowledgeEntity.cj` | .cj | ✅ | 见 #10、#11、#18-5 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 设计：`KnowledgeEntity` 构造函数里直接发 embedding 请求并记 token（`KnowledgeEntity.cj:25-33`），对象一构造就有网络副作用、无法单测；可读性：`ToolCatalog.descriptionOf`（`:102-120`）四层 `match` 嵌套；安全性：`listTools` 的 `offset`/`limit` 直接来自模型实参且未校验（并入 #12）。其余逻辑/边界类问题统一记在 §11 行 |
| §1 死代码 | 1 | 已逐个核对本部分 20 个文件的 `private`/`internal`/`protected` 符号与 `import`：`ToolCatalog` 的 `scoreOf`/`sortDesc`/`descriptionOf` 均被同文件调用，`McpToolSource.textOf`（`:176`）被 `:115` 调用，`firstTypeOf` 被 `:141` 调用，`ToolCall.expand` 被两个宏调用，`SpyHost` 被 `loom/LoomWiringSupervisor_test.cj:143` 使用，`Memory.add` 两个重载分别被 `AgentTask.cj:510` 与内部调用 ⇒ 唯一命中是未使用的 `import Config`（#20）。信息项（不算问题）：`Memory.timer` 字段只在 `static init` 里被 `atExit` 捕获，之后不再读取（生命周期锚点，保留合理）；`@WeavedToolCall`、`ToolEntry.score` 等对外 public 声明仓内零引用但 README 已登记，按硬原则一不判 |
| §2 重复逻辑 | 2 | 已把 20 个文件的函数体压成「输入→输出→副作用」两两比对，并跨文件搜了相同错误文案/字面量：命中 #18（5 组）与 #17（kind/namespace 字面量复制）。`Code`/`CodeParam`/`Knowledge`/`Specification` 字段重叠属不同职责，不判；`Supervisor_test` 里重复的 `reset` 样板归入 #22 |
| §3 空实现 | 1 | `DummyMemory` 三个空方法是"有意 Null Object"且有 `makingMemory` 开关控制，不算问题；命中是测试里的 `catch(error: Exception){ () }`（`ToolFunctions_test.cj:82-86`、`McpToolSource_test.cj:99-101`/`:114-116`）——静默吞异常，仅测试代码，按轻微并入 #22。另 `Memory.summarise` 的"失败返回成功"已单列为 #6 |
| §4 栈溢出 | 1 | `sanitizeSchema` 的递归深度由外部 schema 决定（#21）；`ToolCall.expand` 的 `while(let MacroExpandDecl <- ...)` 有单调收敛、`ToolCatalog`/`MemoryExtractor` 无递归 ⇒ 其余不命中 |
| §5 OOM | 2 | #2（内容键永不删除）+ #13（每事件 `spawn`、无上限）。`Memory.summarise` 全量拼会话串另有优化方案 3；`ToolCatalog.entries` 的物化受注册工具数限制，未达 OOM 量级 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile / bench 数据，"`spawn` 多"、"JSON 解析多"只是线索；已全部落到「待验证假设」1/3/4/5，不进 `todo.md` |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件自身不含任何锁；调用路径上唯一相关的是 `StoreWiring.wire()` 的全局 `Mutex`（`StoreWiring.cj:52`），被 `Memory.remember` 每次调用一次，但记忆写入频率低（每会话每天一次），看不出热点；已列入待验证假设 3 补数据 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`、无"批大小=1"的循环；`Memory.add` 的 `spawn` 是 fire-and-forget（问题在无界与静默失败，见 #13） |
| §6.4 低效算法 | 0 | `sortDesc` 是插入排序 O(n²)（`ToolCatalog.cj:90-100`）、`ToolScope.check` 的 `result.contains` 也是 O(n²)，但 n = 工具数（几十），未证明是热点 ⇒ 待验证假设 5 |
| §7 降堆内存方案 | 1 | 输出 1 条方案（摘要输入截断），证据状态均为「无基线（待验证）」 |
| §8 降 CPU 方案 | 2 | 输出 2 条（关闭开关时跳过 `add` 路径；`ToolCatalog` 缓存），均无基线 |
| §9 local mode 可行性 | 0 | 逐函数做过逃逸检查：`ToolCatalog.entries/search` 返回的 `ArrayList<ToolEntry>`、`sanitizeSchema` 返回的新 `JsonObject`、`Memory.summarise` 拼出的 `content` 全部逃逸出函数（返回值/请求体），`ToolFunctions.call` 的 `text` 作为 `FunctionResult` 返回 ⇒ 没有"函数内创建、函数内释放"的大对象，改造不成立 |
| §11 现有代码的 BUG（存量） | 15 | 计数口径列出：#1 #2 #3 #4 #5 #6 #8 #10 #11 #12 #13 #14 #15 #16 #19 = 15 条（边界、空集合、错误处理、资源、契约与注释不符各一组）。其余 7 条按主维度归到 §1(#20)、§2(#17/#18)、§3(#22)、§4(#21)、§14(#7/#9)。均已核对调用链（`AgentTask.cj:510`、`FunctionMediator.call`、`Store.add`、`Timer.after`） |
| §12 并发安全与锁粒度 | 1 | 共享路径只有两条：① `Memory` 的 static `faithful`/`timer`（初始化后只读，无线程共享写）；② `FaithfulMemoryImpl.add` 的 `contains`→`add` 非原子（并入 #3 描述）与 `Memory.add` 的 `spawn` 无 join/无界（#13）。`Store` 本身是并发安全实现（`ConcurrentSkipListMap` + `AtomicInt64` 序列号），未发现"无保护共享可变状态" |
| §14 功能完备性与 README 覆盖 | 2 | #7（`ToolScope` 未接线）、#9（`llm_summarisingActionKind` 取值无实现/无文档）。另 README 对 `Memory` 只写"是否保存记忆（保存才有经验）"，未说明 `llm_summarisingActionKind` 的合法取值与前置 bean，属 #9 的一部分 |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md`（§13 文档一致性 0 命中），`.cj` 20 个全部逐行读完；`imports.cj` 的 `internal import` 可见性已按语言文档核对 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 9 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

存量缺陷 22 条，是否纳入修复待用户决定（本部分不含「本次改动」来源——基线为工作区快照，无 diff 可比）。

## 总评

`model` 包与 `ToolCatalog`/`ToolFunctions` 这类"纯数据 + 纯转换"的代码质量良好，`ToolScope` 的实现本身也正确（校验语义清晰、错误消息带上下文）。真正的问题集中在 `memory` 包：`FaithfulMemoryImpl.summarise` 一个循环里同时踩了三个独立错误——把 session 主序当时间序（#1）、删除时复用当前条目的 `timeStr`（#2）、内容键只精确到毫秒（#3），而整条链路又跑在没有异常保护的 `Timer` 任务里（#4），任一环节出错都会以"功能静默消失、需要重启"的形式呈现。这四条建议作为阻塞项一起修，并配一条"写入 N 条 → 触发摘要 → 断言存储已清空、记忆只写一次"的端到端用例；否则单修其中任一条，其余两条会让验证结论失真。

`ToolScope` 未接线（#7）与 `KnowledgeEntity` 的两处未校验（#10/#11）属于"API 存在但路径不通"的半成品特征，建议排期处理；`McpToolSource.load` 的半途状态（#8）在 MCP 真正接入前修掉即可。其余重复逻辑与注释不一致项按轻微排期，可随下一次重构一并清理。
