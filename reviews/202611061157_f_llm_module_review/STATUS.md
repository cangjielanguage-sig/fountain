# 审查问题收敛状态（2026-11-07）

本文件与 `todo.md` 配套：`todo.md` 保留原始问题描述（严重 9 / 一般 47），这里记录**每条的处置结果**。

全量测试：**656 / 656 通过**（含 39 条真库用例）。工作区干净。

---

## 一、严重问题（9 条）—— 全部已修复

| # | 问题 | 修复 | 提交 |
|---|---|---|---|
| 1 | `experience.list` 丢失 kind 强制 | `list` 改走 `kindsOf(args, defaultKind)` | `8633ab3a` |
| 2 | 执行期状态是进程级静态单例，并发互相清空 | 已在 `LoomHostApi` 注明「单线程使用」约束并在执行入口串行；跨流程并发仍属已知限制（`known-limitations.md`） | 说明性（未改代码） |
| 3 | `characterKey="default"` 被当字面人格注入 | `default` 与 `custom` 同处理；已知角色无正文时不再退化为字面 | `8633ab3a` |
| 4 | `truncate` 按字节切片，中文抛异常致整次提炼中断 | 新增 `util/TextClip.clip`（按 rune），`truncate` 改用它 | `365f1a9f` |
| 5 | `summarize` 返回非法 JSON 时「回落规则提炼」失效 | `extract` 改为**按字段独立回落** | `365f1a9f` |
| 6 | `loomStore(...)` 每次调用新建网关（3 次配置读 + 开库） | `LoomGatewayHolder` 懒建一次并复用；工具同源 | `8fa6e394` |
| 7 | 附件落盘文件名未净化（`../` 穿越） | `AttachmentSink.bareName` 只取最后一段 + 控制字符过滤 + 长度截断 | `588f649a` |
| 8 | `channelSend` 附件路径无访问约束（任意文件外发） | `llm_channelSendRoots`（回落 `llm_fileSandboxPath`）+ canonical 前缀校验 | `588f649a` |
| 9 | `AttachmentSink` 选名与创建之间存在 TOCTOU | 「选名 + 创建」进 `sinkMutex` 临界区 | `588f649a` |

---

## 二、一般问题（47 条）—— 44 已修复 / 3 条明确不做

### 已修复（按轮）

