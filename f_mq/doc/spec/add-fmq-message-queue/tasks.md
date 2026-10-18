# Tasks: add-fmq-message-queue

> 约定：每一小步都按 TDD 走「先写失败用例（Red）→ 最小实现（Green）→ 重构（Refactor）→ 回归」。
> 用例文件与实现同目录，命名 `<Type>_test.cj`；文件系统用例统一使用 `/tmp/fmq_test_<用例名>/`
> 并在用例前后清理。时间相关逻辑必须注入时钟，不使用 `sleep`。
>
> 环境（按需 `source` 仓颉环境，不要 `set -u`）：
>
> ```bash
> cd <worktree>/f_io   && cjpm build && cjpm test
> cd <worktree>/f_mq   && cjpm build && cjpm test
> cd <worktree>/fmq    && cjpm build && cjpm test
> ```

## 0. 前置：f_io 位置可见性

- [x] 0.1 在 `fmq` 侧写一个最小探针（读 `pos.seq` / `pos.offset` 并调用 `openEntryStream`），确认当前编译失败信息为 `can not access field 'seq'`
- [x] 0.2 把 `f_io/src/SegmentedLog.cj` 的 `LogPosition.seq` / `offset` 改为 `public let`，补字段用途注释
- [x] 0.3 在 `f_io` 增加/保留用例：`append` 返回位置可读、两字段可回传 `openEntryStream`、跨段位置正确
- [x] 0.4 跑 `cd f_io && cjpm test` 全量回归（当前 19 项）并记录结果
- [x] 0.5 重新编译 `f_mq` / `fmq` 的探针，确认位置读取链路通过

## 1. `f_mq` 基础（独占，先行）

- [x] 1.1 `src/exception/MQException.cj`：先写 `MQException_test.cj`（四个 `init` 重载、`cause`/`message` 语义、子类关系），再实现 `MQException` / `MQConnectionException` / `MQServiceException`（含 `code`）
- [x] 1.2 `src/base/MQConstants.cj`：先写 `MQErrorCode_test.cj`（0–11 数值稳定、文案非空且不重复、`MQConfigKey.CLIENT_HOSTS == "mqClient_hosts"`、`MQInternalKind` 常量），再实现常量
- [x] 1.3 `src/base/MQTopic.cj`：先写合法/非法主题用例（`/order`、`order`、`/order/`、`//a`、`/a b`），再实现单趟扫描校验
- [x] 1.4 `src/base/model/*.cj`：先写 `MQModel_test.cj`（`MQTopicMeta`/`MQSubscribeGroupMeta` 往返、`MQMessage` 标量/对象/None/类型不匹配的 `get<T>()`），再实现模型类
- [x] 1.5 `src/base/MQFilter.cj`：先写 `MQFilter_test.cj`（空串、布尔路径、缺失路径、谓词、`DataNone`、存在即真、非法表达式），再实现 `compile/path/matches`
- [x] 1.6 `src/base/MQMessageRecord.cj`：先写 `MQMessageRecord_test.cj`（全类型往返、空 tags、逐段解码、截断/多余/空记录、前缀只读、MESSAGE_ID 一致、`MQBytes` 两种形态、编码器资源归还），再实现 `encode/decode/topic/tags/body/messageId` 与 `MQBytes.fromData`
- [x] 1.7 `src/base/payload/*.cj`：先写每类型往返用例（含 `MQMetaSnapshot` 嵌套、`MQBackupPayload` 字节数组、空 `record`、分配越界、死信上下文、内部消息 kind），再实现 14 个 `@DataAssist` 载荷类
- [x] 1.8 `src/base/MQProtocol.cj`：先写 `MQProtocol_test.cj`（各工厂命令正确、记录逐字节、16KB 大记录、帧往返、类型不匹配、`kindOf` 分类、`respond` 回显 id、`fail`、`asResult` 空载荷、`asConsumeResult`），再实现构造与解析
- [x] 1.9 `src/f_mq.cj`：先写只 `import fountain::f_mq.*` 的门面用例，再补三条 `public import`，并确认 `internal` 类型未被导出
- [x] 1.10 回归：`cd f_mq && cjpm test` 全绿，记录用例数

## 2. `f_mq` 客户端

