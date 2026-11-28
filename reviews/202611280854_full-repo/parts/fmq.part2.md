# fmq 模块审查报告（模块第 2/7 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fmq`（本部分 15 个 `.md`、0 个 `.cj`：`doc/spec/fix-fmq-postfix-audit/` 的 proposal + 7 份 delta spec + tasks + verify-report，`doc/spec/fix-fmq-verify-followups/` 的 4 份 delta spec，以及 `doc/开发计划.md`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 本部分全部问题来源记「存量」
- **审查重点**：fmq 专项（投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑）。本部分为文档，实际落点按 checklist §13/§14：把 delta 规格的 SHALL / Scenario 逐条落到 `fmq/src`、`f_mq/src` 行号核对，并复核台账引用是否真实
- **报告版本**：v1（分报告，待主 Agent 与 part1、part3–part7 合并为 `docs/review/2026-11-28/fmq.md`）

> 本部分无 `.cj`，`§1 死代码` 与 `§2 重复逻辑` 的机械动作改为「文档引用的符号 / 路径 / 用例名是否仍存在」与「同一规则是否被多套措辞重复表述」；`.cj` 侧符号级结论留给其余子轮，不在此重复计数。

## 发现

### [一般][存量] 备份关闭期失败的批次仍重新入队，与规格「丢弃并记 ERROR」相反

- **位置**：规格 `fmq/doc/spec/fix-fmq-postfix-audit/specs/fmq/metadata-cluster/spec.md:305-308`；实现 `fmq/src/cluster/BackupReplicator.cj:153-156`（`flushOnce` 无条件 `requeue`）、`:238-265`（`requeue` 无 `closed` 判断）、`:297-310`（`close`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」+ §11「契约与实现不符」
- **证据**：静态确定 —— `close()` 先 `closed.compareAndSwap(false, true)`（`:298`），等 `workerRunning` 变假（`:302-305`），再 `flushOnce()`（`:306`）；`flushOnce()` 拿到 `retry` 后无条件 `requeue(retry)`（`:153-156`）；`requeue` 只做 `attempts++` 与「合并回 `pending`」（`:238-260`），**没有 `closed` 分支**（对照 `record()` 在 `:121-124` 有）。工作线程此时已退出 `while (!closed.load())`（`:273`），条目不会再被发送，只剩 `close()` 末尾一条 `closed with N unsent item(s)` 汇总（`:308-309`）
- **描述**：规格原文是「关闭期间失败而需要重新入队的批次 SHALL 被丢弃并记 ERROR，MUST NOT 入队等一个已不存在的工作线程」。当前是「入队 + 轮末计数」：① 缺 topic/queue/位置级 ERROR，运维只能看到总数；② 条目在 `close()` 返回后仍留在 `pending`，与「关闭完成后若仍有未发送条目」的语义混淆（两类来源被合并计数）。数据影响有限（本就是发送失败的副本），但契约不成立
- **建议**：`requeue` 首行加 `if (closed.load()) { 逐条 log.error(含 topic/queue/position); return }`；或 `flushOnce(allowRequeue!: Bool)`，`close()` 传 `false`，把「关闭期丢弃」与「运行期重试」两条路径显式分开；补一条用例：关闭中目标不可达 → 每条有 ERROR，`pendingCount == 0`

### [一般][存量] `fmq/doc/开发计划.md` 与实现大面积漂移：3 个源路径、143/154 个用例名、多个已删成员、配置项与读取方式全部对不上

