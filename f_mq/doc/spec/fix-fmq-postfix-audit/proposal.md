# Proposal: fix-fmq-postfix-audit

## Why

`reviews/202610211902_fmq-postfix-audit/todo.md`（来源 `review_v1.md`–`review_v5.md`，HEAD
`22c13ec4`）记录了 `f_mq` 与 `fmq` 的 77 项问题：6 项严重、71 项一般。与上一轮 `fix-fmq-full-audit`
不同，本轮问题集中在**语义边界**而不是功能缺失——功能都在，但边界条件给出的答案是错的：

- **公开 API 给出错误答案**：`MQProtocol.asPayload<T>` 对标量与字符串恒返回 `None`，与规格
  SHALL 相反；它还用 `SILENCE` 转换，字段漂移时会产出「字段全默认」的对象。同一个类里的
  `decodePayload` 却是严格模式，两个相邻 API 语义不对称。
- **墓碑只写不判**：`applyTopic` / `applyGroup` 从不查墓碑，已删除的主题/组会被迟到的低版本
  广播或旧 peer 快照复活；`applyTombstone` 在版本比较失败（墓碑输掉）时仍按 revision 删除本地
  条目，一次同 revision 竞争就能把活着的主题连同队列目录、游标、订阅一起清掉。
- **段末尾位点让队列永久停摆**：`committed = (seg, meta.size)`（排空到段尾的常态）在段封口或
  重启后会被当成「剩余 −4 字节」，每轮 `consume` 都 ERROR 且不前进；`stats` 以同一位置开流同样
  报 `INTERNAL`。
- **越界写**：`segmentedLogMaxSize` 与 `MAX_RECORD_SIZE` 无关联校验，段上限小于单条消息时
  `append` 直接 `mcopy` 越过 mmap 长度。
- **回归不可见**：管理端「服务端错误」与「载荷类型不符」两个 Scenario 的用例只断言退出码，
  而三条失败路径退出码都是 1；A65 的错误分类修复没有任何保护。
- **状态与边界腐化**：不可达分支、仅测试使用的生产符号、无消费者的协议字段、被编入生产源集的
  测试替身，以及规格/详细设计/README 之间四处互相矛盾（段恢复语义、退订幂等、kind 数量、具名
  参数示例）。

这些不是风格问题：前四项分别对应「错答、复活删除、永久停摆、进程崩溃」。本轮把它们收敛为
可验收的 delta 规格、技术方案与按 P0/P1/P2 分批的任务，实现阶段严格 TDD。

## What Changes

按 capability 拆分，每项变更都能对应到一条 Requirement 或一个明确的文档/测试任务：

1. **f-mq/protocol**
   - `asPayload<T>` 改为「运行时类型精确匹配 + `DEFAULT_DATA_FLAG` 严格转换」，与 `decodePayload`
     共用同一实现；标量/字符串命中返回 `Some`，异类/字段漂移返回 `None`。
   - 组名/标签/主题的字符约束覆盖 `0x7F`、Unicode 空白（U+00A0/U+3000 等），不再按 UTF-8 字节
     只判 `<= 0x20`。
   - 删除已废弃的「内部消息的两种 kind」场景，只保留三种 kind；延迟构造示例改为具名参数
     `delayingMs:`；`publishTime` 断言改为绝对 UTC 时刻；每个 `metaSync` 重载都有行为用例。
2. **f-mq/client**
   - `MQNodePool.clientOf` 在节点锁内二次检查 `closed`，`close()` 与建连不再产生泄漏连接。
   - `MQSubscription` 的字段要么进入日志/清理路径，要么删除；`MQFilter` 预编译结果不再挂在
     订阅上伪装成「客户端会二次过滤」。
   - 退订幂等改为「本地已成功退订的 id 再退订是成功空操作」，「从未见过的 id」才抛
     `MQServiceException`，两者用有界 `retired` 集合区分。
   - 补齐回滚失败、ack 失败可重试、10 个 tags、仅接受者 owner、对象 BODY 端到端、配置还原
     隔离等用例。
