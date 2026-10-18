# 任务：fmq verify 遗留修复

> 每个编码任务按 TDD 执行：先写失败用例（Red），再改实现（Green），必要时重构。
> 纯文档任务不适用红绿，直接用检索/构建验收。

## 0. 准备

- [x] 0.1 复核归档 `verify-report.md` 与 tasks 第 11 节，确认 6 项现状与落点（读源码，不改代码）
- [x] 0.2 记录基线：`f_io` 20 项、`f_mq` 79 项、`fmq` 145 项、`E2E_OK`

## 1. 管理端子命令用例（11.1）

- [x] 1.1 新增 `fmq/src/server/MQManager_test.cj`（包内可见性需要 `MQServerOptions`）：进程内起服务，覆盖 `registerTopic` / `deleteTopic` / `registerSubscriber` / `deleteSubscribeGroup` / `listTopics` / `listSubscribeGroups` 的成功路径（返回 0 + 状态可观察）
- [x] 1.2 同文件补错误路径：主题重复、删除不存在主题、对未注册主题建组、删除不存在组、空列表（断言返回码）
- [x] 1.3 同文件补连接失败：`--server` 指向未监听端口，断言返回 1
- [x] 1.4 `cd fmq && cjpm test --no-progress` 全绿（154 项；`--filter MQManager` 在本仓库不命中，已用全量替代）

## 2. BODY 容器矩阵（11.2）

- [x] 2.1 先写用例：`TreeSet<Int64>` / `HashMap<String, Int64>` / `Array<Int64>` 的非空往返（类型、长度、元素一致）
- [x] 2.2 再写空容器往返与 `filter` 求值（`$.age`、`$[0]`）
- [x] 2.3 实测 `f_codec` 已支持三类容器，用例直接通过；未在 MQ 层加特判
- [x] 2.4 实现/修正后 `cd f_mq && cjpm test` 全绿（82 项）

## 3. 备份刷写与关闭（11.3）

- [x] 3.1 先写用例：`BackupReplicator` 只记录 1 条、等待 > 100ms，断言定时器触发一次发送（超时 2s 轮询）
- [x] 3.2 先写用例：`BackupStore.close()` 与 4 线程并发 `append`，断言无异常、`instanceCount == 0`、关闭前成功写入的记录可读回
- [x] 3.3 用例固化关闭语义：关闭后 `append` 不得重建 `QueueLog`，并发关闭不得抛异常
- [x] 3.4 实现：`BackupStore` 增加 `closed` 原子标志；`close()` 置位后清空；`append` 在创建前后检查，关闭后静默丢弃
- [x] 3.5 `cd fmq && cjpm test --no-progress` 全绿（`--filter "Backup"` 不命中，已用全量替代）

## 4. host 解析归位（11.4）

- [x] 4.1 先写 `f_mq/src/base/MQHost_test.cj`（原 parseHost 用例迁移：合法、空串、缺端口、端口 0、越界），确认 Red（类型不存在 / 编译失败）
- [x] 4.2 新增 `f_mq/src/base/MQHost.cj`，实现原样迁移
- [x] 4.3 删除 `MQClientConfig.parseHost`，改内部调用点（`MQClientConfig.hosts`、`MQNodePool`）
- [x] 4.4 `fmq/src/cluster/NodeRegistry.cj` 改 import `fountain::f_mq.base.MQHost`，删除旧用例
- [x] 4.5 验收：`grep -rn "f_mq.client" fmq/src --include='*.cj' | grep -v '_test.cj'` 无输出（测试装配除外）；`cd f_mq && cjpm test`、`cd fmq && cjpm test --no-progress` 全绿

## 5. 段格式文档（11.5）

- [x] 5.1 把 design.md §3 的格式与兼容约束写入 `fmq/doc/详细设计.md` 存储章节
- [x] 5.2 在 `f_mq/doc/详细设计.md` 引用该格式的位置补一句指针，避免两份定义漂移
- [x] 5.3 验收：`grep -n "4 字节大端" fmq/doc/详细设计.md` 命中，且与源码 `PREFIX_SIZE = 4` 一致

## 6. 远端轮转指针（11.6）

- [x] 6.1 先在 `MetaSyncer_test.cj` 写失败用例：节点 1 应用远程分配后 `nextStartNode` 与注册节点一致；再注册新主题的起始下标相同
- [x] 6.2 用例固化期望：远端指针从 0 推进到 1（实现前必失败）
- [x] 6.3 实现：`applyRemote` 计算 `(startNodeIndex + queueNum) % nodeCount` 并传给 `applyTopic`
- [x] 6.4 补幂等场景：重复广播同一分配，返回值与指针均稳定
- [x] 6.5 `cd fmq && cjpm test --no-progress` 全绿（`--filter MetaSyncer` 不命中，已用全量替代）

## 7. 回归与交付

- [x] 7.1 `f_io`：`cjpm test` 20 项通过
- [x] 7.2 `f_mq`：`cjpm test` 全绿（原 79 项 + 新增）
- [x] 7.3 `fmq`：`cjpm test --no-progress` 全绿（原 145 项 + 新增）
- [x] 7.4 `scripts/mq_e2e.sh` 输出 `E2E_OK`（发布 6450ms、消费 13454ms、重投 3、死信段 1）
- [x] 7.5 更新 `fmq/README.md` / `fmq/README_en.md` 的已知限制：备份存储关闭后写入静默丢弃
- [x] 7.6 依赖图无需重生成（无模块增删）；确认 `fmq` 非测试源码无 `f_mq.client` 引用
- [x] 7.7 按类型分组提交（代码 / 文档），工作区干净

## 验收清单

- [x] 管理端六子命令错误路径有用例且全绿
- [x] `TreeSet` / `HashMap` / `Array` 的 BODY 往返与 filter 有用例
- [x] 备份 100ms 定时 flush、关闭排空、关闭并发均有直接用例
- [x] `fmq/src` 非测试源码不再 import `f_mq.client`，`parseHost` 位于 `f_mq.base`
- [x] `QueueLog` 的 4 字节大端长度前缀已进 `fmq/doc/详细设计.md`
- [x] 远端节点应用分配后推进 `nextStartNode`，有失败后转绿的用例
- [x] 三模块全量 + E2E 全绿（f_io 20、f_mq 82、fmq 154、E2E_OK）