- [x] 2.0 建测试桩 `src/client/test/MQStubServer.cj`：基于 `f_net.Server<DataAny>` 的进程内服务端，可预设响应并记录收到的请求
- [x] 2.1 `MQClientConfig`：先写 `MQClientConfig_test.cj`（配置读取、去空格、缺失抛异常、`host:port` 解析、非法项），再实现 `hosts` / `parseHost`
- [x] 2.2 `MQNodePool`：先写 `MQNodePool_test.cj`（懒建、同下标缓存、死节点抛异常、`aliveNodes` 过滤、`close` 幂等），再实现
- [x] 2.3 `MQOwnershipCache`：先写 `MQOwnershipCache_test.cj`（命中、TTL 过期、失效、替换语义），再实现（注入 `now`）
- [x] 2.4 `MQClient.publish`：先写 `MQClientPublish_test.cj`（发往 owner、字段与 id 一致、主题不存在、`NOT_OWNER` 换节点、非法主题本地失败、全节点不可达、多 tags 顺序），再实现
- [x] 2.5 `MQClient.subscribe` / `unsubscribe`：先写用例（返回 UUID、所有节点同 id、汇总 owners、未知组回滚、默认组、非法 filter 本地失败、退订幂等、未知 id），再实现
- [x] 2.6 `MQClient.consume` / `ack`：先写用例（解码与位置、空后换 owner、阻塞等待、订阅失效、对象 BODY、ack 回投递节点、未知位置广播、autoAck 广播、并发不重复），再实现
- [x] 2.7 生命周期：先写 `MQClientLifecycle_test.cj`（关闭连接、幂等、关闭后调用抛异常、关闭与调用并发），再实现 `close` / `isClosed`
- [x] 2.8 回归：`cd f_mq && cjpm test` 全绿（含阶段 1 全部用例）

## 3. `fmq` 基础设施

- [x] 3.0 可行性验证：确认 `fmq` 作为 executable 能否 `cjpm test`；不可用则先建 `fmq_test` 测试模块或把纯逻辑放入可测子包，并记录结论
  > 结论：本 worktree 上 `cd fmq && cjpm test` 可直接运行（已用临时冒烟用例验证），无需额外测试模块。
- [x] 3.1 `MQFileNames`：先写 `MQFileNames_test.cj`（可逆、无碰撞、空串 `%00`、路径布局），再实现百分号编码
- [x] 3.2 `MQConfig` / `MQConfigException`：先写 `MQConfig_test.cj`（默认值、逐项覆盖、负数 backup、selfIndex、端口缺失/重复、阈值 0、help 文本含 10 项），再实现
- [x] 3.3 `MQUsage`：先写 `MQUsage_test.cj`（顶层含 server/manager、serverHelp 含全部配置、managerHelp 含六子命令与 `--server`），再实现

## 4. `fmq` 存储

- [x] 4.1 `QueueLog` 读取适配：先写 `QueueLog_test.cj` 第 1 批（从位置读、跨段、跳过预分配、未知段抛异常、流快照、`readAt`、`size` 取段元数据），再实现 `openFrom/readAt/segments/size`
- [x] 4.2 `QueueLog` 写入/重启：先写第 2 批（位置单调、与 `logMetas` 一致、重启开新段、重启 size 不变、轮转、空日志、每条 fsync 可读），再实现 `init/append/sync/close`
- [x] 4.3 `QueueManager`：先写 `QueueManager_test.cj`（只建本地队列、目录布局、轮转、无队列、删文件、保留文件、`allLogs`），再实现
- [x] 4.4 `CursorStore`：先写 `CursorStore_test.cj`（往返、缺失、1000 次覆盖无 `.tmp`、按主题清理、默认组），再实现
- [x] 4.5 `DeadLetterQueue`：先写 `DeadLetterQueue_test.cj`（写入迭代、从中间读、按 `updateTime` 清理、保留新段、重启完整），再实现
- [x] 4.6 回归：`cd fmq && cjpm test`（或测试模块）全绿

## 5. `fmq` 消费语义

- [x] 5.1 `MQMatcher`：先写 `MQMatcher_test.cj`（主题精确、空 tags、子集无序、缺 tag、重复 tags、空 filter、过滤器真/假、未注册对象 BODY），再实现按 topic → tags → filter 短路
- [x] 5.2 `DeliveryRecord` + `GroupCursor`：先写 `GroupCursor_test.cj` 全部场景（顺序投递、确认推进、乱序留洞、超时重投、超阈值死信、autoAck、不匹配跳过、分配给他人、`release`、`sweep`、无匹配暂停、位点恢复、重启重投、流重开、段被删跳过、`references`、并发），再实现四步算法
- [x] 5.3 `SubscriberRegistry`：先写用例（登记/查询、幂等、注销、按组隔离、按连接清理、按主题/组清理、并发），再实现双索引 + `Mutex`
- [x] 5.4 `ConsumeService`：先写用例（匹配返回、空返回 None、同组不重复、错误订阅 ack、已越过 ack、BODY 只解一次、注销释放），再实现游标懒建缓存
- [x] 5.5 回归：`cd fmq && cjpm test` 全绿

