# 设计：fmq verify 遗留修复

> 依据：`openspec/changes/archive/2026-10-18-add-fmq-message-queue/verify-report.md` 的 6 项遗留，
> 以及归档 `tasks.md` 第 11 节。本文固定每项的落点、算法与用例边界；实现细节冲突时以源码实测为准。

## 1. 目标与非目标

### 目标

1. 管理端六个子命令有独立、可断言的正常/错误路径用例。
2. BODY 的 `TreeSet` / `HashMap` / `Array` 三类容器进入编解码与 filter 测试矩阵。
3. 备份的 100ms 定时刷写、关闭排空与关闭并发写入有直接用例；关闭路径无竞态。
4. `fmq` 不再 import `f_mq.client`，`parseHost` 归位到 `f_mq.base`。
5. `QueueLog` 的 4 字节大端长度前缀进入设计文档。
6. 远端节点应用主题分配时推进 `nextStartNode`，消除分配倾斜。

### 非目标

- 不改协议命令号、帧格式、配置键与持久化目录布局（除第 5 项补文档）。
- 不做故障转移、备份接管、跨节点事务。
- 不重构 `f_io.SegmentedLog` 的存储格式（前缀属于 `QueueLog` 层）。

## 2. 关键决策

### 2.1 管理端测试（对应 11.1 / 任务 1）

- 落点：`fmq/src/manager/MQManager_test.cj`（新增）。
- 方式：进程内起 `MQServer`（复用 `MQServer_test` 的装配方式），用 `MQManager` 直接调用六个
  方法；连接失败路径用一个未监听端口构造 `MQManagerArgs`。
- 断言维度：返回码（0 / 1 / 2）与服务端状态变化（注册后 `listTopics` 可见、删除后不可见）。
- 不引入金样文件：stdout 由 CLI 直接打印，单元测试不捕获；文案只由 `MQManagerOutput` 的独立用例覆盖。

### 2.2 BODY 容器矩阵（对应 11.2 / 任务 2）

- 落点：`f_mq/src/base/payload/MQPayload_test.cj` 或 `MQMessageRecord_test.cj`（就近扩展）。
- 数据：非空与空的两组 `TreeSet<Int64>`、`HashMap<String, Int64>`、`Array<Int64>`。
- 断言：`decode(encode(x))` 的类型、长度/键集合、元素逐一相等；`MQMatcher.matches` 对
  `$.age`、`$.items[0]` 等路径返回预期布尔。
- 若 `f_codec` 对 `TreeSet` 不支持，先补 `f_codec` 用例再改编码路径；不在 MQ 层做特判。

### 2.3 备份刷写与关闭（对应 11.3 / 任务 3）

- `BackupReplicator_test.cj`：新增「1 条记录 + 等待 > 100ms → 收到一次发送」；用真实
  `Timer` 与 `FakeTransport`，超时 2s 轮询，避免固定 sleep 造成偶发。
- `BackupStore`：
  - 增加 `closed` 原子标志；`close()` 先置位、再在锁内关闭所有 `QueueLog` 并清空。
  - `append` 在 get-or-create 前后各检查一次 `closed`：已关闭则直接返回（丢弃），不创建新实例。
  - 用例：4 线程持续 append 与 close 并发；断言无异常、`instanceCount == 0`、
    「关闭前成功返回的条数」≤「读回条数」且差值只可能来自关闭瞬间被拒绝的调用。
- 关闭后 `append` 的语义定为**静默丢弃**（与备份「不阻塞发布、可丢」的既有取舍一致），
  不向发布路径抛异常。

### 2.4 host 解析归位（对应 11.4 / 任务 4）

- 新增 `f_mq/src/base/MQHost.cj`：`public class MQHost { public static func parseHost(entry: String): ?(String, UInt16) }`，
  实现原样迁移（trim、单冒号、端口 1..65535）。