3. **fmq/metadata-cluster**
   - 接受判定统一为「墓碑也算一次带版本的变更」：条目必须严格新于同 key 墓碑才能落地；
     快照合并中被墓碑挡下的条目不得再被「缺失扫描」判成对端已删除。
   - `applyTombstone` 只在墓碑赢下 `isNewer` 时删除本地条目，输掉的墓碑不产生任何副作用。
   - 加载期按已落盘墓碑收敛；重新注册主题时移除墓碑；快照里的畸形条目不再触发本地删除。
   - 备份：部分目标失败按条重试；关闭时真正等当前批次并 drain；`states` 数量不一致与真实
     `acked` 推导补用例；组校验失败记 WARN（含失败字段）。
   - 清理器：单对象失败记 ERROR（含主题/队列/段），一轮结束汇总删除数/失败数。
4. **fmq/queue-storage**
   - 位点归一化：`offset >= meta.size` 时视为「该段已读完」，直接落到下一个现存段起点，不产生
     负剩余字节；这是 C1 的唯一修复点。
   - 记录上限与段上限建立约束：`effectiveMaxRecord = min(MAX_RECORD_SIZE, maxFileSize - 4)`，
     超限在写入前拒绝；`f_io.SegmentedLog.append` 增加「不越过段容量」的防御性检查；`append([])`
     拒绝零长度。
   - 零长度头改为「损坏」，损坏记录与「段被删除」用不同返回类型区分，损坏不得被静默确认。
   - 段缺失语义统一为「跳到最接近的更大段 + WARN」，并对同一位置的重复 WARN 限流。
5. **fmq/consume-semantics**
   - 与 queue-storage 统一「位点段被删」的唯一说法；`stats` 在 committed 段缺失时返回错误而不是
     偏小的 backlog。
   - 死信阈值改为「重试次数」语义：`deadMsgThreshold = 3` 对应 1 次首发 + 3 次重投，死信条目
     `deliverCount = 4`，与既有 Scenario 一致。
   - 跳过计数（不可读/无匹配/不支持）进入 `stats` 与指标，不再只存在于测试。
   - 延迟的「发布时间超前 5 分钟按到期处理」写入规格并补用例。
6. **fmq/server-runtime**
   - 启动顺序：先打开队列与定时器，最后开始监听；端口绑定不再早于装配完成。
   - `BackupStore` 关闭后写入记 DEBUG/WARN（限流），与规格一致。
   - `MQMetrics.bump` 改为原子 `compute`，删除主题/组与在途消费并发时不抛异常。
   - 生产产物与测试替身划界：`MQStubServer`、`TestDirs` 改为 `*_test.cj`，测试替身不得进入
     动态库/可执行文件。
   - 补齐命令矩阵 6 条错误分支、`port = 0`、发布触发备份、退出钩子、关闭 `queues.sync`、
     进程级 `Config` 隔离等用例。
7. **fmq/manager-cli**
   - 输出可注入、可断言：每个用例同时断言退出码与输出文本；服务端 ERROR、非快照响应、
     真正连不上三条路径的文案互斥。
   - 渲染层解析失败（如 `delaying` 非数字）归类为「响应格式不正确」，不得兜底成「无法连接」。
   - 本地校验（组名、配置缺失）在发请求前拒绝并可断言。
8. **fmq/metrics**
   - 计数器的「取值 + 自增」原子化；删除与读取并发安全。
   - `stats` TSV 增加三个跳过计数列，表头与渲染同步。
9. **docs**
   - 详细设计的字段表、签名、配置读取方式、断链清理机制、关闭顺序、`registerTopic` 参数与
     输出格式、子命令数量逐项对齐实现，并给出可 grep 的验收串。
   - README 依赖列表补全 10 个依赖；段恢复语义、`BackupStore` 丢弃策略、字符限制说明一致。
   - 规格自身四处矛盾收敛为单一权威表述；`开发计划.md` 不再引用幽灵用例文件。

**非目标**：