- **位置**：`fmq/doc/开发计划.md:51`、`:58`、`:60`（源路径）；`:117`（配置项数量）；`:119`（配置读取方式）；`:126`（`rootHelp`）；`:252`、`:281`、`:323`、`:362`（目标成员）；`:10`（前置状态）
- **来源**：存量 —— `git blame -L 51,51` 指向 `76912d0053`（2026-10-18），postfix-audit 的 V40/V60 只改了 4 个用例文件路径与 3 个用例名，其余未动
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」「示例不能用」；`specs/docs/spec.md:206-216`（任务台账真实：每条引用须指向实际存在的文件或用例）
- **证据**：静态确定（`test -f` / `grep -rF` 逐项核对）：
  - 源路径 3 个不存在：`:51` `src/server/MQMatcher.cj`（实际 `src/queue/MQMatcher.cj`）、`:58` `src/meta/MetaSyncer.cj`（实际 `src/cluster/MetaSyncer.cj`）、`:60` `src/queue/LogCleaner.cj`（实际 `src/cluster/LogCleaner.cj`）
  - 表格里 154 个用例名中 143 个在 `fmq/src` + `f_mq/src` 零命中（仅 11 个命中）。例：计划 `rotationHappensAtMaxFileSize`，真实为 `rotationResetsOffsetAndIncrementsSequence`（`fmq/src/queue/QueueLog_test.cj:98`）；计划 `appendReturnsMonotonicPosition`，真实为 `appendThenReadAtReturnsSameBytes`（同文件 `:77`）
  - 目标成员含已删除 / 改名符号：`:281` `byGroup`/`removeByBuffer`（现 `byGroupOf`，`SubscriberRegistry.cj:98`）、`:323` `ownersOf`（下沉测试）、`:362` `self`/`nodeAt`/`indexOf`（现 `selfIndex`，`NodeRegistry.cj:82`）、`:252` `references`（现由注入的 `floorOf` 判定段保留，`LogCleaner.cj:34,78`）、`:126` `rootHelp`（现 `MQUsage.root()`，`MQUsage.cj:23`）
  - `:117` 断言 `helpText()`「含全部 10 个配置项」，实际 12 项（11 个 `mqServer_*` + `mqClient_hosts`，`MQConfig.cj:355-371`；`server-runtime/spec.md:212` 也要求 12）
  - `:119` 写 `Config.getValue<UInt16>/getDuration/getString` + `f_util.computeBytes`；实现是 `Config.getString` + `parseByteSize`，且 `MQConfig.cj:185` 明确说明**不用** `computeBytes`
  - `:10` 仍写 `fmq/src/main.cj（占位）`，而 `main.cj:70` 已有完整子命令分发
- **描述**：这是本模块唯一的 TDD 计划书（`详细设计.md` 的「开发顺序」指的就是它）。按它实现会撞上 8 个已删除 / 改名的成员与 3 个错误目录；按用例名回归找不到用例。`tasks.md:350` 却已结项「台账路径全部收敛」
- **建议**：文件头加「历史计划（2026-10）：成员签名与用例名以源码为准」；或最小改动——按当前源码重写各阶段「目标成员」、修正 3 处目录、把 10 改 12、配置读取改成 `getString` + 严格解析、删掉 `rootHelp`/「占位 main」

