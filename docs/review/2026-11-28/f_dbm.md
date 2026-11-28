# f_dbm 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_dbm`（3 个 `.cj`，其中 1 个测试文件；7 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；无 diff 可依，全部问题按「存量」记）
- **审查重点**：设计文档与实现一致性、空实现、死代码、并发安全、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [一般][存量] 扩展契约的硬约束只落在代码注释，README 与规格未承载（并发模型 / 确定性 / key 类型 / ID 唯一性 / 能力回退边界）

- **位置**：`f_dbm/README.md:12-30`、`f_dbm/src/PartitionAlgorithm.cj:18-30`、`f_dbm/src/IdGenerator.cj:31-49`
- **来源**：存量（工作区快照，无基线可比）
- **判据**：review-checklist §14.2（公开 API 的关键约束/限制段落缺失）、§13（关键段落缺失）、§12.1（默认按多线程调用审）
- **证据**：静态确定（共享路径与文档缺失均可只读确认）；下游是否真的写出有状态实现为待确认
  - 共享路径：`fdbm/src/server/CustomLoader.cj:92-114` 每个名字只保存一个实例；`fdbm/src/server/FdbmServer.cj:73`、`:99` 把该实例注入 `PartitionRouter` 与 `ServerContext`；`:138-140` 把 `custom.idGenerators` 交给 `ExecutorDispatcher`；`f_net/src/server/server.cj:139` 每条连接一个 `spawn`，`:169` `executors.call{...}` 进 200 线程池执行 handler；调用点集中在 `fdbm/src/route/router.cj:235-239` 与 `fdbm/src/execute/executors.cj:935-960`。即**同一扩展实例会被任意请求线程并发调用**，而接口与 README 均未声明这一前提。
  - 文档缺失：`README.md` 全文检索不到「并发 / 线程安全 / 无状态 / 确定」；出现的「唯一」只是**扩展名唯一**（`:31-33`）与「唯一分配库」（`:27`），**不是 ID 唯一性**。`PartitionAlgorithm.cj:21-23` 只在 javadoc 写了确定性（原文用「稳定」），`key ∈ {Int64, String}` 也只在 javadoc；`IdGenerator.cj:31-36` 只写了「至少支持一种」，**唯一性与并发安全两处都无承诺**。`fdbm/doc/详细设计.md:1003` 明确「fdbm 不调用 `Initializer.start()`」，README 的扩展编写段落未提。
  - 能力回退边界未写：`README.md:29-30` 称「只实现一种能力是合法用法 …… 按能力回退」，但回退出的字符串能否被分片算法消费并无保证——`fdbm/src/route/algorithms.cj:64-69` 经 `keyAsInt64`（`:120-138`）对非数字字符串直接抛 `ROUTE_FAILED`，`step` 表上配只生成 `'id-1'` 这类字符串的生成器仍会失败（只是错码从 `INTERNAL` 变成 `ROUTE_FAILED`）。
- **描述**：模块唯一的产出就是「契约」，但契约里最容易被第三方实现踩的四件事——单实例被多线程共享、`partition` 必须确定性且只接受 Int64/String、生成的 ID 必须全局唯一、`Initializer.start()` 不会被调用——都没有写进 README（部分连 javadoc 都没有）。按 README 实现一个带本地计数器的 ID 生成器或带缓存的算法，编译与启动都能通过，故障要到并发压测才暴露：数据竞争、重复 ID 撞主键、或按时间/随机分片导致同一 key 落到不同物理库（数据写错分片）。
- **建议**：在 `README.md`「接口」节与两个接口的 javadoc 各补一条硬约束：①扩展实例全局唯一、会被并发调用，实现必须无状态或自行同步（可引 `UUID` 生成器自带 `Mutex` 的先例，`doc/spec/harden-fdbm-stack-defects/design.md:213-217`）；②`partition` 必须确定性、只接受 `Int64`/`String`，其余类型 fdbm 不会传入也不得自行定义；③`nextStringId`/`nextIntId` 必须全局唯一，不得依赖可复用/进程内易失状态；④`Initializer.start()` 不会被调用；⑤能力回退仅保证「不让请求直接 `INTERNAL`」，目标算法若需要整数键，字符串 ID 仍可能 `ROUTE_FAILED`。同步在 `doc/spec/harden-fdbm-stack-defects/specs/f-dbm/spec.md` 增一条 MUST，便于后续回归。

### [轻微][存量] `PartitionAlgorithm.name` 的注释引用了不存在的配置项 `fdbm_partition_algorithm`