## 6. `fmq` 元数据与集群

- [x] 6.1 `MQAssignment`：先写 `MQAssignment_test.cj`（规格三节点例子逐字复现、单节点、单队列、环绕、非法队列数、`ownersOf`），再实现纯函数
- [x] 6.2 `MetaStore`：先写 `MetaStore_test.cj`（持久化重载、重复、默认组、删主题级联、快照、指针推进、坏文件跳过、原子写、并发），再实现
- [x] 6.3 `NodeRegistry`：先写 `NodeRegistry_test.cj`（自身/计数、环形后继、backup=0、自身返回 None、懒建缓存、存活标记、地址反查），再实现
- [x] 6.4 `MetaSyncer`：先写 `MetaSyncer_test.cj`（注册分配并广播、重复、组广播、删除广播、幂等不转发、冲突保留先到、启动合并、全不可达、快照内容），再实现
- [x] 6.5 `BackupReplicator`：先写 `BackupReplicator_test.cj`（backup=0、环形目标、按条数/时间 flush、溢出丢弃、单节点故障、关闭 flush），再实现
- [x] 6.6 `LogCleaner`：先写 `LogCleaner_test.cj`（删超期、保留新段、保留游标引用、死信独立 TTL、当前段不删、返回条数），再实现
- [x] 6.7 回归：`cd fmq && cjpm test` 全绿

## 7. `fmq` 服务运行时

- [x] 7.1 `main` / `dispatch`：先写 `Main_test.cj`（`server --help`、`manager --help`、空参数返回 2、未知子命令返回 2、`server` 调用装配点），再把 `main` 抽成可测 `dispatch`
- [x] 7.2 `MQCommandExecutor`：先写 `MQCommandExecutor_test.cj` 全矩阵（注册回分配、非法主题、注销、主题不存在、非 owner、原样落盘、16KB 大记录、备份入队、未注册组、订阅消费确认闭环、空消费、`ACK_UNKNOWN`、metaSync 快照、备份只存不投递、垃圾载荷），再实现分派
- [x] 7.3 `MQServer` 装配：先写 `MQServer_test.cj`（绑定并接受、负数 backup 拒绝、未知自身拒绝、无 peer 仍启动、只开本地队列、关闭释放端口、重启恢复消费），再实现 `build()` 与 `run()`
- [x] 7.4 回归：`cd fmq && cjpm test` 全绿
- [x] 7.5 手工冒烟：单节点起服务 → 用 `f_mq` 客户端完成注册、发布、订阅、消费、ack（记录命令与输出）
  > 结论：已用真实 `fmq server` 进程 + `fmq manager` + e2e 客户端完成注册、发布 3 条、订阅、消费 3 条；三节点脚本另见 9.x。

## 8. `fmq` 管理端

- [x] 8.1 `MQManagerArgs`：先写 `MQManagerArgs_test.cj`（`--server` 前置/后置、默认端口、六命令参数校验、`--help`、非法子命令），再实现解析
- [x] 8.2 `MQManagerOutput`：先写用例（CJK 宽度对齐、空结果「（空）」、错误前缀），再实现
- [x] 8.3 `MQManager`：先写 `MQManager_test.cj`（注册并打印分配、注册组后列出、列表队列数、删主题后发布失败、删组后订阅失败、不可达返回 1、help 含六命令），再实现六子命令
- [x] 8.4 回归：`cd fmq && cjpm test` 全绿；手工跑一遍六个子命令

## 9. 端到端与交付

- [x] 9.1 建 `scripts/mq_e2e.sh`：起 3 个 `fmq server`（独立 metas/log/deadmsg 目录，`mqServer_backup=1`），用 manager 注册 `/e2e` 4 队列与 `grp1`/`grp2`
- [x] 9.2 脚本客户端步骤：`grp1` 订阅并消费 100 条并 ack；`grp2` 以 `autoAck=true` 订阅并消费
- [x] 9.3 脚本断言：100 条不重不漏（按 `(topic, messageId)` 集合）；停掉一个节点后仍可发布/消费；不 ack 的消息在 `ackTimeout` 后重投并最终进死信目录；`autoAck` 组无需 ack 即推进
- [x] 9.4 判据：脚本输出 `E2E_OK`，失败时逐项列出失败断言；记录吞吐、重投次数、死信条数（发布 100 条 5377ms、消费 100 条 11809ms、重投 3 次、死信条目 1）
- [x] 9.5 文档：`f_mq/README.md` + `README_en.md`、`fmq/README.md` + `README_en.md`
- [x] 9.6 仓库元数据：根 `README.md` / `README_en.md` 模块表、`CHANGELOG`、`.modules` 的 `[include]`
- [x] 9.7 依赖图重生成：`python docs/模块依赖图/extract_deps.py` → `gen_layered_svg.py` / `gen_matrix_svg.py`
- [x] 9.8 提交前检查：换行符归一（LF）、一次提交只做一类改动（代码 / 文档）、按任务独立提交

