# f_llm 模块审查报告（模块第 5/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个文件，全部 `.md`，均位于 `f_llm/doc/spec/fix-loom-*/`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，无 diff 可对照）⇒ 全部记「存量」
- **审查重点**：f_llm 专项（客户端契约与配置、流式与错误处理、资源与超时、死代码、重复逻辑、并发安全）中的「契约」与「并发/资源」两项。本部分不含 `.cj`，因此实际执行的是 checklist §13 / §14：把 5 份 OpenSpec 变更记录里的每条 MUST、每个任务勾选、每个符号与位置，逐条拿到 `src/loom/` 复核；顺带过 §1、§2、§11、§12
- **报告版本**：v1（分部分报告，供主 Agent 合并为 `f_llm_v2.md`）

## 发现

### [一般][存量] `experience` 双 kind 合并让 `limit` / `offset` 不再是页语义

- **位置**：`f_llm/src/loom/LoomStoreGateway.cj:149-163`（`memory.list` 的 experience 分支）；承诺源 `f_llm/doc/spec/fix-loom-read-path/specs/loom-flow/spec.md:21`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符 / 边界）、§13（规格与实现漂移）
- **证据**：静态确定 —— `offset`、`limit` 被**逐 kind** 各传一遍，`merged.add` 拼接后无全局截断：`limit=1` 时两 kind 各取 1 条 → 返回 2 条；`offset=1` 时两 kind 各自的第 0 条都被跳过 → 跨页漏条。`listByKind` 是「先过滤再分页」的下推实现（`f_llm/src/store/MemoryRepository.cj:72-80`、`f_llm/src/dao/postgres/MemoryDAO.cj:166-172`）。
- **描述**：spec 要求「`memory.list` 在缺少 `limit`、或 `limit<=0` 时 MUST 使用缺省上限 50」，实现里 50 是**每 kind** 的上限，experience 一次最多返回 100 条；`offset` 在两条 kind 流上重复生效。文档 `f_llm/doc/loom.md:565` 还写「带 `kind` 时…**先过滤再分页**」，与「两类各分页再拼接」不符。演进侧同路径（`SkillEvolutionJob.cj:266-269` 对两类 kind 各取 `limit=500`）。
- **建议**：最小改法是在网关内合并后按 `saveTime` 排序再 `take(limit)`；根治则是给 Store 增加 `listByKinds(..., offset, limit)`（`kind IN (...)` + 单次 `LIMIT/OFFSET`）。注意 `MemoryQuery.kinds` 只服务 `search`（`f_llm/src/store/InMemoryStores.cj:152`），`list` 侧没有等价能力，不能直接复用。

### [一般][存量] 网关的惰性单例无同步，违反「一次装配最多创建一个网关」

- **位置**：`f_llm/src/loom/LoomWiring.cj:38-53`（`LoomGatewayHolder.get`）；共享路径 `LoomWiring.cj:103-106`（`loomStore` 闭包）与 `LoomWiring.cj:215`（调度线程里的 `SkillEvolutionJob`）；承诺源 `f_llm/doc/spec/fix-loom-store-gateway-reuse/specs/loom-flow/spec.md:5-7`
- **来源**：存量
- **判据**：review-checklist §12.1（惰性初始化 / 检查-然后-写入 / 发布逸出）、§13（规格与实现漂移）
- **证据**：静态确定 —— `get` 是「读 `value`（`:46`）→ 为 `None` 则 `LoomStoreGateway()`（`:50`）→ 回写 `value`（`:51`）」的检查-然后-写入，`value` 是普通字段，无 `Mutex` / 原子。两个访问者是请求线程（`LoomWiring.cj:105` 的 store 闭包）与调度线程（`LoomWiring.cj:215` 任务触发时 `holder.get(injected)`）。
- **描述**：并发首调用时两个线程都可能看到 `None`，各建一个网关（内部会 `Stores.content()` + `Stores.meta()` + `EvolutionStores.current()`），构造计数 >1，与 spec 的「MUST 最多创建一个」直接冲突；`value` 的写也没有 happens-before，另一线程可能读到未安全发布的引用（是否会观察到未构造完成的对象取决于运行时内存模型，待确认）。后果量级：多一个实例与一组存储连接，不涉及数据损坏。`design.md:14` 把「并发下的懒加载优化」列为 Non-Goal，但 spec 的 MUST 是无条件的，两处口径不一致。
- **建议**：`get` 整体放进 `synchronized`（构造只在首次发生，临界区代价可接受）；或双检 + 原子引用。若坚持不做并发保证，则把 spec 的 MUST 降级为「单线程首次使用」并在 design 的 Non-Goal 中明说。

### [一般][存量] jit 占位符校验只覆盖向后引用，前向引用与任意 `{…}` 仍会漏成字面量