- `MQClientConfig.parseHost` 删除，`MQClientConfig.hosts` / `MQNodePool` 改调 `MQHost.parseHost`；
  `fmq/src/cluster/NodeRegistry.cj` 改 import `fountain::f_mq.base.MQHost`。
- 用例迁移：`MQClientConfig_test` 的 parseHost 用例改到新文件 `MQHost_test.cj`，断言不变。
- 验证：`grep -r "f_mq.client" fmq/src` 为空；`fmq` 构建与测试通过。

### 2.5 段格式文档（对应 11.5 / 任务 5）

- 在本文 §3 固化格式；同步到 `fmq/doc/详细设计.md` 的存储章节与 `f_mq/doc/详细设计.md`
  需要引用处。
- 明确约束：前缀宽度 4 字节、大端、无符号、只计记录体；跨版本不得改变；空记录前缀为 0。

### 2.6 远端轮转指针（对应 11.6 / 任务 6）

- 现状：`MetaSyncer.applyRemote` 调 `store.applyTopic(assignment)`，未传 `nextStart`，远端
  `nextStartNode` 停旧值；`mergeSnapshot` 只在快照值更大时推进，运行期广播不经过它。
- 修正：`applyRemote` 用分配结果计算
  `nextStart = (assignment.startNodeIndex + assignment.queueNum) % nodeCount`，
  再调 `store.applyTopic(assignment, nextStart: nextStart)`；`nodeCount` 取 `transport.nodeCount`。
- 幂等性：重复广播同一主题时 `applyTopic` 返回 `Duplicated`，但仍应把 `nextStart` 推进到
  同一值（幂等写入）。
- 用例：`MetaSyncer_test` 新增「节点 1 应用远程分配后，其 `nextStartNode` 与节点 0 一致；
  再注册新主题得到相同起始下标」。

## 3. QueueLog 记录格式（正式定义）

```
段文件（log_<n>.log）内连续存放：
+----------------+---------------------------+
| 4B 大端 length | length 字节的记录体        |
+----------------+---------------------------+

length = 记录体字节数（不含这 4 字节），取值范围 1..64MiB
记录体 = MQMessageRecord.encode(...) 的原始字节，原样落盘
```

- 读取端按 `length` 取整条；`length <= 0` 或剩余字节不足视为损坏，停止读取（不返回空记录）。
- 记录不跨段：若当前段剩余空间 `< 4 + length`，先轮转再写。
- 该前缀只用于顺序读取定界，不是索引；`LogPosition.offset` 指向前缀起点。
- 兼容性：宽度、字节序、含义任一改变都会让旧段无法按边界读取；升级必须保持或提供迁移。

## 4. 测试与验收

| 项 | 用例落点 | 验收 |
|---|---|---|
| 管理端 | `fmq/src/manager/MQManager_test.cj` | 六子命令正常/错误路径全绿 |
| BODY 容器 | `f_mq/src/base/**/*_test.cj` | 三类容器非空/空往返 + filter |
| 备份 | `BackupReplicator_test.cj`、`BackupStore_test.cj` | 定时 flush、关闭排空、并发关闭 |
| 分层 | `MQHost_test.cj` + import 检查 | `fmq` 无 `f_mq.client` 引用 |
| 文档 | `design.md`、`fmq/doc/详细设计.md` | 格式与兼容约束可检索 |
| 轮转 | `MetaSyncer_test.cj` | 远端指针与注册节点一致 |

回归门槛：`f_io` / `f_mq` / `fmq` 全量测试通过（`fmq` 用 `--no-progress` 规避 SDK 报告器缺陷），
`scripts/mq_e2e.sh` 输出 `E2E_OK`。

## 5. 风险

- `f_codec` 可能不支持 `TreeSet` 编码；若如此，任务 2 扩到 `f_codec`，但不在 MQ 层做类型特判。
- `BackupStore` 关闭语义改为「静默丢弃」；需在 README 的已知限制中说明。
- `parseHost` 迁移是源码级 BREAKING；仓库内调用点已全部覆盖，外部引用不在本期兼容范围。