- **位置**：`f_dbm/src/PartitionAlgorithm.cj:26`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（语义与注释不符）、§13（配置名与实现不符）
- **证据**：静态确定 —— 全仓检索 `fdbm_partition_algorithm` 只命中这一行注释；真实键是 `fdbm_partition__<table>`，解析在 `fdbm/src/config/FdbmConfig.cj:158-166`（值形如 `<logical>,<algorithm>,<column>`），`f_dbm/README.md:13` 写的也是 `fdbm_partition__<table>`。
- **描述**：扩展作者按注释去配置里找 `fdbm_partition_algorithm` 会找不到键，只能反查 README 或 fdbm 源码；同一个字段两处口径不一致。
- **建议**：改为「算法名，对应 `fdbm_partition__<table>` 配置值的第二个字段」。

### [轻微][存量] 测试替身 `StableAlgorithm` 不校验入参：空数组除零、未知 key 类型静默归档

- **位置**：`f_dbm/src/IdGenerator_test.cj:70-81`（`case _ => 'key'` 在 `:75`，`sum % databases.size` 在 `:80`）
- **来源**：存量（工作区快照）
- **判据**：review-checklist §11（空集合未处理 / 边界缺失）
- **证据**：静态确定 —— `databases` 为空时 `% 0` 直接抛算术异常；`match (key)` 的 `case _` 把任意类型的 key 折叠成常量 `'key'`，不报错。
- **描述**：该文件是本模块唯一的测试入口，替身的行为会被当成「契约示范」参考。除零只是崩溃点，更实际的问题是 `case _` 让「实现悄悄接受契约外类型」变成默认写法；`PartitionAlgorithm` 的泛型 `K` 无约束，实现方只能靠这种兜底，容易把脏数据静默路由到固定分片。
- **建议**：构造时断言 `databases` 非空（`ensureDatabases` 风格的显式抛错）；`case _` 改为抛错或用例内 `fail`，让替身只演示契约内输入。

### [轻微][存量] 「跨实例一致」用例是同义反复，不能回归确定性

- **位置**：`f_dbm/src/IdGenerator_test.cj:147-156`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §14.1（承诺的回归覆盖是否有效）
- **证据**：静态确定 —— `StableAlgorithm` 无状态，`partition` 先把 Int64 `toString()` 再逐字节求和（`:71-79`），因此 `:153`（两个实例同结果）与 `:155`（`Int64(42)` 等于 `'42'`）按构造成立，任何实现都能过；`doc/spec/.../spec.md:46-50` 的「跨实例一致」场景实际只被这条永真断言覆盖。
- **描述**：用例测的是替身自己的实现细节，而不是契约；换成「有随机盐」的算法也能通过，回归价值为零。
- **建议**：断言具体期望桶（如 `'abc'` → `dbX`）覆盖四个 key，并补一条「不同 key 至少命中两个不同桶」，让算法退化能被发现。

### [轻微][存量] 两份 delta spec 逐字节重复，存在漂移风险

- **位置**：`f_dbm/doc/spec/harden-fdbm-stack-defects/spec.md:1-64` 与 `f_dbm/doc/spec/harden-fdbm-stack-defects/specs/f-dbm/spec.md:1-64`
- **来源**：存量（工作区快照）
- **判据**：review-checklist §2（重复内容）、§13（规格与实现漂移风险）
- **证据**：静态确定 —— `diff -q` 两文件报告完全相同（各 64 行，4 条 MUST 与 4 个 Scenario 一字不差）。
- **描述**：同一个变更的 delta spec 存了两份，后续只改一份就会出现两个互相矛盾的 MUST；读者也无法判断哪份是权威。
- **建议**：保留 `specs/f-dbm/spec.md`（OpenSpec delta 的规范位置），删除根 `spec.md` 或在根文件留一行指针说明「内容见 specs/f-dbm/spec.md」。

## 优化可行性方案

本模块无运行时生产逻辑（仅两个接口 + 1 个异常类型，唯一可执行代码是两个默认抛出方法），不持有堆对象、无循环、无锁，本轮的堆内存与 CPU 方案均为 0 条。唯一可提升 CPU 的点在能力探测方式（抛异常当能力查询），属 fdbm 侧调用策略，且无测量数据，见「待验证假设」#1。

## 待验证假设