- 不改段文件、`.meta`、`.cursor` 的二进制格式；不新增 `f_protocol` 命令号。
- 不做跨节点事务、自动故障转移、备份自动接管、备份反熵补偿（仅保证「失败按条重试+关闭排空」）。
- 不重构 `f_io.SegmentedLog` 的存储模型（只补越界防御与位点归一化）。
- 不引入滚动升级兼容层：`MQMetaSnapshot` 删除 `tombstoneFloor` 会使新旧节点的快照线格式不同，
  集群按「同版本部署」处理，README 已知限制中说明。

## Capabilities

**Modified Capabilities**

- `f-mq/protocol`
- `f-mq/client`
- `fmq/metadata-cluster`
- `fmq/queue-storage`
- `fmq/consume-semantics`
- `fmq/server-runtime`
- `fmq/manager-cli`
- `fmq/metrics`
- `docs`

## Impact

| 范围 | 影响 |
|---|---|
| `f_mq/src/base/MQProtocol.cj` | `asPayload` 与 `decodePayload` 合并为严格读取；标量/字符串路径生效 |
| `f_mq/src/base/MQGroup.cj`、`MQTags.cj`、`MQTopic.cj` | 字符集判定改为按 `Rune` 分类（控制/空白/保留符号） |
| `f_mq/src/client/MQNodePool.cj` | 锁内二次检查 `closed`；关闭与建连串行化 |
| `f_mq/src/client/MQSubscription.cj`、`MQClient.cj` | 会话字段收敛；`retired` 有界集合；日志补 topic/id |
| `fmq/src/meta/MetaStore.cj` | 墓碑参与接受判定；删除判定改用 `isNewer`；加载收敛；注册清墓碑 |
| `fmq/src/cluster/MetaSyncer.cj` | 畸形条目不再触发删除；组校验 WARN；待补偿集清理 |
| `fmq/src/cluster/BackupReplicator.cj` | 按 target 重试、关闭 drain、移除空转 `flush()` |
| `fmq/src/queue/QueueLog.cj` | 位点归一化、记录上限、零长度判损坏、WARN 限流 |
| `fmq/src/queue/GroupCursor.cj` | 损坏与段缺失分流；死信阈值；跳过计数出口 |
| `fmq/src/server/MQServer.cj`、`BackupStore.cj`、`ConsumeService.cj` | 启动顺序、关闭留痕、`stats` 严格模式 |
| `fmq/src/server/MQCommandExecutor.cj`、`MQManager*.cj` | 错误分类、输出注入、本地前置校验 |
| `fmq/src/metrics/MQMetrics.cj` | 原子更新；跳过计数；TSV 列扩展 |
| `f_io/src/SegmentedLog.cj` | `append` 越界防御（行为由「内存破坏」变为「明确异常」） |
| `f_mq/src/client/test/MQStubServer.cj`、`fmq/src/test/TestDirs.cj` | 重命名为 `*_test.cj`，退出生产源集 |
| 文档 | `f_mq/README(.md/_en.md)`、`f_mq/doc/详细设计.md`、`f_mq/doc/开发计划.md`、`fmq/README.md`、`fmq/doc/详细设计.md` |

## 问题映射

> 编号沿用 `todo.md`：`R<轮>-S<严重序号>` / `R<轮>-G<一般序号>`。任务编号见 `tasks.md`。
> 落点使用「capability + Requirement 名称」；一条问题可以同时落到多条 Requirement。

### R1（1 严重 / 18 一般）