### [一般][存量] 台账与规格里的事实性断言不成立（W29 / `generations` / 「路径全部收敛」）

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/tasks.md:323`、`:361`、`:350`；`fmq/doc/spec/fix-fmq-postfix-audit/specs/docs/spec.md:96`
- **来源**：存量
- **判据**：review-checklist §13「文档过期 / 与事实相反」；`specs/docs/spec.md:233-236` Scenario「历史勾选与事实一致」
- **证据**：静态确定
- **描述**：
  - `tasks.md:323` 写「全仓检索无 `W29`，无需处置」、`:361` 写「W29 不存在」。W29 实际存在：`f_mq/doc/spec/fix-fmq-full-audit/verify-report.md:35`；同一变更的 `proposal.md:250` 也把 W29 列为「勾选不实」待处置项。按 `specs/docs/spec.md:215`，W29 的勾选状态必须逐项核实，这里用一句不成立的检索结论绕过了核对
  - `specs/docs/spec.md:96` 写「`count`/`generations` 已删，文档不列」：`count` 确已删，但 `generations` 仍是 `SubscriberRegistry` 的私有字段并参与代次推进（`fmq/src/server/SubscriberRegistry.cj:33,49,53`）
  - `tasks.md:350` 写「台账路径全部收敛」，与发现 #2 冲突（3 个源路径仍不存在）
- **建议**：`:323/:361` 改为「W29 位于 `f_mq/doc/spec/fix-fmq-full-audit/verify-report.md:35`，属历史台账，保留勾选并注明不处置」；`specs/docs/spec.md:96` 改为「私有字段仍在，文档不列」；`tasks.md:350` 收敛为可复核表述

### [一般][存量] 规格主副本位置与仓库布局不符，`openspec/` 验收路径恒真空转

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/specs/docs/spec.md:38`、`:51-54`；`fmq/doc/spec/fix-fmq-postfix-audit/verify-report.md:14`、`:17`；`fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/queue-storage/spec.md:13`
- **来源**：存量
- **判据**：review-checklist §13「链接 / 路径失效」；`specs/docs/spec.md:38`「归档时同步到主规格」
- **证据**：静态确定 —— `openspec/specs/` 只有 5 个与本模块无关的能力（`data-assist-compare`、`data-assist-supertypes`、`jwt-signature`、`orm-result-type-mapping`、`uring-async-io`）；`openspec/changes/` 只有 `add-f-a2a/` 与 `archive/`
- **描述**：规格把「主规格」定在 `openspec/specs/**`（:38），并把「检索『最老段』应为 0」的验收场景也放在该目录（:51-54）。该目录没有 fmq 能力，场景必然 0 命中，验收恒真；`verify-report.md:17` 自称「对照 `openspec/specs/**` 主规格」，实际无对象可对照；`:14` 的 `openspec status --change fix-fmq-postfix-audit` 在本仓库也不可复现（变更实际在 `fmq/doc/spec/`）。followups 的 `queue-storage/spec.md:13` 引 `openspec/changes/fix-fmq-verify-followups/design.md`，同样不存在
- **建议**：把「主规格」指向本仓库实际布局（`fmq/doc/spec/**` 的 capability 目录，或把 fmq 能力登记进 `openspec/specs/fmq-*`），验收串换成能命中的路径；followups 的引用改相对路径

### [轻微][存量] `verify-report.md` 的收尾结论已过期：3 条 WARNING + 4 条 SUGGESTION 实际均已修复

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/verify-report.md:6`、`:32`、`:40-89`
- **来源**：存量
- **判据**：review-checklist §13「文档过期：描述的问题已被修复，报告仍列为未修」
- **证据**：静态确定 —— 逐条对照当前文件：
  - W1（§6.11 缺 5 分钟容差）→ `fmq/doc/详细设计.md:962-963` 已写入
  - W2（`--help`/`case _` 写成不可达）→ `design.md:366-367` 已改「可达 / 保留」
  - W3（丢弃日志限流「毫秒」）→ `specs/fmq/server-runtime/spec.md:288` 已改「同一秒内限流一条」
  - S1（§5.12/§6.10 指向错）→ `详细设计.md:508` 已改 §5.12/§5.14/§6.4
  - S2（`MetaApplyResult` 片段缺 `Conflict`）→ `design.md:120-126` 已列
  - S3（「投入生产」示例仍写 `scanAfter`）→ `design.md:341` 已换 `BackupReplicator.pendingCount`
  - S4（`tasks.md` 375 例）→ `tasks.md:352` 已 376
- **描述**：报告以「剩 3 WARNING + 4 SUGGESTION」收尾，与 `tasks.md` 的 V68 全绿结论口径不一致；按它排查会去改已经正确的文档。另注：其「9 份 delta spec / 59 条需求 / 282 个 Scenario」与两模块合并统计（`f_mq` 2 份 + `fmq` 7 份）完全一致，**不是**统计错误，勿按单一目录复核成 7/45/227
- **建议**：报告末尾加「收尾状态」表，逐条标注修复位置或对应 V6x；文件头注明「第四轮快照，后续见 `tasks.md` V55–V68」

### [轻微][存量] queue-storage 规格对「段缺失恢复」三套措辞并存，且限流阈值相差 100 倍

- **位置**：`.../specs/fmq/queue-storage/spec.md:126-127`（「每秒最多一条」）vs `:164-167`（「不超过约 100 条/秒」）；措辞三处：`:126`「最接近的更大段」、`:250`「最近的后继段」、`:252`「编号更大的最近现存段」
- **来源**：存量
- **判据**：review-checklist §2「同一规则换写法重复表述」+ §13「规格自身矛盾」（该变更 `specs/docs/spec.md:38-47` 自己要求「唯一说法」）
- **证据**：静态确定 —— 实现为一秒窗口限流一条（`fmq/src/queue/WarnLimiter.cj:34` `windowMs = 1000`），不是 100 条/秒
- **描述**：本变更的核心整改对象就是「四种说法收敛为一种」，结果仍是三套措辞；Scenario 的量化值与正文差两个数量级，照 Scenario 写用例会得到与正文冲突的期望
- **建议**：正文只保留一处定义（「跳到编号大于起点段的最近现存段起点 + WARN；同一 `(topic, queue, 位置)` 每秒最多一条」），其余改为引用；Scenario 改为「100 轮不可读 ≤ 1 条日志」

### [轻微][存量] docs 漂移表 §5.10 的目标字段少列 `nextStartNode`

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/specs/docs/spec.md:78`
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `MQMetaSnapshot` 有 5 个字段（`f_mq/src/base/payload/MQMetaSnapshot.cj:29-36`：`topics`/`groups`/`nextStartNode`/`tombstones`/`revision`）；`f_mq/doc/详细设计.md:447-457` 已列全 5 个；漂移表却要求「列 `topics`/`groups`/`tombstones`/`revision`」
- **描述**：同文件 `:102-105` 的 Scenario 要求「字段集合完全一致」。按漂移表执行会把已经正确的文档改错（删掉 `nextStartNode`），修复口径反向
- **建议**：`:78` 的目标值补 `nextStartNode`，与 §5.10、源码三方一致