> 无性能测试数据，下列均不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 能力探测用异常实现：只实现 `nextStringId` 的生成器配 `step` 表时，每次缺分库键的 INSERT 都要构造并捕获一次 `IdGeneratorException`（含 message 插值），可能占该路径可观比例 | `f_dbm/src/IdGenerator.cj:42-49`（抛出点）；`fdbm/src/execute/executors.cj:935-960`（调用策略） | 单次异常构造+捕获耗时、在 INSERT 端到端耗时中的占比 | `cjprof record` 跑 1k / 10k 条「缺分库列值 + 字符串生成器」的 INSERT，对比同规模下整数生成器的耗时分布；如占比 <5% 则不立项 |
| 2 | 上述异常路径的栈深度随调用链（handler → dispatcher → executor）增长，异常构造成本可能随请求嵌套变化 | 同上 | 异常构造的 CPU 时间与栈帧数关系 | 分段计时：在 `tryStringId` 前后打点，统计 P50/P95 单次开销 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_dbm/README.md` | .md | ✅ | 接口与加载规则与实现一致（已对照 `CustomLoader.cj`、`FdbmConfig.cj`、`handler.cj`）；约束缺失见「发现」#1 |
| 2 | `f_dbm/README_en.md` | .md | ✅ | 与中文版同步（章节、示例、5 条加载规则一一对应），无中英缺失 |
| 3 | `f_dbm/doc/spec/harden-fdbm-stack-defects/design.md` | .md | ✅ | 变更设计；本模块只涉及 D09/D11 文档项与附录 A #9/#17/#45，与实现自洽；f_dbm 接口签名确未改（`proposal.md:81`） |
| 4 | `f_dbm/doc/spec/harden-fdbm-stack-defects/proposal.md` | .md | ✅ | 「f_dbm 仅文档/测试」与工作区一致；不改接口的承诺成立 |
| 5 | `f_dbm/doc/spec/harden-fdbm-stack-defects/spec.md` | .md | ✅ | 4 条 MUST 与实现/用例对应；与 #6 逐字节重复，见「发现」#5 |
| 6 | `f_dbm/doc/spec/harden-fdbm-stack-defects/specs/f-dbm/spec.md` | .md | ✅ | 同 #5（OpenSpec delta 规范位置） |
| 7 | `f_dbm/doc/spec/harden-fdbm-stack-defects/tasks.md` | .md | ✅ | 任务全部 `[x]`；「f_dbm 5/5」与 `IdGenerator_test.cj` 的 5 个 `@TestCase` 吻合；T01 与 4.3 的文档项已落地 |
| 8 | `f_dbm/src/IdGenerator.cj` | .cj | ✅ | 异常类型 + 接口 + 两个抛异常的默认实现，与 spec/README 一致；契约约束缺失见「发现」#1 |
| 9 | `f_dbm/src/IdGenerator_test.cj` | .cj | ✅ | 5 个用例（4 个 `IdGenerator` + 1 个 `PartitionAlgorithm`）；见「发现」#3、#4 |
| 10 | `f_dbm/src/PartitionAlgorithm.cj` | .cj | ✅ | 单方法接口 + 确定性 javadoc；注释键名错误见「发现」#2 |

合计：`.cj` 3 个 / `.md` 7 个 / 共 10 个，全部读完（`files/f_dbm.txt` 10 行逐行对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 模块无分支逻辑、无外部输入、无敏感数据、无 SQL/注入面；3 个 `.cj` 的可见性、`Option`/异常用法与仓颉惯用法一致。设计层面的问题不在此行重复计数，归入下方 §14 行（#1） |
| §1 死代码 | 0 | 逐个符号搜引用：`PartitionAlgorithm` / `IdGenerator` / `IdGeneratorException` 均为对外可达 `public`（不判，`fdbm` 与扩展仍在使用）；`StringOnlyGenerator` / `IntOnlyGenerator` / `NoCapabilityGenerator` / `StableAlgorithm` / `messageOf` 均在 `IdGenerator_test.cj` 内被用例引用；`@Test` 类由框架调用；两处 `import` 均使用；无 `return`/`throw`/`break`/`continue` 后同层语句、无 `if (false)` |
| §2 重复逻辑 | 1 | 已两两比对 4 个实现体（两个默认方法、`StableAlgorithm.partition`、`messageOf`）：默认方法文案差异是契约要求、替身与用例无同语义重复；唯一重复是两份逐字节相同的 delta spec（#5） |
| §3 空实现 | 0 | 两个默认方法显式抛 `IdGeneratorException` 并在 javadoc/README 说明「未支持」语义，属有意的 Null-Object 式契约，不是静默空实现；无 `TODO`/`FIXME`/`catch {}`；`Initializer.start()` 的空体在 `f_app`，非本模块 |
| §4 栈溢出 | 0 | 模块内无递归、无自引用结构、无深度遍历；异常构造的栈深度由调用方决定，见待验证假设 #1 |
| §5 OOM | 0 | 无容器、无 `Array(n)` 预分配、无全量物化、无长期持有；异常消息插值只产生单个短字符串 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，热点不成立；已列待验证假设 #1、#2 |
| §6.2 大粒度锁 | 0 | 模块内无锁、无临界区（`Mutex` 只在 fdbm 的内置生成器里，属范围外） |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future`、无批处理；并发问题属契约声明缺失，记在 §12 行 |
| §6.4 低效算法 | 0 | 无循环与查找（测试替身只有一趟 key 字符遍历，n 为 key 长度，无规模意义） |
| §7 降堆内存方案 | 0 | 模块不持有堆对象，无中间副本/缓存/池可优化；提交 0 条方案 |
| §8 降 CPU 方案 | 0 | 无生产循环/无分配热点；唯一线索（异常当能力探测）缺基线，已降为待验证假设 |
| §9 local mode 可行性 | 0 | 接口与默认方法内无函数级临时大对象，无逃逸检查收益可证；改造收益无法用峰值内存证明，不立项 |
| §11 现有代码的 BUG（存量） | 2 | 已核对全部 4 个函数体（2 个默认方法、替身 `partition`、`messageOf`）与 1 个异常构造：注释键名错误（#2）、替身空数组除零与 `case _` 静默归档（#3）；两个默认方法的 message 与 spec 要求一致，无缺陷 |
| §12 并发安全与锁粒度 | 1 | 模块本身无共享可变状态；但契约未声明「单实例 + 多线程调用」，已给出共享路径与缺失的同步要求（#1）。锁粒度层面无可判内容（模块内无锁） |
| §14 功能完备性与 README 覆盖 | 2 | 以 `src/` 公开声明为基准逐项对照：`PartitionAlgorithm.name/partition`、`IdGenerator.name/nextStringId/nextIntId`、`IdGeneratorException` 均在 README 出现，符号层面无遗漏，`README_en` 与中文版同步；缺的是约束段落（#1，同一条也计于 §12 行，模块统计不重复计数）。另：确定性回归无效（#4，判据同属本节） |
| 文件覆盖（§13 等） | 10/10 | 无缺读；`tasks.md:213` 的「f_dbm 5/5」与实际 5 个 `@TestCase` 一致；README 引用的 `fdbm/doc/详细设计.md` §10.5 存在（`:951`） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 5 条（1 一般 + 4 轻微），是否纳入修复待用户决定；本模块无「本次改动」来源的条目（快照基线无 diff）。

