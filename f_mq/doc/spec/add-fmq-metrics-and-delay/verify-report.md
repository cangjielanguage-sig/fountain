# 校验报告：add-fmq-metrics-and-delay

- 校验时间：2026-10-18（最终轮）
- 校验方式：融合侧 `/opsx:verify` 只读复核 + 三模块实跑 + E2E
- 结论：**无 critical，可归档**

## 1. 任务与需求

- `tasks.md`：**50/50** 全部勾选。
- 5 个 capability、9 条 ADDED requirement 均有实现与测试证据：
  - `fmq/metrics`：指标口径、TSV 查询、无副作用。
  - `fmq/manager-cli`：`stats [topic]`、`registerTopic ... delaying=`、`listTopics` 延迟列。
  - `fmq/consume-semantics`：延迟到期才投递、队首阻塞、跨重启。
  - `f-mq/protocol`：主题元数据/分配 `delayingMs`、`STATS` 字符串载荷、`publishTime`。
  - `fmq/metadata-cluster`：延迟随落盘/广播/快照复制。

## 2. 实跑证据

| 项 | 结果 |
|---|---|
| `f_io` | 20/20 |
| `f_mq` | 86/86 |
| `fmq` | 174/174 |
| `scripts/mq_e2e.sh` | `E2E_OK`（发布 100 条 4540ms、消费 9591ms、重投 3、死信 1；`delaying=3s` 用例 ≥2.5s 通过） |
| 工作区 | 干净 |

## 3. 校验发现与处置

### Critical（已修复）

C1：延迟主题在组内多订阅时被绕过 —— 记录分配给同组其它订阅时未做到期判定，
`committed` 未推进但 `s2` 可提前取走。
处置：`GroupCursor` 在「扫描分配给他人」与「取走已分配未投递」两处补 `isDue`；
新增 `delayedRecordNotAssignedToOtherSubscriberEarly` 用例，红转绿。

### Warning（已处理）

1. `bytes` 指标只计算未输出 —— 已从规格/README 移除该指标，行格式精简为 10 字段。
2. `lagMs` 首条记录不可解析时继续取后续时间 —— 已改为首条解析失败即 `None`（输出 0），并补断言。
3. manager 场景只断言退出码 —— 补 `stats` 连接失败用例；输出断言受限于测试框架未捕获 stdout，记录为已知限制。
4. 指标场景覆盖不足 —— 补「全部确认后 backlog=0/lag=0」「两主题 + 按主题过滤」
   「查询不创建游标/不改变记录数」「无组主题输出空 group 行」用例。
5. 规格残留对象载荷描述 —— 全部改为 TSV 文本协议；`MQStatsSnapshot` 等描述已删除。
6. `stats` 全量/按主题对「无本地队列主题」口径不一致 —— `QueueManager.localTopics()` 只返回本节点持有队列的主题，并补测试。
7. `MQManager.stats` 字段守卫 `<10` 越界 —— 改为 `<11`。

### Suggestion（记录，不阻塞）

- 非标准 messageId 的 WARN 未捕获（行为已按规格立即投递）。
- `lagMs` 跨队列聚合时若某队列首条不可解析，当前跳过该队列取其它队列时间；后续可统一为「任一不可解析即 0」。

## 4. 结论

实现、规格、设计与实测一致；无未修复的 critical。同意进入 `opsx:archive`。
