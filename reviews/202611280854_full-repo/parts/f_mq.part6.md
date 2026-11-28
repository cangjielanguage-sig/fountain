# f_mq 模块审查报告（模块第 6/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mq`（本部分 11 个文件：11 个 `.cj` + 0 个 `.md`；全模块共 61 个 `.cj` + 36 个 `.md`，本部分为 `src/client/MQSubscription.cj`、`src/client/**/*_test.cj`、`src/exception/**`、`src/f_mq.cj`、`src/test/Facade_test.cj`）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线；`git status --porcelain f_mq` 为空，本部分文件 `git blame` 指向 2026-10-18 `6303d88db0`、2026-10-21 `196824caa5` / `bc7b8eeac0` / `d587122f6d` 等 runningW 的提交，故一律记为「存量」）
- **审查重点**：投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑、存量 BUG
- **报告版本**：v1

## 发现

### [严重][存量] `deliveries` 认领永不过期：未确认的重复投递被静默丢弃，at-least-once 退化为「丢弃 + 进死信」

- **位置**：`f_mq/src/client/MQSubscription.cj:37`（`deliveries` 认领表无 TTL、无上限）、`f_mq/src/client/MQSubscription.cj:48-50`（键构造）；配合 `f_mq/src/client/MQClient.cj:246-253`（`addIfAbsent` 命中即 `continue`）、`f_mq/src/client/MQClient.cj:326`（唯一删除点）
- **来源**：存量（快照模式无基线；`git blame` 6303d88db0，2026-10-18）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「异步语义（超时但任务继续跑 / 失败被静默吞掉）」、§5「无界容器」
- **证据**：静态确定 —— ①`deliveries` 的删除只有 `ack` 成功一条路径（`MQClient.cj:326`），`MQClient.cj:250` 命中已存在键时只做 `continue`，没有任何时间、次数或容量约束；②`ConcurrentHashMap.addIfAbsent` 在键已存在时不赋值并返回旧值（std `collection_concurrent_class.md:1132`「如果赋值之前 key 存在，则返回当前 key 对应的值 Some(V)，且不执行赋值操作」）；③服务端确实会重投同一位置：`fmq/src/queue/GroupCursor.cj:143` 的 `ready = !entry.delivered || current - entry.lastDeliverTime >= ackTimeout`，重投返回的仍是同一 `(seq, offset)`
- **描述**：正常路径是 `consume` 认领 → 业务处理 → `ack` 删除认领。业务处理失败（抛异常、超时放弃、主动跳过）而不 `ack` 时：服务端在 `ackTimeout` 后重投同一位置，客户端 `addIfAbsent` 再次命中 → `continue` 静默丢弃，认领永不释放。后果有三层：①`README.md:122` 承诺的「投递语义为 at-least-once：未确认消息在超时或服务重启后会重复投递」对**同一客户端实例**不成立，重投一次都到不了业务；②服务端仍按 `deliverCount` 反复重投，每次都被客户端吞掉，累计到 `deadMsgThreshold` 后由 `fmq/src/queue/GroupCursor.cj:184` 写入死信队列——本应重试成功的消息被静默推进死信，且客户端全程没有一行日志；③每条进死信的记录都永久留在 `deliveries` 里（`ack` 永远不会发生），随后端运行时间无界增长，单条约 10² B（`"q:s:o"` 字符串 + 哈希表槽），百万级死信即百 MB 量级
- **建议**：①认领带生命周期——条目改为 `(node, claimedAt)`，超过服务端 `ackTimeout`（作为客户端配置暴露）即失效并允许重新认领，或「已返回给调用方」后转为可重投状态；②加容量上限与淘汰（超过上限时按最早认领淘汰并 `warn`），避免死信记录常驻；③命中已认领位置时至少 `debug/warn` 一次计数，不要全静默；④现有用例 `MQClient_test.cj:530-566`（`sameDeliveryPositionIsClaimedOnce`）把「永久挡住」写成期望行为，需与新语义一起修改，并补一条「不 ack 的重投必须重新交付」的用例

### [轻微][存量] `MQSubscription.subscribedId` 字段从未被读取