### [轻微][存量] `tasks.md` 27.4 / 28.9 的标题与括号结论相反

- **位置**：`fmq/doc/spec/fix-fmq-postfix-audit/tasks.md:295-296`（27.4）、`:320-324`（28.9）
- **来源**：存量
- **判据**：review-checklist §13「文档表述与事实相反」+ 可读性 / 可维护性
- **证据**：静态确定 —— 27.4 标题写「删除不可达分支（…`main --help`、`MQManager case _`）」，括号内写「二者语法/实际可达，保留」；28.9 标题写「V9、26.1、W12/W29 取消不实勾选并注明原因」，结论写「均属实，保留勾选」。两处均已 `[x]`。源码中 `--help`、`case _` 均在（`fmq/src/main.cj:70`、`fmq/src/manager/MQManager.cj:98`）
- **描述**：同一行既说删除又说保留，台账被当验收依据时会误判「这两个分支已删」；28.9 的「取消勾选」与「保留勾选」同样互斥
- **建议**：标题改结论式：「27.4 处理 4 处候选分支：删 2 处、保留 2 处（附原因）」；「28.9 复核历史勾选：V9/26.1/V29 属实维持，W29 见 `f_mq` 归档」

### [轻微][存量] 管理端「分配」示例用字母节点号，与真实数字输出不符

- **位置**：`.../specs/fmq/manager-cli/spec.md:24`
- **来源**：存量
- **判据**：review-checklist §13「示例不能用」
- **证据**：静态确定 —— 真实输出为 `分配：${assignments(owners)}`（`fmq/src/manager/MQManagerOutput.cj:47`），节点号是数字；同变更 `specs/docs/spec.md:98` 的样例是 `分配：0→0,1→1`
- **描述**：`0→A,1→B` 会让按它写断言的用例永远失败，或诱导实现改成字母
- **建议**：`:24` 改为 `0→0,1→1`

### [轻微][存量] 同一变更的 proposal/design/tasks/verify-report 在 `f_mq` 与 `fmq` 各存一份完全相同的副本

- **位置**：`f_mq/doc/spec/fix-fmq-postfix-audit/{proposal,design,tasks,verify-report}.md` ↔ `fmq/doc/spec/fix-fmq-postfix-audit/` 同名文件
- **来源**：存量
- **判据**：review-checklist §2「跨文件复制」（文档形态：同一内容两处维护）
- **证据**：静态确定 —— `diff` 四对文件全部无差异
- **描述**：任何修订都要双写；本部分 #3/#5/#8 在两份副本里同时存在，已证明同步成本，勾选状态尤其容易漂移
- **建议**：保留一份为权威副本，另一份改为一行指针（说明「变更跨 f_mq/fmq，权威副本在 X」）

