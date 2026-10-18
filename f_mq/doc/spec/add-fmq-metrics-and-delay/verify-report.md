# 校验报告：add-fmq-metrics-and-delay

- 校验时间：2026-10-18
- 校验方式：融合侧只读复核 + 三模块实跑 + 单点探针验证（探针用后已还原，工作区干净）
- 结论：**不通过，暂不可归档**。1 项 critical（延迟投递在组内多订阅场景被绕过）；
  5 项 warning（3 项用例缺口、2 项口径/健壮性）；3 项 suggestion。

## 1. 任务完成度

49/49 全部勾选。逐阶段核对：

| 阶段 | 核对结果 |
|---|---|
| 0 准备 | `fmq/doc/backlog.md` 存在；基线在 8.x 更新为 20/85/171，与实测一致 |
| 1 协议载荷与发布时间 | `MQInternalKind.STATS`、`MQProtocol.stats`、`publishTime` 均已实现；用例齐（`MQProtocol_test.cj:168`、`MQMessageRecord_test.cj:144`、`MQErrorCode_test.cj:58`） |
| 2 主题延迟元数据 | 字段、`MQAssignment.allocate`、`MetaStore` 落盘、广播链路均实现；但 2.1 要求的 f_mq 层往返用例缺失（W1），负值拒绝无服务端用例（W2） |
| 3 延迟投递 | `GroupCursor` 到期判定、队首阻塞、重启、非标准 ID 均有用例；但组内「分配给其它订阅」路径未做到期判定（C1） |
| 4 指标计数器 | `MQMetrics` + 三处埋点 + 投递/重投/确认/死信用例齐 |
| 5 统计服务与分派 | `scanAfter`/`localTopics`/`delayingOf`/`stats`/`STATS` 分派齐；5 个用例覆盖积压、lag、过滤、未知主题、无副作用（W4 属口径边界） |
| 6 管理端 | `stats` 子命令、`registerTopic` 三操作数、`listTopics` 延迟列、帮助文本均已实现；6.3 的列输出断言缺失（W3），TSV 字段守卫有一处越界风险（W5） |
| 7 文档 | 两份 README、两份详细设计、`MQUsage` 均已更新；`backlog.md` 第 11 项以注释代替移除（S3） |
| 8 回归与交付 | `f_io` 20/20、`f_mq` 85/85、`fmq` 171/171 实测复现；E2E 未复跑（S1）；工作区干净，提交分组符合要求 |

## 2. 场景覆盖

| Capability | 场景数 | 覆盖情况 | 证据 |
|---|---|---|---|
| `f-mq/protocol` | 6 | 4 覆盖；2 缺失（元数据往返、分配往返的 `delayingMs` 断言） | `MQProtocol_test.cj:168`；`MQModel_test.cj:63` 与 `MQPayload_test.cj:59` 未断言新字段 |
| `fmq/consume-semantics` | 6 | 5 覆盖；1 存在实现缺陷（组内多订阅） | `GroupCursor_test.cj:497/517/539`、`nonStandardMessageIdDeliversImmediately`；C1 |
| `fmq/metrics` | 7 | 6 覆盖；「无订阅组输出 group 为空」与「查询前后 committed 不变」仅部分断言 | `ConsumeService_test.cj:296-377` |
| `fmq/manager-cli` | 8 | 6 覆盖（多为退出码断言）；`listTopics` delaying 列、「（空）」输出未直接断言 | `MQManager_test.cj:159/173/181`；`MQManagerArgs_test.cj:50/64/66` |
| `fmq/metadata-cluster` | 3 | 1 直接覆盖（重启保持）；快照携带与远端应用靠广播用例间接覆盖 | `MetaStore_test.cj:38`、`MetaSyncer_test.cj:160/177/208` |

## 3. 实跑证据

- `f_io`：20/20（`cjpm test --no-progress`）
- `f_mq`：85/85
- `fmq`：171/171
- 探针：临时加入 `tempProbeDelayedTopicOtherMember` 用例 → 失败（见 C1），随后 `git checkout --` 还原；`git status` 干净
- `scripts/mq_e2e.sh`：本轮未复跑（tasks 8.4/8.5 声称 `E2E_OK`、延迟 ≥2.5s，脚本 `scripts/mq_e2e.sh:198-210` 确有该检查）