- **位置**：`f_mq/src/client/MQSubscription.cj:32`（声明）、`41`（唯一赋值）
- **来源**：存量（`git blame` 6303d88db0）
- **判据**：review-checklist §1「无调用者 / 读了不用」——所属顶层声明是 `internal class`，对外不可达，成员在全仓无读取即死代码
- **证据**：静态确定 —— `grep -rn "\.subscribedId" f_mq/src` 只命中 `base/payload/*` 自身字段与测试、以及本文件 `41` 行的赋值；`MQClient.cj` 打印订阅 id 时用的是方法参数 `subscribedId`（`260/285/328` 等行），不是 `sub.subscribedId`
- **描述**：每个订阅多持有一个 `String` 引用且永不使用；字段存在会让人误以为 `MQSubscription` 能自描述身份，排障时容易踩空
- **建议**：删除该字段与构造参数；若确实要保留用于日志，则把 `MQClient` 的日志改用 `sub.subscribedId`，让字段真正被使用

### [轻微][存量] 测试辅助的清理入口全部未接线：日志捕获器的静态缓冲跨用例只增不减

- **位置**：`f_mq/src/client/test/LogCapture_test.cj:31-33`（`static let lines` / `pending`）、`50-54`（`take()` 只做快照，不清空）、`56-61`（`CapturingStream.clear()`）、`90-92`（`CapturingAppender.clear()` 无调用者）；`f_mq/src/client/test/MQStubServer_test.cj:110-114`（`MQStubServer.clear()` 无调用者）
- **来源**：存量（`git blame` 196824caa5 / 6303d88db0，2026-10-21 / 2026-10-18；快照模式无基线）
- **判据**：review-checklist §1「非 public 符号无调用者」、§11（测试隔离缺失导致断言可能误命中）
- **证据**：静态确定 —— `grep -rn "CapturingAppender\.\|CapturingStream\." f_mq/src` 只有 `install()` / `waitFor()` / `take()` 的调用，`clear()` 零调用；`MQStubServer.clear()` 同样零调用（`isClosed()` 是 `Resource` 接口实现，不计）
- **描述**：`lines` 是进程级静态容器，`take()` 返回副本而不消费，`clear()` 又没人调用，于是整个测试进程的日志行持续累积。`clientFailsWithPerNodeLogs`（`MQClient_test.cj:981`）与 `allNodesUnreachableThrowsConnectionException`（`213`）、`deadNodeThrows` 共用 `127.0.0.1:1`，`waitFor(["node 0", "127.0.0.1:1"])` 可能匹配到前一个用例残留的行，形成假通过
- **建议**：在 `@BeforeAll` / 每个日志断言用例开头调用 `CapturingAppender.clear()`；更稳的做法是 `waitFor` 记住起始下标，只在「本轮新增行」里匹配；`MQStubServer.clear()` 若无用途直接删除

### [轻微][存量] `MQClient_test` 硬编码 tags 边界 65 / 129，复制 `MQTags.MAX_COUNT` / `MAX_LENGTH`

- **位置**：`f_mq/src/client/test/MQClient_test.cj:96`（`Array<String>(65, repeat: "t")`）、`101`（`longText(129)`）
- **来源**：存量（`git blame` d587122f6d，2026-10-21）
- **判据**：review-checklist §2「字面量复制：同一组边界值散落多处」
- **证据**：静态确定 —— 边界定义在 `f_mq/src/base/MQTags.cj:24-25`（`MAX_COUNT = 64`、`MAX_LENGTH = 128`），`README.md:112` 也按常量名描述；测试另写一份 +1 的数值
- **描述**：常量上调时（例如 `MAX_COUNT` 改 128），`65` 变成合法值，用例从「预期 6 次本地失败」变成 5 次，失败原因指向测试而不是实现，排查成本高
- **建议**：改为 `MQTags.MAX_COUNT + 1` / `MQTags.MAX_LENGTH + 1`

### [轻微][存量] 用例用墙钟做时序断言，未使用已注入的假时钟

- **位置**：`f_mq/src/client/test/MQNodePool_test.cj:124`（`@Assert(elapsed < 300)`）、`169-184`（`failedBuildBacksOff` 依赖 200ms 退避窗口，三次调用间不得超时）
- **来源**：存量（`git blame` bc7b8eeac0，2026-10-21）
- **判据**：review-checklist §11「非确定断言」、§10 可维护性
- **证据**：需实测 —— 需在负载机上重复运行确认抖动幅度；代码层面可确定 `MQNodePool` 已支持 `nowMs` 注入（`f_mq/src/client/MQNodePool.cj:51-53`），但两个用例都没传
- **描述**：`elapsed < 300`（建连耗时含 TCP 握手）与「200ms 内不重撞」都随机器负载漂移，CI 并行跑用例时容易偶发失败，且失败信息无法区分「实现退化」与「机器慢」
- **建议**：`slowNodeDoesNotBlockOtherNodes` 改为断言「取节点 1 的调用未等待节点 0 的 build 完成」（用 `AtomicBool` 时序标记）而不是绝对耗时；`failedBuildBacksOff` 传入固定 `nowMs` 序列，把退避窗口变成确定逻辑

