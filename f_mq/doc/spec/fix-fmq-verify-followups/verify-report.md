# 校验报告：fix-fmq-verify-followups

- 校验时间：2026-10-18
- 校验方式：`/opsx:verify`（融合侧只读复核）+ 本地实跑核对
- 结论：**通过，可归档**。无 critical、无 warning 遗留（3 项 warning 已当场修正为文档/任务描述）；4 项 suggestion 记录如下。

## 1. 任务完成度

40/40 全部勾选。7 个阶段逐项核对：

| 阶段 | 核对结果 |
|---|---|
| 0 准备 | 基线 20/79/145 与实测一致 |
| 1 管理端 | `fmq/src/server/MQManager_test.cj`，5 个用例覆盖六子命令正常/错误/连接失败 |
| 2 BODY 容器 | `MQMessageRecord_test.cj` 覆盖 `TreeSet`/`HashMap`/`Array<Int64>` 非空与空往返；`MQFilter_test.cj` 覆盖 `$.age`、`$[0]` 与空容器 + 空过滤 |
| 3 备份刷写/关闭 | `BackupReplicator_test.cj` 定时器用例；`BackupStore_test.cj` 关闭读回与 4 线程并发；`BackupStore.cj` 增加 `closed` 原子标志与双检查 |
| 4 host 归位 | `f_mq/src/base/MQHost.cj` 新建；`MQClientConfig.parseHost` 删除；`NodeRegistry` 改用 `MQHost` |
| 5 段格式文档 | `fmq/doc/详细设计.md` §5.8 记录 4B 大端格式与跨版本约束；`f_mq/doc/详细设计.md` §3.2 有指针 |
| 6 远端指针 | `MetaSyncer.applyRemote` 计算并传入 `nextStart`；用例覆盖应用后指针与后续注册起点 |
| 7 回归交付 | 20/82/154 + `E2E_OK`；工作区干净；代码/文档分两次提交 |

## 2. 场景覆盖

| Capability | 场景 | 证据 |
|---|---|---|
| `fmq/manager-cli` | 6 | `MQManagerTest` 5 个用例覆盖全部场景 |
| `f-mq/protocol` | 4 | 三类容器往返、空容器、过滤路径 |
| `fmq/metadata-cluster` | 13 | 轮转 5 + 备份 8，新增远端推进/定时刷写/关闭排空 |
| `fmq/server-runtime` | 5 | host 归属 2 + 关闭并发 3 |
| `fmq/queue-storage` | 4 | 文档格式 + 长度/轮转行为由既有 `QueueLog_test` 覆盖 |

## 3. 实跑证据

- `f_io`：20/20
- `f_mq`：82/82
- `fmq`：154/154（`--no-progress`）
- `scripts/mq_e2e.sh`：`E2E_OK`（发布 6872ms、消费 15615ms、重投 3、死信段 1）
- 工作区：干净

## 4. 校验发现与处置

### Warning（3，已修正）

1. `design.md` 中管理端用例落点写 `fmq/src/manager/`，实际为 `fmq/src/server/` —— 已改正。
2. `tasks.md` 三条 `--filter` 验收命令在本仓库不命中（SKIPPED 154）—— 已改为全量命令并注明原因。
3. `grep "f_mq.client"` 断言未排除测试装配 `MQServer_test.cj` —— 已限定为非测试源码。

### Suggestion（4，记录，不阻塞）

1. 管理端成功场景用「重复注册返回 1」间接证明状态变化，未直接断言 `listTopics` 输出。
2. 空容器 + 空过滤的组合断言已补（本轮修复）。
3. 任务描述与实际 `$[0]` 路径已对齐（本轮修复）。
4. `fmq/manager-cli` 的 delta 与主 spec 的「连接失败语义」有轻度重叠，后续可合并维护。

## 5. 结论

实现、用例、文档与规格一致，无未覆盖的 critical；同意进入 `opsx:archive`。