- **位置**：`f_llm/src/loom/Plan.cj:107-121`（`FlowPlan.validate` 的 `jit` 分支）、`f_llm/src/loom/LoomCompiler.cj:77-85`（`compileJit` 无校验）；承诺源 `f_llm/doc/spec/fix-loom-read-path/specs/loom-flow/spec.md:33-35`、`design.md:36-37`、`tasks.md:16`
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）、§14.1（半成品：只处理部分输入）
- **证据**：静态确定 —— 校验遍历 `seen.keys()`，而 `seen` 在同一次循环里先加入当前步骤 id（`Plan.cj:106-107`），因此只覆盖「已出现过的步骤」与 `start`；`{later.output}`（前向引用）、`{input}`、`{env.X}` 一律放行，继续拼进 `jitSourceOf` 当代码编译。design D3 写的是「`LoomCompiler` 在拼 jit 源码前扫一遍：正则近似 `\{[a-zA-Z_][\w.\-]*\}` 命中即抛」，tasks 3.1 也写「`LoomCompiler` 对 jit 源码里的 `{…}` 抛 `LoomException`」，实际落点在 `Plan.validate`，机制是「按已知 id 精确匹配」。
- **描述**：spec 写的是「源码若包含 `{…}` 形式的模板占位符，编译期 MUST 抛错」，实现收窄成「引用已声明步骤或 start 才抛」。最常见的**前向引用**（引用后定义步骤的输出）与拼错 id 仍然编译失败或变成字面量，正是该变更想消除的排查成本。文档把位置写成 `LoomCompiler`，后续维护按文档找不到校验点。
- **建议**：在 `LoomCompiler.compileJit` 编译前统一扫描整段 `step.input`（可先收集全部 step id + `start`，再扫一遍；无法识别的 `{…}` 也抛错），并修正 `design.md:36-37` / `tasks.md:16` 的位置与机制描述。

### [一般][存量] 提炼写入失败被静默吞掉，与「提炼失败可观测」的 MUST 冲突

- **位置**：`f_llm/src/loom/LoomMemoryPolicy.cj:160-165`（knowledge upsert）、`:192-198`（memory add）；承诺源 `f_llm/doc/spec/fix-loom-memory-owner/specs/loom-flow/spec.md:51-53`
- **来源**：存量
- **判据**：review-checklist §3（`catch { () }` 静默吞异常）、§11（错误处理静默）、§13
- **证据**：静态确定 —— knowledge 分支 `catch (error: Exception) { () }`，memory/experience 分支 `catch { false }`，只让 `written` 不递增。`LoomRunner.cj:238-252` 只在 `extract` 抛出或 `written==0` 时 `warn`；三条写入中只要有一条成功（例如 memory 成功、knowledge 失败），`written>=1`，既不告警也无痕迹。
- **描述**：`proposal.md:11` 的根因之一是「提炼失败三层 `catch` 静默」，本次只补了外层两类：`extract` 自己把异常吃掉，`catch (error)` 分支不会因单点写入失败触发。spec 的「异常与零写入 MUST 各留一条 warn，MUST NOT 完全静默」只对「全挂」成立。
- **建议**：`write` 内对 `LoomHostApi.callStore` 的失败各打一条 warn（带 kind / docId / flow），`written` 只统计成功；或让 `extract` 返回失败项列表由 `LoomRunner` 统一告警。

### [一般][存量] `docId` 唯一性仍依赖秒级时间戳 + 进程内序号，重启/多实例同秒会覆盖

- **位置**：`f_llm/src/loom/LoomMemoryPolicy.cj:155-156`（`stamp` + `nextDocSeq()`）、`:170-181`；承诺源 `f_llm/doc/spec/fix-loom-memory-owner/specs/loom-flow/spec.md:5-7`
- **来源**：存量
- **判据**：review-checklist §11（边界 / 契约与实现不符）、§13
- **证据**：静态确定（机制）—— `stamp = DateTime.now().toUnixTimeStamp().toSeconds()` 只有秒级精度，`seq` 是进程内静态计数、启动即为 1（`LoomMemoryPolicy.cj:167-181`）。同进程内两次执行必然不同，跨进程（重启、多实例）则可能完全相同。
- **描述**：proposal 的原始缺陷是「重启后序号归零，撞上历史文档即覆盖」。加时间戳把窗口从「每次重启必撞」缩小到「重启后与上一次首条写入落在同一秒」，但 spec 写的是无条件「MUST NOT 覆盖既有文档」，多实例部署同秒各自写第一条知识同样会互覆。后果是知识文档被覆盖（数据丢失），触发面窄但不为零。
- **建议**：`docId` 后缀改用毫秒/纳秒时间戳，或加进程唯一标识（启动时生成一次随机串/UUID），消掉「同秒 + 序号重来」这个组合。