### [轻微][存量] 桩服务端吞掉绑定/启动异常，真实原因被覆盖成「cannot bind a free port」

- **位置**：`f_mq/src/client/test/MQStubServer_test.cj:46-56`（`catch (_: Exception) { attempt++ }` 丢弃原因）、`66-73`（`spawn { server.start {...} }` 的异常无人接收）、`77-89`（探针失败后统一抛 `did not start`）
- **来源**：存量（`git blame` 6303d88db0）
- **判据**：review-checklist §3「`catch {}` 静默吞掉异常」、§11「错误处理缺失或静默」
- **证据**：静态确定 —— 循环里捕获所有异常只做计数，`getOrThrow` 的兜底异常不带任何原始 cause；`spawn` 的 `Future` 被丢弃，`server.start` 抛错时用例只会看到 2 秒超时后的通用文案
- **描述**：端口被占以外的失败（`Server` 构造参数错误、监听权限不足）都会被重试 100 次并报成端口问题，测试排障时会往错误方向查；这是测试桩，影响面限于本模块用例
- **建议**：保存最后一次异常并作为 `MQStubException` 的 `causedBy`；只对「端口占用」类错误重试，其余立即上抛；`spawn` 的返回值保留并在 `start()` 里检查一次

## 优化可行性方案

> 不是缺陷，是"还能更好"。本部分只有一条候选，且无任何测量数据。

### [CPU] 位置键改为值类型，去掉每消息的字符串拼接与字符串哈希

- **现状**：`MQSubscription.keyOf`（`MQSubscription.cj:48-50`）用 `"${queueIndex}:${segmentedIndex}:${segmentedOffset}"` 生成键；非 `autoAck` 订阅每投递一条消息在 `consume` 拼一次（`MQClient.cj:247`）、`ack` 再拼一次（`MQClient.cj:314`），即每条消息 1–2 次 String 分配 + 字符数组 + 逐字符哈希，键对象在 `ack` 前一直存活
- **方案**：定义 `struct LogKey <: Hashable & Equatable { let queueIndex: Int64; let segmentedIndex: Int64; let segmentedOffset: Int64 }`，`deliveries` 改为 `ConcurrentHashMap<LogKey, Int64>`，`ack` 复用调用方已有的三个 `Int64` 直接构造（栈上值类型）
- **预期**：每条消息省 1–2 次 String 分配与字符串哈希；`deliveries` 条目由「String 头 + 字符数组 + 表槽」变为「24B 值 + 表槽」。具体降幅未测
- **代价**：`deliveries` 的泛型参数与 `keyOf` 签名变更（内部类型，无兼容负担）；日志里拼可读位置时仍需 `toString`
- **验证**：`cjpm bench -O2`，同机同 SDK，10 万条 consume+ack 各跑 5 轮取中位数；`cjprof record` 看 `String` 构造与 `hashCode` 的自耗时占比是否从热点表消失
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 位置键的字符串拼接 + 哈希在 consume/ack 热路径占有可观自耗时 | `f_mq/src/client/MQSubscription.cj:48`、`f_mq/src/client/MQClient.cj:247`、`314` | 自耗时占比、每条分配字节数 | `cjprof record` 跑 10 万条 consume+ack，看 `String`/`hashCode` 占比与分配量 |
| 2 | `nextStart` 的 `AtomicInt64.fetchAdd` 在 4+ 并发消费者下形成缓存行争用 | `f_mq/src/client/MQSubscription.cj:53-55` | 线程状态（BLOCKED/自旋）与单次延迟 | 4/8/16 线程各跑 10 万次 consume，采线程状态与 P99；CPU profile 看不出这类争用 |
| 3 | 若位置键改为栈上值类型（不逃逸的临时键），consume 路径可用 local mode 降峰值内存 | `f_mq/src/client/MQSubscription.cj:48` | 峰值内存对照、`getAllocatedLocalObjectSize()` | 按 `docs/LocalMode-O2-Plan.md` 的口径跑改前/改后峰值内存；当前 `keyOf` 的返回值进 `deliveries` 已逃逸，需先按优化方案 #1 改值类型键 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mq/src/client/MQSubscription.cj` | .cj | ✅ | 见发现 #1、#2，优化方案 #1 |
| 2 | `f_mq/src/client/MQTestSetup_test.cj` | .cj | ✅ | 与 #7 逐字相同（仅 `package` 不同），属测试准备代码，按 §2 误报边界不判重复 |
| 3 | `f_mq/src/client/test/LogCapture_test.cj` | .cj | ✅ | 见发现 #3 |
| 4 | `f_mq/src/client/test/MQClient_test.cj` | .cj | ✅ | 见发现 #4；`sameDeliveryPositionIsClaimedOnce` 是发现 #1 的期望固化点 |
| 5 | `f_mq/src/client/test/MQNodePool_test.cj` | .cj | ✅ | 见发现 #5 |
| 6 | `f_mq/src/client/test/MQStubServer_test.cj` | .cj | ✅ | 见发现 #3、#6 |
| 7 | `f_mq/src/client/test/MQTestSetup_test.cj` | .cj | ✅ | 与 #2 逐字相同（仅 `package` 不同） |
| 8 | `f_mq/src/exception/MQException.cj` | .cj | ✅ | 4 个构造器与 `BaseException` 对齐（`f_base/src/BaseException.cj:47-57`），无缺陷 |
| 9 | `f_mq/src/exception/MQException_test.cj` | .cj | ✅ | `MQException()` 的 `message.isEmpty()` 断言与 std 实现一致（`stdlib/libs/std/core/exception.cj:57` `detailMessage = String.empty`） |
| 10 | `f_mq/src/f_mq.cj` | .cj | ✅ | 5 个 `public import` 覆盖 base / base.model / base.payload / exception / client，无遗漏包 |
| 11 | `f_mq/src/test/Facade_test.cj` | .cj | ✅ | 断言值与实现一致（`MQErrorCode.TOPIC_NOT_EXIST == 1`、`messageOf(1) == "topic does not exist"`，见 `f_mq/src/base/MQConstants.cj:24/43-44`） |