| 编号 | 摘要 | 落点 |
|---|---|---|
| R1-S1 | `asPayload` 对标量/字符串恒 `None`，转换标志相反 | `f-mq/protocol`「载荷读取的类型闸门与转换严格性」+ T1 |
| R1-G1 | `MQNodePool` 关闭与建连竞态 | `f-mq/client`「节点连接自愈」+ T7 |
| R1-G2 | `MQSubscription` 五字段不读、`MQFilter` 丢弃 | `f-mq/client`「客户端会话状态的最小集」「客户端可观测性」+ T8 |
| R1-G3 | §5.10 `MQMetaSnapshot` 缺三字段 | `docs`「设计文档与实现一致」「文档漂移清单逐项闭环」+ T28 |
| R1-G4 | §5.2 `MQSubscribeGroupMeta` 缺 `revision`/`origin` | `docs`「设计文档与实现一致」+ T28 |
| R1-G5 | `MQGroup`/`MQTags` 校验规则未文档化 | `docs`「模块限制说明可查」+ T28 |
| R1-G6 | `开发计划.md` 与现状不符、引用幽灵文件 | `docs`「任务台账真实」+ T28 |
| R1-G7 | 退订幂等场景与正文/实现矛盾 | `f-mq/client`「退订与生命周期」+ T7 |
| R1-G8 | 「两种 kind」与「三种 kind」并存 | `f-mq/protocol`「载荷按运行时类型分派」+ T10 |
| R1-G9 | `delayingMs` 示例为位置参数 | `f-mq/protocol`「主题延迟字段」+ T10 |
| R1-G10 | README 依赖列表不完整 | `docs`「README 与实际行为一致」+ T28 |
| R1-G11 | 配置还原不精确、用例依赖顺序 | `f-mq/client`「客户端配置与节点表」+ T11 |
| R1-G12 | 控制字符只判到 `0x20` | `f-mq/protocol`「组名、标签与主题的字符集约束」+ T9 |
| R1-G13 | 缺 `metaSync(MQDeregisterPayload)` 用例 | `f-mq/protocol`「协议工厂重载的行为覆盖」+ T10 |
| R1-G14 | 缺回滚失败可观测性用例 | `f-mq/client`「客户端关键路径的用例覆盖」+ T11 |
| R1-G15 | 缺 ack 发送失败可重试用例 | `f-mq/client`「客户端关键路径的用例覆盖」+ T11 |
| R1-G16 | `publishTime` 恒真/未切时区 | `f-mq/protocol`「messageId 发布时间解析」+ T10 |
| R1-G17 | 10 tags 顺序、仅接受者 owner 覆盖不足 | `f-mq/client`「客户端关键路径的用例覆盖」+ T11 |
| R1-G18 | 对象 BODY 端到端无用例 | `f-mq/client`「客户端关键路径的用例覆盖」+ T11 |

### R2（2 严重 / 11 一般）

| 编号 | 摘要 | 落点 |
|---|---|---|
| R2-S1 | 墓碑不参与接受判断，删除可被复活 | `fmq/metadata-cluster`「删除与接受的统一判定」+ T2 |
| R2-S2 | `applyTombstone` 比较失败仍删本地条目 | `fmq/metadata-cluster`「墓碑竞争的原子性」+ T3 |
| R2-G1 | 畸形快照条目被当成「对端已删除」 | `fmq/metadata-cluster`「元数据全量复制」+ T12 |
| R2-G2 | `load()` 不按落盘墓碑收敛 | `fmq/metadata-cluster`「元数据持久化与内存索引」+ T12 |
| R2-G3 | 清理器失败日志级别/粒度不符 | `fmq/metadata-cluster`「清理器异常隔离」+ T13 |
| R2-G4 | 单段删除失败/死信清理无用例 | `fmq/metadata-cluster`「清理器异常隔离」+ T13 |
| R2-G5 | `states` 与记录数不一致无用例 | `fmq/metadata-cluster`「备份副本的消费位点」+ T14 |
| R2-G6 | 真实 `acked` 推导无用例 | `fmq/metadata-cluster`「备份副本的消费位点」+ T14 |
| R2-G7 | 组载荷校验失败不记 WARN | `fmq/metadata-cluster`「远端元数据结构校验」+ T15 |
| R2-G8 | 备份部分目标失败不重试 | `fmq/metadata-cluster`「备份副本复制」+ T14 |
| R2-G9 | 备份 `close()` 只等 500ms | `fmq/metadata-cluster`「备份副本复制」+ T14 |
| R2-G10 | 重新注册不清理墓碑、随快照扩散 | `fmq/metadata-cluster`「删除与接受的统一判定」+ T15 |
| R2-G11 | 死代码 4 类 30 项 | 各 capability「受支持面」+ `fmq/server-runtime`「生产产物与测试替身的边界」+ T27 |