## 优化可行性方案

本部分 15 个文件全为规格 / 任务 / 验证报告，无可测量的分配与调用路径，也没有 bench / profile 基线；按铁律不产出堆内存 / CPU 方案（0 条）。文档侧改进已并入各条「建议」，不重复计为优化方案。

## 待验证假设

> 本部分无性能对象，性能类假设 0 条。唯一的数据缺口是「计划项 → 真实用例」的映射，属一致性核对待办，不是性能结论，也不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 计划中 143 个未命中用例名都能映射到现有用例（仅命名漂移，非功能缺失） | `fmq/doc/开发计划.md` 各用例表 | 计划项 → `@TestCase` 的映射表 | 按表逐个对照同包 `*_test.cj`，标注「已覆盖 / 改名 / 未实现」三态 |

## 文件覆盖

> 与 `files/fmq.part2.txt` 一一对应（15 行，全部读完）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fmq/doc/spec/fix-fmq-postfix-audit/proposal.md` | .md | ✅ | 77 项映射（R1–R5）与 `todo.md` 编号一致；非目标与 README 已知限制对得上；`f_mq` 侧副本字节相同（#10） |
| 2 | `fmq/doc/spec/fix-fmq-postfix-audit/specs/docs/spec.md` | .md | ✅ | 漂移表 §5.10 漏字段（#7）、`generations` 断言不实（#3）、主规格路径空转（#4） |
| 3 | `.../specs/fmq/consume-semantics/spec.md` | .md | ✅ | 死信阈值（`deliverCount > threshold`，`GroupCursor.cj:183-184`）、跳过计数、5 分钟容差与源码一致 |
| 4 | `.../specs/fmq/manager-cli/spec.md` | .md | ✅ | 七子命令、四类失败文案与 `MQManager.cj` 一致；分配示例字母与数字输出不符（#9） |
| 5 | `.../specs/fmq/metadata-cluster/spec.md` | .md | ✅ | 墓碑 `isNewer`、快照字段、按 target 重试均可在源码找到对应；**关闭期丢弃未落地（#1）** |
| 6 | `.../specs/fmq/metrics/spec.md` | .md | ✅ | 14 列表头与 `STATS_HEADER`（`MQManagerOutput.cj:31-33`）、`ConsumeService.stats` 输出逐列一致；`bump` 走 `entryView` 原子自增（`MQMetrics.cj:41-49`） |
| 7 | `.../specs/fmq/queue-storage/spec.md` | .md | ✅ | 段末尾归一化、`effectiveMaxRecord`、零长度判损坏与源码一致；限流阈值与三套措辞矛盾（#6） |
| 8 | `.../specs/fmq/server-runtime/spec.md` | .md | ✅ | 13 步关闭顺序与 `closeSteps` 逐项一致（`MQServer.cj:206-232`）；12 个配置项与 `helpText` 一致；绑定推迟到 `start()`（`:183`） |
| 9 | `fmq/doc/spec/fix-fmq-postfix-audit/tasks.md` | .md | ✅ | 6 个 Red 提交号均存在（`41e54f16`/`149b65a8`/`b009abe7`/`a6607c9f`/`b5852467`/`16438b8e`）；W29 断言不实（#3）、27.4/28.9 互斥（#8） |
| 10 | `fmq/doc/spec/fix-fmq-postfix-audit/verify-report.md` | .md | ✅ | 需求 / 场景计数与两模块合并统计一致（9 份 / 59 条 / 282 个）；收尾结论过期（#5）、主规格对照空转（#4） |
| 11 | `fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/manager-cli/spec.md` | .md | ✅ | 「六个子命令」为该轮口径，后由 postfix-audit MODIFIED 为七个；按 `specs/docs/spec.md:53` 属历史快照，不计矛盾 |
| 12 | `.../fix-fmq-verify-followups/specs/fmq/metadata-cluster/spec.md` | .md | ✅ | 轮转分配与备份语义为该轮口径，被后续 MODIFIED 覆盖；文件内自洽 |
| 13 | `.../fix-fmq-verify-followups/specs/fmq/queue-storage/spec.md` | .md | ✅ | 记录边界格式与该轮设计一致；`openspec/changes/.../design.md` 路径不存在（#4） |
| 14 | `.../fix-fmq-verify-followups/specs/fmq/server-runtime/spec.md` | .md | ✅ | `MQHost.parseHost` 归属与 `BackupStore` 关闭语义与源码一致 |
| 15 | `fmq/doc/开发计划.md` | .md | ✅ | 大面积漂移（#2）：3 源路径、143/154 用例名、8 个已删成员、配置项 10→12、读取方式过期 |

合计：`.cj` 0 个 / `.md` 15 个 / 共 15 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：#1（关闭期丢弃契约未实现）、#2（引用不存在的文件与用例）；设计：#4（规格主副本位置与仓库布局冲突）；可读性：#8（同一勾选项结论互斥）；语言特性、安全性无对象（无 `.cj`，文档无凭据与外部输入） |
| §1 死代码 | 0 | 文档无代码，本维度无对象；机械动作换成「文档引用是否存在」：`开发计划.md` 的 8 个目标成员（`byGroup`/`removeByBuffer`/`ownersOf`/`self`/`nodeAt`/`indexOf`/`references`/`rootHelp`）已不存在、154 个用例名中 143 个零命中 —— 结论并入 #2，不另立死代码条目 |
| §2 重复逻辑 | 2 | #6（「段缺失恢复」三套措辞，语义同、量化值相反）；#10（4 份变更文档在两模块各一份，`diff` 无差异）。delta 链的 MODIFIED 覆盖属正常演进，不计 |
| §3 空实现 | 0 | 15 个文件 grep `TODO|FIXME|待补` 仅命中 `proposal.md:124`「待补偿集」与 `开发计划.md:10`「占位 main」（描述性文字，非待办占位）；规格中「SHALL 有行为」的 9 个出口（死信、跳过计数、`stats` 严格模式、`queues.sync`、备份按 target 重试、`BackupStore` 留痕、清理汇总、`bump` 原子性、`TestDirs` 可见性）8 个有实现，第 9 个（关闭期丢弃）是实现走样而非空，记 #1 |
| §4 栈溢出 | 0 | 文档无递归承诺；规格涉及的遍历（`cleanOnce` 逐段、`stats` 单趟扫描、`startSegmentAtOrAfter` 线性找段）均迭代，无深层递归接口 |
| §5 OOM | 0 | 规格声明的上界都有实现：`min(64MiB, maxFileSize-4)`（`QueueLog.cj:55-71`）、备份队列 `capacity` 有界、读端先校验长度再分配（`QueueLog.cj:396-410`）；本部分不新增无界容器 |
| §6.1 热点瓶颈 | 0 | 无 bench / `cjprof` 数据，本部分也不含可测量代码，不给热点结论 |
| §6.2 大粒度锁 | 0 | 规格未承诺锁结构；抽查 `CursorCatalog.positionOf` 已把磁盘 IO 放锁外（`CursorCatalog.cj:62-78`），`MQMetrics` 无全局锁；缺持有时长数据不报 |
| §6.3 并发串行 | 0 | 规格承诺「发布不阻塞、独立工作线程批量发送」，实现一致（`BackupReplicator.cj:267-286`），未见 `spawn` 后立即 `get` |
| §6.4 低效算法 | 0 | `stats` 为单趟扫描（`ConsumeService.cj:178-261`）；线性找段在段数有限时不构成证据 |
| §7 降堆内存方案 | 0 | 无「持有什么 / 多大 / 活多久」的量化数据；`close()` 残留 `pending` 是缺陷（#1）不是优化项 |
| §8 降 CPU 方案 | 0 | 无改前基线，按铁律不写 |
| §9 local mode 可行性 | 0 | 本部分无函数体，无法做逃逸检查，也无峰值内存对照 |
| §11 现有代码的 BUG（存量） | 1 | #1（`requeue` 未判 `closed`，与规格 SHALL 相反）；其余读到的边界（`resolveStart(strict)`、`ackedByAll` 边界、`stats` 无组行、`readAt` 越界校验、`wall-clock` 限流）核对无缺陷 |
| §12 并发安全与锁粒度 | 1 | 唯一并发面是 `close()` 与工作线程的退出时序（#1），与 §11 同源不重复计数；规格承诺的 `MQMetrics` 删除/自增并发、`BackupStore` 关闭并发在源码侧成立 |
| §13 文档一致性（.md） | 9 | #2–#10；15 个 `.md` 全量比对实现（#1 属规格与实现的行为漂移，归 §11） |
| §14 功能完备性与 README 覆盖 | 2 | #2（「每条勾选项 SHALL 能指向实际用例」不成立）、#4（变更未归档到主规格，验收恒真）；README 覆盖属 part1，不重复计 |
| 文件覆盖（§13 等） | 15/15 | 无缺项；`design.md`、`README.md`、`doc/详细设计.md` 仅作交叉取证读片段，未计入覆盖与统计 |

## 模块统计

> 仅统计本部分（第 2/7 部分，15 个 `.md`）。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 10 条（本部分全部问题均为存量），是否纳入修复待用户决定。

## 总评

本部分不含 `.cj`，但它是 fmq 的契约层：postfix-audit 的 delta 把墓碑判定、段末尾归一化、记录/段上限联动、死信阈值、`stats` 严格模式、关闭 13 步、管理端错误四分类都写成了可验收的 SHALL + Scenario。逐条对照源码后，**规格主体可信**：抽查的 20 余个断言（`effectiveMaxRecord`、零长度判损坏、损坏/段缺失分流、`deliverCount = N+1`、14 列 TSV、`ackedByAll` 边界、13 步关闭顺序、12 个配置项、6 条命令错误分支、`MQMetrics` 原子自增、`TestDirs` 可见性）都能在 `fmq/src` 找到对应实现，未发现「承诺的功能不存在」这类严重漂移。verify-report 的 9 份 / 59 条 / 282 个 Scenario 也与两模块合并统计吻合，不是统计错误。

风险集中在三处，都不在实现主体而在「文档没跟上代码」：

1. **有一条 SHALL 没落地**——备份关闭期失败的批次仍 `requeue` 进 `pending`（#1），与「丢弃并记 ERROR」相反。这是本部分唯一涉及运行期行为的项，影响面限于发送失败的副本与日志粒度，建议与集群/备份部分的修复合并（同一落点 `BackupReplicator.requeue`）。
2. **台账不真实**——`开发计划.md` 的 3 个源路径、143 个用例名、8 个已删成员、配置项数量与读取方式全部停留在设计期（#2），而 `tasks.md`、`docs/spec.md` 又有三条不成立的自检断言（#3）。按计划实现会找不到文件，按台账会以为已核对过。
3. **验收口径空转**——主规格定在 `openspec/specs/**`，该目录没有 fmq 能力，「检索『最老段』为 0」必然通过；verify-report 的「对照主规格」没有对象（#4），且它以「3 WARNING + 4 SUGGESTION 未闭环」收尾，实际 7 条都已修（#5）。

建议排期：#1 与集群/备份代码修复同批；#2、#3、#8 一次通读 `开发计划.md` + `tasks.md` 改完（同一 PR 内可完成）；#4 需先定「fmq 主规格放哪里」；#5、#6、#7、#9、#10 随下一轮文档收敛处理。

**范围外提示**（不计入统计）：`fmq/src/config/MQConfig.cj:312` 用字面量 `64 * 1024 * 1024 + 4` 判断段上限，与 `fmq/src/queue/QueueLog.cj:48` 的 `MAX_RECORD_SIZE` 是同一常量两处定义（§2 字面量复制），改一处漏一处会让「启动期 WARN 阈值」与「写入拒绝阈值」分叉。