合计：`.cj` 11 个 / `.md` 0 个 / 共 11 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 命中：发现 #1（投递语义）、#4（测试边界值漂移）；`MQException` 体系与门面导入逐项核对无问题；本部分无外部输入拼接、无凭据、无 SQL |
| §1 死代码 | 2 | 命中 #2（1 个字段）、#3（2 个无调用者的测试辅助函数）；已逐个符号搜引用：`MQSubscription`（internal）的 `subscribedId` 零读取、`nextStart`/`keyOf`/`deliveries`/`owners`/`autoAck`/`topic`/`subscribeGroup` 均有调用；`CapturingAppender.clear`、`MQStubServer.clear` 零调用；`MQStubServer.isClosed` 是 `Resource` 接口实现，豁免；`MQException*` 为 `public open` 顶级类，对外可达不判 |
| §2 重复逻辑 | 1 | 命中 #4（tags 边界字面量）；另逐行比对 `MQClient_test` 的 5 个 `stubMessage`/`okBut` 调用形态、`MQNodePool_test` 的 3 个 `MQStubServer(ok)` 建桩段，差异在响应码与断言目标，属业务差异；`client/MQTestSetup_test.cj` 与 `client/test/MQTestSetup_test.cj` 逐字相同，但属 §2 误报边界「测试里的准备代码」，不判 |
| §3 空实现 | 1 | 命中 #6（桩服务端吞异常）；`CapturingStream.flush() {}` 是 `OutputStream` 的有意 no-op（内存流无需 flush）；`MQException` 各构造器均有实体；无 `TODO`/`FIXME`（`grep -rn "TODO\|FIXME" f_mq/src` 无命中） |
| §4 栈溢出 | 0 | 本部分无递归、无自引用结构遍历；`MQClient.consume` 的 `while (true)` 是轮询循环不是递归，每次迭代不增栈 |
| §5 OOM | 1 | 命中 #1 的第三个后果（`deliveries` 无界增长）；`MQStubServer.received` 的 `ArrayList` 仅测试进程内增长，用例量有限，不单列 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据；疑似热点已全部降级到「待验证假设」#1/#2 |
| §6.2 大粒度锁 | 0 | 本部分唯一的锁是 `CapturingStream.lock`（测试日志捕获），临界区内是 `String.fromUtf8` 与数组追加，持有时长与日志条数成正比但只在测试进程；`MQSubscription` 用 `ConcurrentHashMap` + `AtomicInt64`，无锁临界区 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`；`MQNodePool_test` 与 `MQClient_test` 的 `spawn` 用于制造并发，不在生产路径；`ack` 广播路径的串行 RTT 在 `MQClient.cj`（本部分外），未计入 |
| §6.4 低效算法 | 0 | `keyOf` 的字符串拼接计入优化方案 #1；`MQClient_test.countOf` 为 O(请求数) 的测试辅助，单用例请求数 ≤ 数十，不构成 O(n²) 风险；本部分无 `remove(at: 0)`、无嵌套匹配 |
| §7 降堆内存方案 | 0 | 唯一可量化项（`deliveries` 条目膨胀）与发现 #1 同根因，已并入该条的建议，不重复计数 |
| §8 降 CPU 方案 | 1 | 优化方案 #1（值类型位置键），证据状态为无基线 |
| §9 local mode 可行性 | 0 | `keyOf` 的临时 String 会经 `deliveries` 逃逸，不满足线程内释放前提；其余函数无函数内大对象；已转为待验证假设 #3 |
| §11 现有代码的 BUG（存量） | 3 | 命中 #1（契约不符）、#5（非确定断言）、#6（吞异常）；另核对：`nextStart` 的 `% owners.size` 在 `owners` 为空时会除零，但唯一调用点 `MQClient.cj:223` 已先拦截空集合；`cursor` 的 Int64 溢出需 9.2×10¹⁸ 次调用，不构成可达缺陷 |
| §12 并发安全与锁粒度 | 1 | 命中 #1（跨线程共享的 `deliveries` 语义问题）；`deliveries`/`owners`/`cursor` 的并发访问手段齐备（`ConcurrentHashMap`、`AtomicInt64`、不可变数组），无检查-然后-写入缺陷；`MQSubscription` 无发布逸出 |
| §14 功能完备性与 README 覆盖 | 0 | `f_mq.cj` 的 5 个 `public import` 覆盖模块全部 public 包（base、base.model、base.payload、exception、client），无「注册了但没导出」；本部分不含 README，`MQException`/`MQSubscription`（internal）不涉及文档承诺 |
| 文件覆盖（§13 等） | 11/11 | 11 个文件全部读完；本部分无 `.md`，§13 无对象 |

## 模块统计

> 仅统计本部分 11 个文件。

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 0 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

存量缺陷 6 条（严重 1 + 轻微 5），是否纳入修复待用户决定；本部分无「本次改动」引入的问题（工作区快照，`f_mq` 无本地改动）。

## 总评

本部分的生产代码只有 3 个文件、158 行（`MQSubscription.cj` 56 行、`exception/MQException.cj` 75 行、门面 `f_mq.cj` 27 行），其余是测试。代码质量整体良好：异常层次与 `BaseException` 严格对齐、门面导出完整、测试覆盖了投递/确认的绝大多数分支（NOT_OWNER 回退、ACK_UNKNOWN 容忍、部分退订保留本地订阅、并发认领唯一性），注释密度与「为什么这么写」的说明都到位。

阻塞项只有一个，但性质严重：`deliveries` 把「并发去重认领」实现成了无生命周期的永久表。它让 README 承诺的 at-least-once 在同一客户端实例内失效——未 ack 的消息在被丢弃若干次后直接进死信，业务与日志都看不到；同时该表对进死信的消息永久驻留，长时间运行会缓慢增长。修法不复杂（认领加 TTL/上限 + 跳过时计数告警），但需要同步改掉把该行为写成期望的用例 `sameDeliveryPositionIsClaimedOnce`，属于语义决策，建议优先排期。

其余 5 条轻微项集中在测试设施：清理入口未接线导致静态日志缓冲跨用例累积（可能造成假通过）、边界值硬编码、墙钟时序断言、桩服务端吞异常。这些不影响生产行为，可随下次测试维护一起处理。

范围外提示（不计入统计）：`MQClient.ack` 命中投递映射后只打那一个节点，超时/拒绝时保留映射并抛错、不回退广播（`f_mq/src/client/MQClient.cj:315-335`），投递节点长期不可达时该位置将永远无法确认；该文件属其他子轮，此处仅记录。