**范围外提示（不占本轮统计）**：
1. `fdbm/doc/详细设计.md:1001` 的内置算法清单写作 `step/hash/crc16/crc32/crc64/murmur`，漏了 `std` 与 `substr`；实现 `FdbmConfig.cj:35` 与 `f_dbm/README.md:25` 都是 8 个，属 fdbm 文档过期。
2. `fdbm/src/execute/executors.cj:937` 用 `algorithm.name == 'snowflake' || 'sequence'` 判「期望整型」，对内置算法恒不成立，只有自定义算法恰好取这两个名字时才命中，语义混杂（不是死代码，因自定义名未被禁止）。

## 总评

`f_dbm` 是纯契约模块：2 个接口、1 个异常类型、1 个测试文件，没有业务逻辑与运行时状态，因此不存在死代码、空实现、栈溢出、OOM、锁竞争类缺陷；现有实现与 `doc/spec` 的 MUST、`tasks.md` 的 5/5 断言、README 的加载规则（全部 load 后只 initialize 一次、自定义之间及与内置重名拒绝、失败即 `CONFIG`）逐条对得上，代码质量良好。

主要风险不在代码，而在**契约文本**：扩展实例被 fdbm 以单例形式持有并放在 200 线程池里执行（`f_net/src/server/server.cj:139`、`:169`），但 README/javadoc 没有要求实现无状态或线程安全，也没写 `partition` 的确定性、key 只可能是 `Int64`/`String`、ID 必须唯一、`Initializer.start()` 不会被调用。第三方按现有文档写出有状态实现或依赖时间的分片算法，故障会表现为跨节点路由不一致或主键冲突，定位成本很高——这属于阻塞项，建议在下一轮文档修订中一次性补齐（可在 spec 增一条 MUST 以固化回归）。

其余 4 条轻微项（注释键名错误、测试替身缺校验、确定性用例同义反复、delta spec 重复）可排期处理，均不影响运行期行为。性能方面本模块无生产热点，异常当能力探测的开销仅作为待验证假设，等有 `cjprof` 数据再决定是否值得改造。