## 10. verify 修复（2026-10-18）

> 来源 `verify-report.md`；用户确认修复 C1–C3 + W1–W3。每步仍按 Red → Green → Refactor → 回归。

- [ ] 10.1 协议字段 `queueIndex`：先写 `MQProtocol_test` 的 `MQConsumeResult`/`MQAckPayload` 四字段往返用例，再给 `MQConsumeResult`、`MQAckPayload`、`MQMessage` 加 `queueIndex`，更新 `toMessage` 与所有构造点
- [ ] 10.2 客户端 ACK 路由：先写「两队列同位置不串台」用例，再把 `MQSubscription.deliveries` 键改为 `queueIndex:index:offset`，`ack` 载荷携带 `queueIndex`
- [ ] 10.3 服务端 ACK 精确定位：先写「错 queueIndex → `ACK_UNKNOWN`」与「两队列同位置只确认目标队列」用例，再改 `ConsumeService.ack` 按 `(topic, queueIndex, group)` 取游标，删除遍历兜底
- [ ] 10.4 `MQMatcher` 三态：先写 `Match/NoMatch/Unsupported` 用例（未注册对象 BODY + 非空 filter），再改返回类型与调用点
- [ ] 10.5 发布 `FILTER_UNSUPPORTED_BODY`：先写「对象 BODY + 非空 filter → 发布报错且不落盘」「空 filter → 正常发布」用例，再改 `MQCommandExecutor.onPublish` 的落盘前检查
- [ ] 10.6 `GroupCursor` 段失效恢复：先写「删除 committed 所在段后继续消费」「全部段删除返回 None」用例，再实现跳最老段、重置并落盘
- [ ] 10.7 死转活重同步：先写 `NodeRegistry.markSeen` 的 `false → true` 回调一次用例，再接线 `MetaSyncer.syncFromPeers`
- [ ] 10.8 端口唯一性：先写「非本机端口重复也拒绝启动」用例，再改 `MQConfig.validate`
- [ ] 10.9 `BackupStore` 并发：先写 4 线程同 `(owner,topic,queue)` 只创建一个 `QueueLog` 的用例，再给 get-or-create 加锁
- [ ] 10.10 E2E 扩展：在现有 4 队列拓扑上增加「两队列同位置 ACK 后不重复投递、不丢消息」断言；脚本仍输出 `E2E_OK`
- [ ] 10.11 回归与文档：`f_io` / `f_mq` / `fmq` 全量 + E2E；README/CHANGELOG 补充 `queueIndex` 与 `FILTER_UNSUPPORTED_BODY` 行为

## 验收清单

- [x] `f_io` 全量测试通过（20/20，可见性改动无回归）
- [x] `f_mq` 全量测试通过（77 项：base + client + 门面）
- [x] `fmq` 全量测试通过（138 项，`cjpm test` 直接可用）
- [x] `scripts/mq_e2e.sh` 输出 `E2E_OK`
- [x] 六个管理子命令在进程内真实服务上可用，错误路径返回非 0
- [x] 中英文文档、CHANGELOG、`.modules`、依赖图均已更新
- [x] 已知限制写入文档：at-least-once、无自动故障转移、manager 无强隔离、对象 BODY 过滤器限制
- [ ] 两队列同位置 ACK 不串台；错 `queueIndex` 返回 `ACK_UNKNOWN`
- [ ] 未注册对象 BODY + 非空 filter 发布返回 `FILTER_UNSUPPORTED_BODY`，不落盘
- [ ] 删除 `committed` 所在段后消费恢复；全部段删除返回空
- [ ] 死转活重同步、任意节点端口重复拒绝启动、`BackupStore` 并发只创建一个实例
- [ ] `opsx:verify` 重新校验无 critical

## 依赖与并行

- 阶段 0 必须先于一切。
- 阶段 1 必须先于阶段 2 与阶段 3–6（后两者只依赖 `f_mq.base`）。
- 阶段 2 与阶段 3–6 可并行。
- 阶段 7 依赖阶段 2（节点互连）与阶段 3–6（组件就绪）。
- 阶段 8 只依赖阶段 1 与 `f_net`，可与阶段 7 并行；其集成用例需要阶段 7 提供的服务。
- 阶段 9 依赖全部前置阶段。
- 阶段 10 依赖阶段 9；完成后需重新跑 `opsx:verify`，无 critical 才能 archive。