### R3（2 严重 / 12 一般）

| 编号 | 摘要 | 落点 |
|---|---|---|
| R3-C1 | 段末尾位点被判损坏、游标停摆 | `fmq/queue-storage`「段末尾位点归一化」+ T4 |
| R3-C2 | 记录大于段上限时越界写 | `fmq/queue-storage`「记录与段上限的联动约束」+ T5 |
| R3-M1 | 零长度头被当作干净结束 | `fmq/queue-storage`「记录边界格式与文档化」+ T16 |
| R3-M2 | 损坏记录被当成段被删除越过 | `fmq/queue-storage`「损坏记录与不可读记录的可观测性」+ T16 |
| R3-M3 | 「位点段被删」四种说法 | `fmq/consume-semantics`「离线组位点保留」+ `fmq/queue-storage`「读流恢复语义一致」+ T17 |
| R3-M4 | `stats` 部分段缺失静默少算 | `fmq/consume-semantics`「离线组位点保留」+ `fmq/metrics`「统计查询」+ T18 |
| R3-M5 | 死信阈值 off-by-one | `fmq/consume-semantics`「死信判定与按组隔离」+ T19 |
| R3-M6 | `append` 接受 0 长度记录 | `fmq/queue-storage`「记录与段上限的联动约束」+ T5 |
| R3-M7 | 详细设计 §5.8/§5.11/§5.12/§6.4/§6.5/§6.11 漂移 | `docs`「文档漂移清单逐项闭环」+ T28 |
| R3-M8 | 跳过计数生产不可见 | `fmq/consume-semantics`「跳过与不可读事件的统计暴露」+ `fmq/metrics`「跳过计数的指标口径」+ T18 |
| R3-M9 | 段缺失 WARN 未限流 | `fmq/queue-storage`「按位置顺序读取与有界快照」+ T17 |
| R3-M10 | 9 个关键场景缺口 | `fmq/consume-semantics`「关键场景的用例覆盖」+ T20 |
| R3-M11 | 6 类弱断言 | `fmq/consume-semantics`「关键场景的用例覆盖」+ T20 |
| R3-M12 | 未来 >5 分钟视为到期未文档化 | `fmq/consume-semantics`「延迟投递」+ T19 |

### R4（1 严重 / 21 一般）

| 编号 | 摘要 | 落点 |
|---|---|---|
| R4-S1 | 管理端两场景只断言退出码 | `fmq/manager-cli`「输出可断言」+ T6 |
| R4-G1 | 「响应格式异常」兜底成「无法连接」 | `fmq/manager-cli`「连接失败语义」+ T24 |
| R4-G2 | 启动顺序与规格相反、端口早绑定 | `fmq/server-runtime`「启动装配与关闭」+ T21 |
| R4-G3 | `BackupStore` 关闭后写入完全静默 | `fmq/server-runtime`「备份存储关闭并发安全」+ T22 |
| R4-G4 | `MQMetrics.bump` 非原子 | `fmq/metrics`「指标清理入口」+ T23 |
| R4-G5 | 断链清理文档写 `removeByBuffer` | `docs`「文档漂移清单逐项闭环」+ T28 |
| R4-G6 | 关闭顺序列表缺订阅表与 `queues.sync` | `docs`「设计文档与实现一致」「文档漂移清单逐项闭环」+ T28 |
| R4-G7 | §5 四组签名不符 | `docs`「文档漂移清单逐项闭环」+ T28 |
| R4-G8 | §3 配置读取方式不符 | `docs`「文档漂移清单逐项闭环」+ T28 |
| R4-G9 | 子命令「六/七」并存 | `fmq/server-runtime`「子命令分发」+ `docs`「README 与实际行为一致」+ T26/T28 |
| R4-G10 | §7 `registerTopic` 参数与输出格式不符 | `docs`「文档漂移清单逐项闭环」+ T28 |
| R4-G11 | 「默认值」「帮助文本」弱覆盖 | `fmq/server-runtime`「服务端配置项与默认值」+ T25 |
| R4-G12 | 「配置缺失」路径无用例 | `fmq/manager-cli`「本地前置校验与配置缺失」+ T24 |
| R4-G13 | 「发布触发备份」无用例 | `fmq/server-runtime`「服务端测试资产」+ T25 |
| R4-G14 | 「manager 不安装钩子」无用例 | `fmq/server-runtime`「服务端测试资产」+ T25 |
| R4-G15 | 「非绝对路径主题」无用例 | `fmq/manager-cli`「本地前置校验与配置缺失」+ T24 |
| R4-G16 | `stats` 三个 CLI 场景只断言退出码 | `fmq/manager-cli`「输出可断言」+ T24 |
| R4-G17 | 非法组名断言无法区分行为 | `fmq/manager-cli`「本地前置校验与配置缺失」+ T24 |
| R4-G18 | 关闭释放未断言 `queues.sync` | `fmq/server-runtime`「启动装配与关闭」+ T21 |
| R4-G19 | 测试共享进程级 `Config` | `fmq/server-runtime`「服务端测试资产」+ T25 |
| R4-G20 | 命令矩阵 6 条错误分支无用例 | `fmq/server-runtime`「命令处理矩阵」+ T25 |
| R4-G21 | `mqServer_port = 0` 分支无用例 | `fmq/server-runtime`「服务端配置项与默认值」+ T25 |