### [一般][存量] 演进素材的分页发生在租户过滤之前，其他租户占满首页时本租户静默零素材

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:318-341`（`knowledgeOf`）；文档已声明为未覆盖项 `f_llm/doc/spec/fix-loom-memory-owner/proposal.md:31`
- **来源**：存量
- **判据**：review-checklist §11（静默少取 / 语义与注释不符）、§14.1（半成品：只处理部分输入）
- **证据**：静态确定 —— 先 `gateway.call('knowledge','docIds','{offset:0,limit:500}')` 取**全局**前 500 个 id（`SkillEvolutionJob.cj:319-324`），再在内存里用 `ownedBy` 前缀过滤（`:314-315`、`:333-336`）；`ownedBy` 只决定「读不读正文」，不参与「取哪 500 个」。
- **描述**：知识库多租户共用时，前 500 个 id 若被其他租户占满，本租户本轮演进素材为 0，且没有任何日志（`written==0` 告警只覆盖提炼，不覆盖素材为空）。proposal 把它归入「`limit=500` 上限未覆盖」，但实际后果是「本租户完全读不到」，不只是「少取几条」。
- **建议**：让 `knowledge.docIds` 支持按 docId 前缀过滤（或按 owner 建索引），把分页与租户过滤的顺序调换；同时把「素材为空」也纳入可观测（一条 debug/warn）。

### [一般][存量] 选路阶段把「状态查询异常」当成「状态漂移」，会摘除本来正常的流程

- **位置**：`f_llm/src/loom/Supervisor.cj:184-192`；承诺源 `f_llm/doc/spec/fix-loom-supervisor-lifecycle/specs/loom-supervisor/spec.md:5-7`、`design.md:22-24`
- **来源**：存量
- **判据**：review-checklist §11（错误分类 / 契约与实现不符）
- **证据**：静态确定 —— `let stillCompiled = try { service.status(chosen) == COMPILED } catch (e: Exception) { false }`，随后 `if (!stillCompiled) { let _ = unregister(chosen); return NO_USABLE }`；`unregister` 会从内存路由表移除条目（`Supervisor.cj:324-336`）。spec 只授权对「流程已不是 compiled」摘除，design D2（`design.md:24`）则说「`routable()` 与 `status()` 是候选枚举，异常等于『没有候选』」。
- **描述**：`status()` 抛异常（存储抖动、连接被回收）被折算成 `false`，于是对一条完全正常的流程执行 `unregister`，之后只能靠 `LoomService.tap` / `confirmFlow` 重新登记。「没有候选」只是本次不派发，「摘除」是状态变更，两者被合并了。
- **建议**：区分两种失败：`let status = try { Some(service.status(chosen)) } catch { None }`；`None` 时返回 `NO_USABLE` 且**不摘除**，只有 `Some(s) && s != COMPILED` 才摘除。`SupervisorOutcome.message` 可分原因，便于排查。

### [一般][存量] `StoreInvoker` 用「异常类型」判断是否已装配，业务异常也会触发新建网关并重放同一请求

- **位置**：`f_llm/src/loom/StoreFunctions.cj:84-96`；文档 `f_llm/doc/spec/fix-loom-store-gateway-reuse/design.md:37-46`、`specs/loom-flow/spec.md:5-7`
- **来源**：存量
- **判据**：review-checklist §11（错误处理：错误分类过粗）、§13（与「MUST NOT 在每次调用时重新构造」冲突）
- **证据**：静态确定 —— `case None => try { LoomHostApi.callStore(...) } catch (error: LoomException) { LoomStoreGateway().call(...) }`。已装配时 `callStore` 执行的是同一个网关函数（`LoomHostApi.cj:169-177`），而网关对未知 op 抛的也是 `LoomException`（`LoomStoreGateway.cj:355` `unsupported ${kind}.${op}`）。因此「已装配 + op 拼错」也走 fallback：新建网关（`Stores.content()` / `Stores.meta()` / `EvolutionStores.current()`）再重放请求。
- **描述**：`design.md:41-44` 用 `catch (e: LoomException)` 识别「未装配」，但未装配与业务错误的异常类型相同。后果：(1) 每次业务异常多开一次存储、多一条连接——正是本变更要消除的开销；(2) 写类 op（`add`/`upsert`/`remove`）在「已部分生效后抛错」时会被重放，存在重复写入面（是否发生取决于底层实现，待确认）。
- **建议**：只对「未装配」回退。让 `LoomHostApi` 暴露 `storeInstalled(): Bool`，或未装配抛专用类型，`StoreInvoker` 只 catch 该类型；其余异常原样上抛（工具层已有 `memoryCall failed: …` 包装）。

### [一般][存量] design 声称「网关按 op 白名单执行」，实际没有白名单，`character.set` / `prompt.put` / `skill.remove` 都能从 `loomStoreCall` 直达

- **位置**：`f_llm/doc/spec/fix-loom-tool-coverage/design.md:34`；实现 `f_llm/src/loom/LoomStoreGateway.cj:321-341`、`f_llm/src/loom/StoreFunctions.cj:193-215`
- **来源**：存量
- **判据**：review-checklist §10（安全性：外部输入未校验 / 越权面）、§13（文档承诺与实现不符）
- **证据**：静态确定 —— `design.md:34` 的风险是「模型滥用 `loomStoreCall`（例如 kind=character 改人格）」，缓解写「网关按 op 白名单执行」。网关只有 kind / op 的 if 链，无白名单、无只读限制：`character.set` / `character.reset`（`LoomStoreGateway.cj:321-341`）、`prompt.put` / `prompt.remove`、`skill.remove`、`memory.remove`、`knowledge.remove` 全部可达；`StoreCallFunction` 只校验 kind/op 非空与 payload「像个对象」（`StoreFunctions.cj:193-208`）。
- **描述**：模型可以在流程里把某用户的人格、提示词、技能删改（`character.set` 会整体覆盖 `characterKey`/`prompts`）。这是文档自己识别出的风险，但给出的缓解措施不存在，读文档的人会以为写操作被挡住了。
- **建议**：二选一——(a) 在工具层做读写分级：写 op 默认不放行，需显式开关；(b) 若确认要保留写能力，把 `design.md:34` 的缓解列改成真实做法（如「由 `ToolScope` 控制工具可见性，不做 op 级限制」），并写明风险承担方式。

### [一般][存量] 网关创建时机：proposal / tasks 说「装配期建一个」，design 与实现是「懒建一次」，design 风险表还留着急切方案

- **位置**：`f_llm/doc/spec/fix-loom-store-gateway-reuse/proposal.md:18`、`tasks.md:9`、`design.md:18-30`、`design.md:69-71`；实现 `f_llm/src/loom/LoomWiring.cj:38-53,103-106`
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不一致 / 文档内部自相矛盾）
- **证据**：静态确定 —— 实现是懒建：`LoomGatewayHolder.get` 首次调用才 `LoomStoreGateway()`，`wire` 只 `installStore` 一个闭包（`LoomWiring.cj:103-106`），装配阶段不触碰存储；`f_llm/doc/loom.md:219` 也写「存储网关**懒建一次**：装配阶段不连存储」。而 `proposal.md:18` 写「在装配期建**一个**网关」，`tasks.md:9` 写「`wire` … 装配期建一次并复用」；`design.md:29` 明确否决了「在装配期直接建」，`design.md:71` 的风险行却仍是「装配期建网关若失败（库不可用），整个 wire 抛错」——该风险在懒建方案下不存在。
- **描述**：同一变更三份文档给出两种相反的创建时机，且 design 的风险表是急切方案的残留。按 proposal / tasks / 风险表理解，会误判「启动期是否连库」「`wire` 是否可能因存储不可用抛错」。
- **建议**：以代码与 `doc/loom.md:219` 为准统一为懒建：改 `proposal.md:18`、`tasks.md:9` 的措辞，把 `design.md:71` 的风险行改写为「异常延迟到首次 store 调用暴露」。

### [一般][存量] 若干已实现行为没有进对外文档：`wire(host:)` / `characterUserId`、演进归属回落、`prompt.get` 的 `version<=0`

- **位置**：`f_llm/doc/spec/fix-loom-supervisor-lifecycle/tasks.md:21`、`fix-loom-memory-owner/tasks.md:30`、`fix-loom-persona-prompt/tasks.md:24`；实现 `f_llm/src/loom/LoomWiring.cj:73-77,129-141`、`LoomStoreGateway.cj:277-285`、`doc/loom.md:328,569-570`
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API / 关键配置未文档化）、§13
- **证据**：静态确定 —— ①`tasks.md:21` 声称「README 中英补 `host` 参数说明」，但 `grep -n "host:" README.md README_en.md` 无命中（wire 示例只有 `chat` / `plannerModel`，`README.md:332`、`README_en.md:328`），`characterUserId:` 同样无命中；②`tasks.md:30` 声称「`doc/loom.md` 补演进归属派生」，但 `evolutionUserId` 只出现在一个示例（`doc/loom.md:328`），`evolutionOwner` 在 `doc/loom.md` 中无命中；③`tasks.md:24` 声称「网关表补 `prompt.get/remove` 的版本语义」，表中只写了 `remove` 必须给版本，`latest / get` 行没有「`version<=0` 取最新」（`doc/loom.md:569`），而代码 `LoomStoreGateway.cj:278-281` 明确实现该语义。
- **描述**：`wire(host:)` 改变了「已安装宿主不被覆盖」的装配语义（`LoomWiring.cj:129-136`），`evolutionUserId/Namespace` 未显式给时会静默跟随 `LoomMemoryPolicy`（`:152-172`）。这两条都容易被误配，却只存在于代码里；`host` 是 `public static func wire` 的参数，不属于 internal 细节。
- **建议**：在 `README.md` / `README_en.md` 的 loom 装配小节补 `wire` 参数表（`host`、`characterUserId`、`evolutionUserId`、`evolutionNamespace`、`gateway`）；`doc/loom.md` 演进小节写明「未显式给 → 跟随记忆策略，写读同源」；网关表 `prompt` 行补 `get` 的 `version<=0 = latest`。

### [一般][存量] 「同一进程只能跑一个流程」是硬约束，但只写在内部 KDoc，`executeNow` 也没有串行化

- **位置**：`f_llm/src/loom/LoomHostApi.cj:24-28`（KDoc 声明「约束：**单线程使用**」）、`LoomHostApi.cj:47-49,183-205,212,235`、`LoomContextLog.cj:51-53`、`LoomService.cj:122-140`；文档 `f_llm/doc/spec/fix-loom-persona-prompt/design.md:40-46`
- **来源**：存量
- **判据**：review-checklist §14.1（关键限制未记录）、§12.1（共享可变状态：先证线程封闭）
- **证据**：静态确定（共享路径）—— `personaText` / `skillText` / `values` / `current` 与 `LoomContextLog.turns` 全是 `private static var`，只由一把 `mutex` 保证不撕裂，不提供按流程隔离；`LoomService.executeNow`（`LoomService.cj:122-140`）每次 `new LoomRunner` 后直接 `run`，无队列、无锁。`LoomHostApi.cj:27-28` 自己声明「并发流程需各自持有独立进程」。
- **描述**：按 §12 误报边界，这里**不判**为并发缺陷（类型已声明非线程安全），问题在文档面：这条「一个进程只能跑一个流程」的硬约束没有进 `README` / `doc/loom.md` / `doc/known-limitations.md`，`fix-loom-persona-prompt/design.md:45` 的 Risks 也只写了「`LoomCharacterScope` 是静态态」。宿主若在 HTTP 服务里并发调用 `executeNow`（看着像普通 API），会出现 A 流程拿到 B 的人格/技能前缀，A、B 的对话轮次进同一个 `turns` 缓冲，提炼时把别人的对话写进自己的记忆。`doc/loom.md` 的并发小节只讲了「计划 `parallel` 走 `AsyncFlow`」，容易被读成「多流程并发安全」。
- **建议**：把该约束写进 `doc/known-limitations.md` 与 `README`（一句话：「同一进程同一时刻只应执行一个 loom 流程；并发请分进程或自行串行化」）；`LoomService.executeNow` 若将来要支持并发，应改为显式上下文（`LoomRunner` 内 context 随 `bind` 传递，或 `ThreadLocal` + `finally` 清理），而不是静态字段。

### [轻微][存量] 同类「单字段 Box」类在 loom 内重复 25 份

- **位置**：`f_llm/src/loom/LoomMemoryPolicy.cj:27,31`、`LoomCharacterScope.cj:62`、`LoomHostApi.cj:32,36,41`、`LoomRegistry.cj:78-90`、`LoomRunner.cj:26,45,49,53,58`、`LoomTimeout.cj:21`、`LoomContextLog.cj:36`、`LoomAgent.cj:89`、`EvolutionLeases.cj:72`、`SkillCatalog.cj:358-375`、`SkillEvolutionJob.cj:464`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑：只改类型名 / 同一技巧复制）
- **证据**：静态确定 —— `grep -rn "class .*Box" src/loom/*.cj`（排除 `_test`）共 25 处，形状一律 `class XxxBox { public var value: T = 初值 }`，唯一用途是把 `synchronized`（Unit 语义）的返回值带出来，用法一律「new → 锁内赋值 → 锁外读」。本部分审查的变更文档也各自新增了一个（`PolicyBox`、`DocSeqBox`、`ScopeBox`）。
- **描述**：同一惯用法复制 25 次，每加一处锁就要再抄一个类；`public var` 在这些内部类上也无意义（类型本身不可见）。
- **建议**：放一个泛型持有者 `class Box<T> { public var value: T }`（构造参数传初值），各调用点改 `let box = Box<Int64>(0)`；机械替换、无行为变化，顺手可把 `public var` 收成 `var`。

### [轻微][存量] 提炼告警条件里的 `policy.enabled` 是恒真判断

- **位置**：`f_llm/src/loom/LoomRunner.cj:241`
- **来源**：存量
- **判据**：review-checklist §1（恒真分支）
- **证据**：静态确定 —— `if (written == 0 && policy.enabled)` 位于 `if (policy.enabled && !turns.isEmpty())`（`LoomRunner.cj:238`）内部，第二个条件永远成立。
- **描述**：重复判断，读者会以为存在「策略关闭也要告警」的分支。
- **建议**：去掉 `&& policy.enabled`。

### [轻微][存量] 六个已完成的变更仍留在 `doc/spec/` 未归档，且 memory-owner 的 tasks 缺 follow-up 段

- **位置**：`f_llm/doc/spec/fix-loom-memory-owner/`、`fix-loom-persona-prompt/`、`fix-loom-read-path/`、`fix-loom-store-gateway-reuse/`、`fix-loom-supervisor-lifecycle/`、`fix-loom-tool-coverage/`；对照 `f_llm/doc/spec/archive/`（仅两项：`2026-10-30-f-llm-memory-storage/`、`2026-10-31-f-llm-store-wiring/`）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 状态不符）
- **证据**：静态确定 —— 五份 tasks 的 `Workflow follow-up` 都写着「`openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/<name>/`」（`fix-loom-persona-prompt/tasks.md:26-28`、`fix-loom-read-path/tasks.md:24-26`、`fix-loom-store-gateway-reuse/tasks.md:23-25`、`fix-loom-supervisor-lifecycle/tasks.md:23-25`、`fix-loom-tool-coverage/tasks.md:21-23`），任务全部 `[x]`，目录仍在原地；`fix-loom-memory-owner/tasks.md`（1-34 行）连 follow-up 段都没有。
- **描述**：`doc/spec/` 同时存放「进行中」与「已完成」变更，读者无法区分当前有效规格；仓库已有 `archive/` 约定，这六个却没进去。
- **建议**：按 follow-up 归档这六个目录（保留 spec delta 供追溯），并给 memory-owner 的 tasks 补 follow-up 段；归档前先处理本报告里与这些变更相关的未兑现项。

### [轻微][存量] 装配状态散成 5 处进程级静态，各文档只分别声称「与 `LoomServices` 一致」

- **位置**：`f_llm/src/loom/LoomWiring.cj:150`（`reload`）、`:39`（`LoomGatewayHolder.value`）、`LoomCharacterScope.cj:30`（`installed`）、`LoomMemoryPolicy.cj:75`（`current`）、`LoomHostApi.cj:47/212/235`（host / persona / skills）
- **来源**：存量
- **判据**：review-checklist §10（设计合理性 / 可测试性）
- **证据**：静态确定 —— 三份文档分别在 Risks 表写「进程级单例语义，与 `LoomServices` 一致」（`fix-loom-supervisor-lifecycle/design.md:53`、`fix-loom-persona-prompt/design.md:45`、`fix-loom-store-gateway-reuse/design.md:72`），但没有一处汇总「一次装配写哪些静态、`wire` 重入时谁覆盖谁、测试要重置哪几个」。
- **描述**：`wire` 每次调用都会覆盖 `reload` / `currentHost` / `current` / `installed`，并新建 `LoomGatewayHolder`（旧 holder 的已建网关仍被旧闭包持有直到重装）。装配契约只能靠通读多份文档拼出来，测试隔离也没有统一入口。
- **建议**：在 `doc/loom.md` 装配小节加一张「装配写入的进程级状态 / 重置方式」表，或引入单个 `LoomRuntime` 持有这些字段并提供 `resetAll()`。

## 优化可行性方案

### [堆内存] `experience` 列表合并去副本

- **现状**：`LoomStoreGateway.cj:149-163` 为双 kind 各建一份 `ArrayList<MemoryRecord>`（每个最多 `limit` 条），再逐条 `add` 进 `merged`，同一批记录同时存在两份引用数组；缺省 `limit=50` 时最多 100 条记录 + 3 个列表对象。
- **方案**：给 Store 增加「kind 集合 + 分页」的读取（`listByKinds`），一次取一页，去掉 `merged` 中间容器；`MemoryQuery.kinds` 只服务 `search`，不能直接复用。
- **预期**：每次 `memory.list`（experience）少 2 个 `ArrayList` 与 1 次全量拷贝；对象数从 `3 + 2N` 降到 `1 + N` 量级。
- **代价**：`MemoryStore` 契约变更，`SqlLoomStore` / `FStoreLoomStore` / hydra 实现都要跟进。
- **验证**：`getAllocatedHeapSize()` 前后对照，跑 200 次 `memory.list`（limit=50、两 kind 各 50 条）；同时断言返回条数与顺序不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 演进素材的 N+1 跨边界读取

- **现状**：`SkillEvolutionJob.cj:318-341` 先取最多 500 个 docId，再对每个「归属匹配」的 id 各发一次 `knowledge.get`，即 1 + K 次 `LoomStoreGateway.call`（每次含 JSON `parse` 与字符串拼装），K 最大 500，全部在演进任务的单线程里串行。
- **方案**：给知识存储加批量读（`docIds` 直接返回 id+content，或 `knowledge.getMany`），把 K+1 次降到 1 次；顺带把租户前缀过滤下推到存储层（同时解决上文「分页先于过滤」）。
- **预期**：跨边界调用次数下降一个量级（K≈500 时约 500→1）；端到端收益取决于单次 `call` 开销。
- **代价**：新增存储侧 API，三个实现都要补；返回体变大，单次物化上限需评估。
- **验证**：`cjprof record` 跑一次演进任务（500 条知识素材），对比 `knowledgeOf` 自耗时；`cjpm bench -O2` 同输入多轮取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 装配期单网关复用确实降低了 store 步骤端到端延迟（proposal 声称「每步 3 次配置读 + 2~3 次开库」） | `fix-loom-store-gateway-reuse/proposal.md:12`；`LoomWiring.cj:103-106` | 改前/改后单步延迟绝对值与分布 | 10 步流程含 5 个 store 步骤，`cjpm bench -O2` 各跑 50 轮取中位数与 P95 |
| 2 | `knowledgeOf` 的 1+K 次网关调用是演进任务的主要自耗时 | `SkillEvolutionJob.cj:318-341` | 自耗时占比、单次 `call` 开销 | `cjprof record` 跑演进任务，知识库 500 条、跨 3 个租户 |
| 3 | `memory.list(experience)` 的双份物化对 GC 有可测影响 | `LoomStoreGateway.cj:149-163` | 分配量、GC 次数、单次返回条数 | `cjprof heap` + 200 次调用，对比单次查询实现 |
| 4 | 并发调用 `executeNow` 在生产并发度下会实际发生人格/轮次串味 | `LoomHostApi.cj:183-205,212,235`、`LoomContextLog.cj:51-53` | 峰值并发流程数、注入前缀命中率 | 起 8 线程各跑 100 次带不同 persona 的流程，断言每个流程的 `fullSystem` 只含自身 persona |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/doc/spec/fix-loom-memory-owner/proposal.md` | .md | ✅ | 5 条根因逐条回查实现，均已落地；`limit=500` 未覆盖项已声明（见 #6） |
| 2 | `f_llm/doc/spec/fix-loom-memory-owner/specs/loom-flow/spec.md` | .md | ✅ | 5 条 Requirement：docId 格式 ✅、加锁 ✅、演进同源 ✅、租户过滤 ✅；`MUST NOT 覆盖` / `MUST NOT 完全静默` 有偏差（#4 #5） |
| 3 | `f_llm/doc/spec/fix-loom-memory-owner/tasks.md` | .md | ✅ | 任务与实现一致；6.2 的 `doc/loom.md` 演进归属未兑现（#11）；缺 follow-up 段（#15） |
| 4 | `f_llm/doc/spec/fix-loom-persona-prompt/design.md` | .md | ✅ | D1–D4 全部落地；Risks 只写了 `LoomCharacterScope`，漏记 persona/skills/turns（#12） |
| 5 | `f_llm/doc/spec/fix-loom-persona-prompt/proposal.md` | .md | ✅ | 四处问题均已修复，与 `LoomRunner` / `LoomStoreGateway` 行为一致 |
| 6 | `f_llm/doc/spec/fix-loom-persona-prompt/specs/loom-flow/spec.md` | .md | ✅ | 4 条 Requirement 与实现一致（`LoomHostApi.cj:205` 记步骤 system） |
| 7 | `f_llm/doc/spec/fix-loom-persona-prompt/tasks.md` | .md | ✅ | 5.2 部分兑现：`prompt.get` 版本语义未进网关表（#11）；未归档（#15） |
| 8 | `f_llm/doc/spec/fix-loom-read-path/design.md` | .md | ✅ | D1/D2 落地；D3 的落点与正则方案未按原样实现（#3） |
| 9 | `f_llm/doc/spec/fix-loom-read-path/proposal.md` | .md | ✅ | 三条静默错果的修复均已接线（`kindsOf` / `pageOf` / jit 校验） |
| 10 | `f_llm/doc/spec/fix-loom-read-path/specs/loom-flow/spec.md` | .md | ✅ | 分页 MUST 与实现有偏差（#1）；jit MUST 覆盖不全（#3） |
| 11 | `f_llm/doc/spec/fix-loom-read-path/tasks.md` | .md | ✅ | 3.1 的位置描述有误（#3）；4.1「基线以当前为准」无具体数字，无法复核；未归档（#15） |
| 12 | `f_llm/doc/spec/fix-loom-store-gateway-reuse/design.md` | .md | ✅ | D1 落地但无同步（#2）；D2/D3/D4 与实现一致；风险表残留急切方案（#10） |
| 13 | `f_llm/doc/spec/fix-loom-store-gateway-reuse/proposal.md` | .md | ✅ | 「装配期建一个」与实现矛盾（#10）；性能口径为调用次数推导，非计时基线（待验证 #1） |
| 14 | `f_llm/doc/spec/fix-loom-store-gateway-reuse/specs/loom-flow/spec.md` | .md | ✅ | 「MUST 最多创建一个」冲突（#2）；「MUST NOT 每次调用构造」失败路径未满足（#8） |
| 15 | `f_llm/doc/spec/fix-loom-store-gateway-reuse/tasks.md` | .md | ✅ | 2.1 措辞有误（#10）；未归档（#15） |
| 16 | `f_llm/doc/spec/fix-loom-supervisor-lifecycle/design.md` | .md | ✅ | D1/D3/D4 落地；D2 的「异常=没有候选」与实现的「异常=摘除」不一致（#7） |
| 17 | `f_llm/doc/spec/fix-loom-supervisor-lifecycle/proposal.md` | .md | ✅ | 与实现一致 |
| 18 | `f_llm/doc/spec/fix-loom-supervisor-lifecycle/specs/loom-supervisor/spec.md` | .md | ✅ | 摘除 / 可观测 / 宿主不覆盖均已实现（`Supervisor.cj:184-194`、`LoomBootstrap.cj:30-31`）；异常分类有缺口（#7） |
| 19 | `f_llm/doc/spec/fix-loom-supervisor-lifecycle/tasks.md` | .md | ✅ | 4.2 的 README `host` 说明未兑现（#11）；未归档（#15） |
| 20 | `f_llm/doc/spec/fix-loom-tool-coverage/design.md` | .md | ✅ | D1–D4 落地（`StoreFunctions.cj:167-215`、`LoomService.cj:122-140`、`Plan.cj:149-157`）；风险表的「op 白名单」不存在（#9） |

合计：`.cj` 0 个 / `.md` 20 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 #1 #4 #5 #6 #7、错误分类 #8、安全性 #9、关键限制未记录 #12、装配设计 #16；语言特性按文档所述实现抽查（`synchronized` Unit 语义、`Option` 取值）无额外命中 |
| §1 死代码 | 1 | 20 份文档引用的符号逐一搜实现：`kindsOf` / `pageOf` / `ownedBy` / `evolutionOwner` / `lastReload` / `buildCount` / `LoomCharacterScope` / `loomStoreCall` / `StoreInvoker` / `FlowPlan.skills` / `executeNow(skills:)` 均存在且被调用；唯一落点错误是 `LoomCompiler`（并入 #3）。命中 `LoomRunner.cj:241` 的恒真条件（#14） |
| §2 重复逻辑 | 1 | 5 份 spec delta 的 18 条 Requirement 两两比对：memory-owner（演进跟随记忆策略）与 persona（人格解耦记忆策略）方向相反、语义不同，不算重复；同一错误文案 `jit step does not support {…}` 仅一处定义。命中 25 个同形 Box 类（#13） |
| §3 空实现 | 1 | 文档无空实现；实现侧命中两处 `catch { () }` / `catch { false }`（#4） |
| §4 栈溢出 | 0 | 本部分文档不涉及递归；被核对的 `validate` / `kindsOf` / `ownedBy` 均为单层循环 |
| §5 OOM | 0 | 唯一无界项 `docIds limit=500` 已被 proposal:31 声明且为常量上限；`knowledgeOf` 结果受其约束，不构成无界增长 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；网关复用收益与 N+1 调用列入「待验证假设」#1 #2 |
| §6.2 大粒度锁 | 0 | 文档未引入锁内 I/O；`LoomMemoryPolicy` / `LoomCharacterScope` 的 `synchronized` 只包字段读写，`LoomHostApi.render` 已把替换移出锁外 |
| §6.3 并发串行 | 0 | 演进任务是 cron 驱动的单线程串行设计，无「spawn 后立刻 get」形态 |
| §6.4 低效算法 | 0 | `knowledgeOf` 的 1+K 次调用属调用次数放大，无耗时数据，按规则降为待验证假设 #2 |
| §7 降堆内存方案 | 1 | experience 列表合并去副本（见优化方案） |
| §8 降 CPU 方案 | 1 | 演进素材 N+1 批量化（见优化方案） |
| §9 local mode 可行性 | 0 | 本部分为文档，未引入函数内临时大对象；被引用的实现无峰值内存基线，收益不可证 |
| §11 现有代码的 BUG（存量） | 8 | #1 #2 #3 #4 #5 #6 #7 #8，均为「文档所述行为的实现缺陷」，可能与代码分部分重复，合并时去重 |
| §12 并发安全与锁粒度 | 2 | `LoomGatewayHolder` 惰性初始化（#2）、进程级注入态与单线程约束（#12）；其余静态态均有 `Mutex` 保护 |
| §13 文档一致性 | 7 | #1 #3 #4 #5 #6 #10 #11 为文档与实现漂移或文档间矛盾；另核对 20 份文档的用例基线（600→621→625→634）单调，无矛盾 |
| §14 功能完备性与 README 覆盖 | 2 | `wire(host:)` / 演进归属 / `prompt.get`（#11）、并发限制未记录（#12）；`loomStoreCall`、`characterUserId`、网关懒建在 `doc/loom.md` 均有对应段落 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 12 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量 16 条（本部分无 diff，全部为存量），是否纳入修复待用户决定。

## 总评

本部分 20 份文档对应 5 个 loom 变更（记忆归属、人格/提示词、读路径、网关复用、Supervisor 生命周期）+ 1 份工具设计。主体实现是到位的：记忆策略与人格作用域确实加了锁，docId 带上了租户前缀且演进侧按前缀过滤，prompt 版本语义、宿主不被覆盖、陈旧路由摘除、`lastReload` 可观测、`loomStoreCall` 与 `StoreInvoker` 的复用链路都能在代码里逐条对上。没有「承诺但完全没实现」的功能，这是本模块文档质量较好的部分。

问题集中在四处：

1. **自己写的 MUST 被打折**。`experience` 分页上限（#1）、网关「最多创建一个」（#2）、jit「含 `{…}` 即抛错」（#3）、提炼「不得完全静默」（#4）、`docId`「不得覆盖」（#5）都是 spec 原文的无条件要求，实现各让了一步。其中 #2 #3 #4 改动小、收益直接，可优先排期。
2. **错误分类太粗**：`status()` 异常被当成状态漂移而摘除正常路由（#7）、`StoreInvoker` 用异常类型区分「未装配」并在失败路径重建网关重放（#8）、`loomStoreCall` 没有 design 声称的 op 白名单（#9）。三者都是「不崩但给错结果 / 放大开销」。
3. **文档之间口径不一**：网关创建时机 proposal/tasks 与 design/实现相反（#10），若干已实现行为与两条硬约束没进对外文档（#11 #12）。`executeNow` 的「单进程单流程」限制只写在 `LoomHostApi` 的 KDoc 里，最容易被宿主误用。
4. **文档治理**：六个已完成变更未归档（#15），装配静态态无统一重置入口（#16），25 个同形 Box 类（#13）。

没有阻塞项：不存在会导致崩溃、越界、无界增长的缺陷；性能面唯一值得测的是演进素材的 1+K 次 `knowledge.get`，已按铁律放进「优化可行性方案（无基线）」与「待验证假设」，不进修复清单。