## 4. 校验发现与处置

### Critical（1）

1. **延迟主题在组内多订阅场景可被提前投递**
   - 位置：`fmq/src/queue/GroupCursor.cj:266-277`（扫描时把记录分配给同组其它订阅，未判到期）；
     `GroupCursor.cj:116-180`（取走「已分配未投递」记录时同样不判到期）。
   - 复现：主题 `delaying=61s`，组内 s1 只看 tag `a`、s2 只看 tag `b`，发布一条带 tag `b` 的消息。
     `s1.next` 返回空并把记录分配给 s2；随后 `s2.next` **立即取到**该消息，`committed` 停在原位。
     探针断言 `cursor.next(s2, members, MQMatcher()).isNone()` 失败。
   - 与规格冲突：`consume-semantics`「延迟投递」要求 `delaying` 作用于**所有队列与订阅组**，
     「一条记录只有在 发布时间 + delaying ≤ 当前时间 时才可投递」。
   - 修复方向（供 `opsx-apply` 参考）：在「记录即将投递给任一订阅」时统一判到期——扫描段的
     `assignedTo` 分支也要判；`next` 第一段对 `delivered == false` 的已分配记录补判
     （`delivered == true` 的重投按设计仍不延迟）。补一条组内双订阅用例。

### Warning（5）

1. **W1 `delayingMs` 的协议层往返用例缺失**（tasks 2.1，`f-mq/protocol` 两个场景）
   `MQModel_test.cj:63` 与 `MQPayload_test.cj:59` 只断言 topic/queueNum/owners，没有 `delayingMs`。
   实现本身正确（`@DataAssist` 按字段序列化，`MetaStore_test.cj:55` 间接验证）。
2. **W2 服务端负值拒绝无用例**（tasks 2.1 后半）
   `MetaSyncer.cj:51` 已实现 `delayingMs < 0 → INVALID_TOPIC`，但三个相关测试文件均未构造负值注册请求；
   现有断言只覆盖管理端本地解析（`MQManager_test.cj:173`）。
3. **W3 `listTopics` 延迟列无断言**（tasks 6.3，`manager-cli`「带延迟注册」场景）
   `MQManager.cj:149-152` 已输出 `delaying` 列，`MQManager_test.cj:159` 只断言退出码 0。
4. **W4 `stats` 的「全部」与「按主题」对零本地队列主题口径不一致**
   `ConsumeService.cj:138-144`：`stats ""` 用 `localTopics()`（`openTopic` 在每个节点都会登记，
   即使本节点没有任何队列），仍会输出 backlog/lag 全 0 的 `R` 行；而 `stats <topic>` 因
   `localQueues(topic).size == 0` 直接不输出。与规格「只反映被查询节点的本地队列」存在偏差。
5. **W5 `MQManager.stats` 的 TSV 字段守卫差一**
   `MQManager.cj:199-209`：守卫写 `fields.size < 10`，随后访问 `fields[10]`（共 11 列）。
   服务端正常输出不会触发，但畸形行会抛越界，被 `withClient` 的兜底当成「无法连接消息队列服务」。
   应为 `< 11`。

### Suggestion（3）

1. E2E 本轮未复跑；若归档前要留证，重跑一次 `scripts/mq_e2e.sh`。
2. `MQManager_test.cj:159-170` 对 `stats` 全部/按主题/未知主题只断言退出码，
   未断言「（空）」与表头；`nonStandardMessageIdDeliversImmediately` 只断言立即投递，未捕获 WARN。
3. `fmq/doc/backlog.md:42` 第 11 项仍以编号条目存在（注明「已移除」），与 tasks 7.4「从 P1 移除」字面不符。

## 5. 结论

除 C1 外，实现、用例与文档整体与规格一致，三模块全量用例可复现全绿。
C1 属于本次变更的核心语义（延迟到点才投递），且现有用例未覆盖该组合，**不建议直接归档**：

- 补实现 → 走 `opsx-apply`（修 `GroupCursor` 两处判定 + 新增组内双订阅用例），完成后重新 `opsx:verify`；
- 若确认「同组内不同过滤条件」不属于支持范围 → 走 `opsx-update` 收敛规格措辞与场景，再归档。