### R5（0 严重 / 9 一般）

| 编号 | 摘要 | 落点 |
|---|---|---|
| R5-1 | 管理端 11/12 用例只断言退出码 | `fmq/manager-cli`「输出可断言」+ T24 |
| R5-2 | 帮助文本漏测 2 项、不校验默认值 | `fmq/server-runtime`「服务端配置项与默认值」+ T25 |
| R5-3 | 测试替身被编入生产源码树 | `fmq/server-runtime`「生产产物与测试替身的边界」+ T27 |
| R5-4 | 退订幂等：承诺不抛、实现与用例都抛 | `f-mq/client`「退订与生命周期」+ T7 |
| R5-5 | 段恢复语义三份文档相反 | `fmq/consume-semantics`「离线组位点保留」+ `docs`「规格自身无矛盾」+ T17/T29 |
| R5-6 | 协议规格仍保留「两种 kind」 | `f-mq/protocol`「载荷按运行时类型分派」+ T10 |
| R5-7 | 延迟构造示例位置参数 | `f-mq/protocol`「主题延迟字段」+ T10 |
| R5-8 | `开发计划.md` 引用 4 个幽灵文件 | `docs`「任务台账真实」+ T28 |
| R5-9 | 主题墓碑重新注册后不删不标复活 | `fmq/metadata-cluster`「删除与接受的统一判定」+ T15 |

### 专项结论的追加落点

| 专项 | 追加问题 | 落点 |
|---|---|---|
| 死代码 | 完全死代码 6 个、仅测试 11 个、只写字段/无消费者 7 个、不可达分支 4 处、未使用 import 3 处 | 各 capability「受支持面」+ T27（逐项处置表见 `design.md` §4） |
| 打包 | `MQStubServer`/`TestDirs` 进生产源集，`MQStubServer` 为 `public` | `fmq/server-runtime`「生产产物与测试替身的边界」+ T27 |
| 文档一致性 | 门面 import 条数、`MQSubscription.cursor` 类型、`removeTopic` 返回类型、`NodeRegistry` 公开面（`self`/`selfIndex`、缺 `isKnownDead`/`onRevived`）、`CursorCatalog` 无小节 | `docs`「文档漂移清单逐项闭环」+ T28 |
| 规格矛盾 | 「位点段被删」四种说法、退订幂等、kind 数量、具名参数 | `docs`「规格自身无矛盾」+ T29 |
| 台账 | `tasks.md` V9/26.1/W12/W29 勾选不实 | `docs`「任务台账真实」+ T28 |