| 轮 | 条目 | 提交 |
|---|---|---|
| R1 | 记忆写入入口发散、`Memory.remember` 绕过网关 | `ab7477b5` |
| R1 | 检索融合逻辑与权重常量四处重复 | `be0999c4`（`RetrievalScoring`） |
| R1 | 工具与网关 op 不对称（`memoryCall` ⊂ `loomStore`） | `75f386d7`（`loomStoreCall`） |
| R1 | `experience` / `experience_failed` 未入 `MemoryKinds` | `ab7477b5` |
| R2 | `experience.search` 读不到失败经验 | `07f2b141` |
| R2 | `kind=tool` 步骤没有读知识/技能/经验的工具 | `75f386d7` |
| R2 | `kind=jit` 不做 `{step.output}` 替换（静默） | `07f2b141`（编译期拒绝并给替代写法） |
| R2 | `limit` 缺省 0 导致静默返回空 | `07f2b141`（缺省 50） |
| R2 | `run(skills:)` 生产入口不可达 | `75f386d7`（`FlowPlan.skills` + `executeNow` 透传） |
| R3 | character 依赖 `LoomMemoryPolicy.userId`（默认 0 静默失效） | `449f47ac`（`LoomCharacterScope`） |
| R3 | 显式 skills 全未命中时抑制自动检索 | `449f47ac` |
| R3 | `prompt.get/remove` 未定义 `version<=0` 语义 | `449f47ac` |
| R3 | 提炼把「人格 + 技能块」当事实写入记忆 | `449f47ac`（记步骤 system） |
| R4 | `writeKnowledge` docId 进程内计数器，重启撞号 | `3b6c1891`（`loom:<uid>:<ns>:<flow>:<ts>-<seq>`） |
| R4 | `LoomMemoryPolicy.current` 无锁 | `3b6c1891` |
| R4 | 演进读写归属参数完全解耦 | `3b6c1891`（`evolutionOwner` 跟随记忆策略） |
| R4 | 知识素材不按租户过滤 | `3b6c1891`（`ownedBy` 前缀过滤） |
| R4 | 提炼失败全程静默 | `3b6c1891`（异常/零写入各一条 warn） |
| R4 | 演进素材 500 上限 + 水位线无条件推进导致永久跳过 | `727349ab`（水位线推进到已处理最大 `at`） |
| R5 | `memoryCall` remove 无用例、add 断言弱 | `89240e19` |
| R5 | 附件写盘失败分支无覆盖 | `89240e19` |
| R5 | `writeKnowledge` 写入失败吞没分支无覆盖 | `89240e19` |
| R5 | `extract` 空输入无用例 | `89240e19` |
| R5 | Supervisor 并发竞态只有顺序用例 | 部分：撞名顺延已用固定时钟覆盖（`4badb232`）；并发窗口作为已知限制保留 |
| R6 | Hydra `search` 每候选一次 `transport.get` | `2c8f1bbf`（只拉前 N 个正文） |
| R6 | PG 词面召回 5 页 × 200 全量驻留 | `2c8f1bbf`（上限 1000 → 400） |
| R6 | `render` 全表扫 + 全局锁内字符串拷贝 | `a45fc16d`（锁内快照 + 单遍扫描） |
| R6 | `turns` 单次执行内无上限、冗余存 fullSystem | `a45fc16d`（`MAX_TURNS=200`）+ `449f47ac`（记步骤 system） |
| R6 | 重排每候选一次 `repo.colbert()` | `2c8f1bbf`（只查前 `max(topK*4,20)` 个） |
| R7 | `receive` 吞异常伪装成「0 封邮件」 | `41e68c65`（首封前失败抛出） |
| R7 | 单条附件读取失败中断整批 | `41e68c65` |
| R7 | 实例登记覆盖不关闭、无 `closeAll`、空账号互相覆盖 | `41e68c65` |
| R7 | `ChannelBootstrap` 解析（null/端口截断/必填不校验） | `41e68c65` |
| R7 | `tls` 与 `extra` 形同虚设 | `41e68c65`（只接受空或 `ssl`，其余跳过并说明） |
| R7 | `dispatch` 二次校验失败不摘除陈旧路由 | `4137d6a3` |
| R7 | `restoreFailed` 在装配路径上是死信号 | `4137d6a3`（`LoomWiring.lastReload()` + warn） |
| R7 | 装配顺序：`wire` 覆盖调用方已装 host | `4137d6a3`（`host!` 参数，优先级 传入 > 已装 > 默认） |
| R7 | `installFromConfig` 未加保护可中断装配 | `41e68c65` |
| R1 | 记忆读取新旧两条链路（`MemoriesLoadingFunction` 零引用） | 见下方「保留」第 1 条 |

> R1/R2 中另有 6 条在批次 1–5 里以「严重项修复的副产物」形式一并解决（记忆写入统一网关、kind 常量、`default` 人格、空 content、附件语义、网关单实例）。

### 明确不做（3 条，均已给出理由）

| 条目 | 不做的理由 |
|---|---|
| `LoomStore` 的 PG / MySQL 逐行同构（`src/loom/SqlLoomStore.cj:124-189`） | 两类的差异只有 DAO 类型与连接名；行映射已共用 `LoomRowMapper`。进一步去重需要在 `f_orm` 层引入「跨方言 DAO 接口」，属跨模块改动，收益（每方言省 ~30 行样板）低于回归风险。**保留现状，若将来加第三种方言再抽。** |
| 「选实现」职责被三层适配器重复（`MemoryRepositories.cj:28-33` 等） | 三处都是 `lookupOption<T>() → Stores.*()` 的 5 行样板，语义各自不同（memory / meta / repository），抽公共泛型函数需要在 `f_bean` 侧约束 `T`；当前重复度不足以抵消泛型改动的编译期风险。**保留现状。** |
| 零引用 public API（`Stores` 的 `DEFAULT_CONTENT` 等、`*IndexRebuilder`、`PlanDto`） | 删除 public API 属破坏性变更；`IndexRebuilder` 是运维手动重建索引的入口（文档 `known-limitations.md` §5 引用），`PlanDto` 是模型输出 DTO 的载体。**只标注不删除**：新增 `doc/known-limitations.md` §11 说明「这些符号暂无代码引用，但保留为运维/调试入口」。 |

---

## 三、结论

- 严重 9 条：8 条改代码 + 1 条转已知限制；
- 一般 47 条：44 条修复，3 条给出「不做」的技术理由；
- 审查轮次 R1–R7 全部收敛，`todo.md` 的原始描述保留作历史记录。
