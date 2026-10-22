# R2: f_mq 客户端层（连接 / 路由 / 订阅-消费-ack / 资源释放）

审查时间：2026-10-21 06:58
审查基线：HEAD `5a133474`（全树审计，非 diff）

### 审查范围

代码：

- `f_mq/src/f_mq.cj`（门面）
- `f_mq/src/client/MQClient.cj`、`MQClientConfig.cj`、`MQNodePool.cj`、`MQSubscription.cj`、`MQOwnershipCache.cj`
- `f_mq/src/client/MQClientConfig_test.cj`、`MQOwnershipCache_test.cj`
- `f_mq/src/client/test/MQClient_test.cj`、`MQNodePool_test.cj`、`MQStubServer.cj`
- `f_mq/src/exception/MQException.cj`、`MQException_test.cj`
- `f_mq/src/test/Facade_test.cj`
- 依赖参照：`f_net/src/client/client.cj`（重连/关闭语义）、`f_config/src/Config.cj:188`（`getStringArray`）
- 覆盖证据参照：`scripts/mq_e2e.sh`（停机段 173–186 行）

文档：

- `f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/client/spec.md`
- `f_mq/doc/详细设计.md` §5.12–5.17、§6.1–6.7、§8
- `f_mq/doc/spec/add-fmq-message-queue/tasks.md` §2
- `f_mq/README.md`、`f_mq/README_en.md` 客户端章节

### 发现

#### [F1] [严重] 节点连接一次性使用，故障后永不重建（重连链路缺失）

- **位置**：`f_mq/src/client/MQNodePool.cj:68-75`（`clientOf` 命中已关闭 `Client` 时直接抛异常），配合 `f_mq/src/client/MQNodePool.cj:110-114`（`aliveNodes` 把已关闭连接视为死亡）；`f_mq/src/client/MQNodePool.cj:79-89`（`clients[nodeIndex]` 只在首次创建时写入，此后无任何重建路径）
- **现象**：`MQNodePool` 对每个节点只创建一次 `Client<DataAny>`，一旦该 `Client.isClosed()` 为真，`clientOf` 永久抛 `MQConnectionException`，`clients[nodeIndex]` 也不会被清空重建。而 `f_net` 的 `Client` 在全部 `SocketBuffer` 关闭后的心跳轮次会自行 `close()`（`f_net/src/client/client.cj:171-181`），且 `close()` 后 `transfer` 直接返回 `None`（`f_net/src/client/client.cj:270-277`）。也就是说：节点重启或网络中断超过 3 个心跳周期（`checkDuration=30s`，见 `MQNodePool.cj:97`）后，`Client` 自我关闭 → MQ 侧永久放弃该节点，直到整个 `MQClient` 重建。
- **影响**：`详细设计.md:531` 明确承诺「心跳/重连/失败容忍全部复用 `f_net` 内建实现」，但 MQ 侧的 `clientOf` 恰好把 `f_net` 的重连能力截断，实际行为是「一次下线 = 永久下线」。滚动重启、短暂网络抖动后客户端容量永久缩水；若该节点是某订阅的唯一 owner，`consume` 将永远取不到消息（叠加 G1）。现有用例（含 e2e `scripts/mq_e2e.sh:173-186`，停机后 1 秒内即验证）都在重连窗口之内，无法暴露此缺陷。
- **建议**：`clientOf` 的 `case Some(c)` 分支在 `c.isClosed()` 时把 `clients[nodeIndex]` 置为 `None` 并走 `createClient(nodeIndex)` 重建（重建失败仍抛 `MQConnectionException`）；`aliveNodes` 同理不再把「已关闭且无法重建」的节点当作可用。补充用例：桩服务端关闭 → 等待 `Client` 关闭（或直接注入已关闭的 `Client`）→ 重启桩 → 断言 `publish`/`consume` 恢复可用。若产品上确实不做重连，则应删除 `详细设计.md:531` 的重连承诺并在 README「语义与限制」中写明「节点下线后需重建 MQClient」。

#### [G1] [一般] 全部 owner 不可达时 `consume` 永久静默空转，不抛连接异常

- **位置**：`f_mq/src/client/MQClient.cj:164-197`（`while (true)` 内对每个 owner 调用 `transferOf`，`None` 时只 `continue`），`f_mq/src/client/MQClient.cj:280-286`（`transferOf` 把连接异常吞成 `None`）
- **现象**：所有 owner 都拒绝连接时，每轮耗时为 `N × 1s`（`CONSUME_TIMEOUT`）+ 200ms，循环永不退出，也不抛出任何异常。
- **影响**：`详细设计.md:500` 规定「`consume` … 连接类故障抛出 `MQConnectionException`」，实现与该设计矛盾；调用方（`scripts/mq_e2e_client`、业务侧）无法区分「暂时没有消息」与「集群全挂」，只能靠外部超时兜底，且故障期间无任何日志。与 F1 叠加后，`consume` 会成为不可恢复的挂死点。
- **建议**：记录每个 owner 的连接失败次数，当「本轮所有 owner 均为连接失败（而非正常空结果）」达到阈值时抛 `MQConnectionException`；或按 `详细设计.md:642` 的 Q4 增加 `consume(id, timeout!)` 重载并区分超时原因。补充「全节点不可达的 consume」用例。

#### [G2] [一般] `ack` 静默忽略全部失败与全部错误码

- **位置**：`f_mq/src/client/MQClient.cj:208-220`
- **现象**：`ack` 先 `sub.deliveries.remove(...)` 再 `transferOf(...)`，返回值被丢弃（`:214`、`:217`）；广播分支同样丢弃。既未区分 `ACK_UNKNOWN`（设计允许忽略，`详细设计.md:604`）与 `INTERNAL`/连接失败，也不向调用方返回结果；映射条目在发送前已删除，失败后无法重试定位。
- **影响**：ack 丢失时调用方完全无感知，消息只能等待服务端 ack 超时重投，表现为「重复消费」，排查时没有任何线索；与「忽略 `ACK_UNKNOWN`」的规格要求（`spec.md:121-123`）相比，实现放宽成了「忽略一切」。
- **建议**：解析响应，仅 `ACK_UNKNOWN` 静默；连接失败或其它错误码至少记录日志，或通过返回值（如 `Bool`/抛 `MQConnectionException`）上报。补一条「ack 发送失败」用例（桩返回 `None` 或 `INTERNAL`）。

#### [G3] [一般] `unsubscribe` 忽略发送结果，服务端订阅可能残留

- **位置**：`f_mq/src/client/MQClient.cj:229-240`（`:231` 先 `subscriptions.remove`，`:237-239` 逐个 `transferOf` 且不检查）
- **现象**：本地订阅先被删除，再向 owner 发送 `UNSUBSCRIBE`，任一发送失败（超时/断链）都不会重试、不会抛错；失败后本地已无该订阅，调用方也无法补发。
- **影响**：服务端 `SubscriberRegistry` 会留下孤儿订阅，直到该连接断开才被清理（`fmq/src/server/MQCommandExecutor.cj:268-280`），期间该订阅仍占用组游标/参与分配，造成「已退订仍在消费位点上推进」的假象，且客户端无任何途径感知。规格要求 `unsubscribe` 至少幂等成功（`spec.md:147-149`），未要求容错，但这属于错误处理不足。
- **建议**：收集失败节点，返回/记录失败清单（或抛异常并保留订阅以便重试）；至少 `log.warn`。补一条「UNSUBSCRIBE 发送失败」用例。

#### [G4] [一般] `subscribe` 回滚路径同样忽略失败，回滚可能不完整

- **位置**：`f_mq/src/client/MQClient.cj:147-152`（`rollback` 内 `transferOf` 返回值丢弃）
- **现象**：`GROUP_NOT_EXIST`/`TOPIC_NOT_EXIST` 时向已接受节点补发 `UNSUBSCRIBE`，失败被静默吞掉；`fatal` 只保留最后一个错误，`break` 后未尝试的节点也不会再收 `UNSUBSCRIBE`（这些节点本未接受，无影响）。
- **影响**：回滚失败时服务端残留订阅，与 G3 同源；`spec.md:82-85` 只断言「向节点 0 发送 `UNSUBSCRIBE`」，用例 `MQClient_test.cj:200-221` 也只断言条数，无法发现回滚失败。
- **建议**：`rollback` 返回失败节点并在异常信息中附带（或记录日志）。

#### [G5] [一般] 客户端零日志：所有链路异常被无条件吞掉，解码失败的消息静默丢弃

- **位置**：`f_mq/src/client/MQClient.cj:280-286`（`catch (_: Exception) { None }`）、`:173-194`（`asConsumeResult` 返回 `None` 或 `MQMessageRecord.decode` 返回 `None` 时直接 `continue`）
- **现象**：`MQClient.cj` 整个文件没有任何 `LoggerFactory`；连接拒绝、超时、协议解码失败、记录解码失败全部表现为「没拿到消息」，无日志、无异常、无返回值区分。`autoAck = true` 时服务端在投递时已推进游标，客户端解码失败即真丢消息。
- **影响**：`f_net` 侧有完整日志，唯独 MQ 客户端把异常统一抹平，线上排障只能看到「消费很慢」；`spec.md:94-97` 只规定「空 `record` 换下一个 owner」，未覆盖「非空 `record` 但解码失败」，实现选择丢弃，属于未定义的静默数据丢失路径。
- **建议**：引入 `LoggerFactory` 记录节点不可达、响应解析失败、记录解码失败（含 topic/位置）；解码失败应对 `autoAck = false` 记录一条警告并明确是否算作已投递；对 `autoAck = true` 的解码失败考虑直接抛 `MQException`（避免静默丢失）。补一条「服务端返回损坏 record」用例。

#### [G6] [一般] 建连在节点池全局锁内同步进行，一个慢节点阻塞所有节点

- **位置**：`f_mq/src/client/MQNodePool.cj:67-76`（`synchronized(lock)` 内调用 `createClient`）→ `:91-100`（`buildClient` → `Client.builder(...).build()`）→ `f_net/src/client/client.cj:378-386`（`build()` 内 `newSocket()` → `TcpSocket(address).connect()` 同步建连）
- **现象**：首次访问某节点会在池锁内完成 TCP 连接（含 DNS 与 SYN 等待）；连接不可达主机的超时可达数十秒。
- **影响**：多线程并发 `publish`/`consume` 时，只要有一个节点首次建连卡住，全部节点（含健康节点）的请求都会被阻塞在 `clientOf` 的锁上，客户端整体停顿。现有用例只覆盖 `127.0.0.1:1`（本地立即 `ECONNREFUSED`，`MQClient_test.cj:154-164`、`MQNodePool_test.cj:58-69`），无法暴露。
- **建议**：把 `createClient` 移出临界区（双检锁 + 连接中占位，如 `Map<Int64, CompletableFuture>` 语义），或先建连后加锁发布；至少为建连设置显式 `connect` 超时。

#### [G7] [一般] 全部节点回 `NOT_OWNER` 时错误分类为连接异常

- **位置**：`f_mq/src/client/MQClient.cj:87-95`（`NOT_OWNER` → `invalidate` + `continue`，循环结束后统一 `throw MQConnectionException("cannot publish to any node of topic ...")`）
- **现象**：链路完全正常但所有节点都认为自己不是 owner（节点表配置漏了持有队列的节点、重平衡窗口）时，抛的是 `MQConnectionException`。
- **影响**：调用方会把「拓扑不认识该主题」误判为「网络故障」而做无意义的重试/降级；`spec.md:29-30` 只约定「全部节点不可达 → `MQConnectionException`」，未约定全 `NOT_OWNER` 的语义，实现把两种情形合并了。
- **建议**：区分两种终态：全 `NOT_OWNER` → 抛 `MQServiceException(NOT_OWNER, ...)`（或 `MQException` 说明「无节点持有该主题」），全不可达 → `MQConnectionException`。补一条「全节点 `NOT_OWNER`」用例。

#### [G8] [一般] `publish` 未做 tags 校验，与客户端规格矛盾

- **位置**：`f_mq/src/client/MQClient.cj:68-77`（只校验 `MQTopic.isValid(topic)`，随后直接 `MQMessageRecord.encode(topic, tags, ...)`）
- **现象**：`spec.md:28` 要求「`publish<T>(topic, body, tags!)` SHALL 先在本地校验主题与 tags」，实现只校验 topic；`f_mq/src/base` 中也无任何 tags 校验函数（`MQMessageRecord.encode` 直接编码）。
- **影响**：规格中的能力缺失；同时 `spec.md` 未定义 tags 的合法性规则，实现与文档都无法判定「什么算非法 tags」，后续无论补齐校验还是修订文档都缺少依据。
- **建议**：先明确定义 tags 规则（空串、重复、长度/数量上限）并在 `f_mq.base` 提供 `MQTopic.isValidTags` 供客户端与服务端共用，再在 `publish`/`subscribe` 本地校验；若确定不需要，则修订 `spec.md:28` 删除「与 tags」。

#### [G9] [一般] `consume` 无客户端侧「认领」语义，并发用例无法验证规格要求

- **位置**：`f_mq/src/client/MQClient.cj:185-191`（拿到记录后仅 `deliveries.add(key, node)`，无去重/认领），`f_mq/src/client/test/MQClient_test.cj:533-569`（并发用例的桩按调用序号发唯一位置：`:539-540`）
- **现象**：`详细设计.md:617` 声称「`consume` 的『拿到即删』语义：同一 `(index, offset)` 不会被两个线程同时取出（在 `deliveries` 上用 `remove` 的返回值判定归属）」，实现里既没有 `remove` 也没有去重；并发用例的桩每次都返回新位置，因此无论客户端是否去重，`seen.size == 200` 恒成立。
- **影响**：`spec.md:175` 的「同一 `(segmentedIndex, segmentedOffset)` 不得被两个线程同时认领」在客户端层没有实现，完全依赖服务端串行化；一旦服务端在重投窗口内重复投递同一位置（at-least-once 的正常情形），两个消费者线程可同时拿到同一条消息，符合规格字面却未被拦截。同时该用例给出的是虚假保证——删除客户端任何逻辑它仍然通过。
- **建议**：二选一：① 实现认领（`deliveries` 用 `addIfAbsent` 判定归属，已认领则丢弃并继续轮询），并让并发用例的桩**故意**重复投递相同位置以验证去重；② 明确规格由服务端保证，删除 `详细设计.md:617` 的错误描述，并把并发用例改为桩重复投递 + 断言客户端不重复返回（否则该用例应删除或改写为「不同位置不串台」）。

#### [G10] [一般] 关键失败路径与规格场景缺用例（覆盖缺口清单）

- **位置**：`f_mq/src/client/test/MQClient_test.cj`（全文 17 个 `@TestCase`）、`f_mq/src/client/test/MQNodePool_test.cj`、`f_mq/src/client/MQClientConfig_test.cj`
- **现象**：以下规格场景/关键分支在客户端用例集中完全没有对应用例：
  1. `spec.md:77-80`「节点 0 成功、节点 1 回 `NOT_OWNER` → owner 集合为 `[0]`，`consume` 只向节点 0 请求」——无（`MQClient.cj:123-124` 的 `NOT_OWNER` 跳过分支未被执行）；
  2. `spec.md:65`「所有节点都非 owner / 都不可达 → `MQConnectionException`」——`subscribe` 侧无（`MQClient.cj:137-139` 无覆盖）；
  3. `spec.md:182-186`「一个线程 `close()`、其它线程持续调用公开 API」——无（`closeIsIdempotentAndBlocksApis:497-531` 是单线程顺序调用）；
  4. `publish` 的 5s 超时回退路径（`MQClient.cj:77-79` 收到 `None` 后换下一节点）——无：没有任何用例让桩「不响应」，`allNodesUnreachable…` 走的是建连失败；
  5. `consume` 中 `ERROR` 且 code ≠ `SUBSCRIBE_NOT_EXIST` 的跳过分支（`MQClient.cj:179`）——无；
  6. `consume` 中记录解码失败分支（`MQClient.cj:185` 的 `if (let Some(content) <- ...)` 为 `None`）——无；
  7. 节点故障恢复（F1）——无（e2e 的停机段在重连窗口内，见 `scripts/mq_e2e.sh:173-186`）；
  8. `MQClientConfig` 非法 `host:port` 项（`spec.md:21-24`、`tasks.md:39` 声称已测）——无，`MQClientConfig_test.cj` 只测了空串。
- **影响**：上述分支全部为 `if/else` 中的失败路径或规格显式场景，当前 17 条用例均只覆盖 happy path（+ 少量显式错误码），一旦实现回退到「只跑通主流程」不会被任何用例拦住；`MQClient.cj` 中至少 6 个分支零覆盖。
- **建议**：按清单逐条补用例；桩已支持返回 `None`（`MQStubServer.cj:41` 的 `responder` 返回 `?Message`），实现超时/静默场景成本很低。

#### [G11] [一般] 任务清单虚报用例文件与用例内容

- **位置**：`f_mq/doc/spec/add-fmq-message-queue/tasks.md:39`（2.1 声称「`host:port` 解析、非法项」已测）、`:42`（2.4 声称 `MQClientPublish_test.cj` 且含「多 tags 顺序」）、`:44`（2.6 声称含「对象 BODY」）、`:45`（2.7 声称 `MQClientLifecycle_test.cj` 且含「关闭与调用并发」）
- **现象**：实际不存在 `MQClientPublish_test.cj` / `MQClientLifecycle_test.cj`，全部并入 `MQClient_test.cj`；「非法项解析」「对象 BODY」「关闭与调用并发」三处用例均不存在；「多 tags」用例只用了 2 个 tag（`MQClient_test.cj:74`），与 `spec.md:35` 的「10 个 tags」不符。
- **影响**：任务清单是验收依据，标 `[x]` 的条目与实际测试资产不一致，后续按清单核对覆盖度会得出错误结论（这也是本轮 R6 需求-实现-用例矩阵的直接污染源）。
- **建议**：修订 `tasks.md:38-45` 与实际用例一一对应（或补齐缺失用例后再勾选）。

#### [G12] [一般] 详细设计 §5.13–5.15/§6.2 的签名与行为描述已与实现漂移

- **位置**：`f_mq/doc/详细设计.md:490`（`ack(subscribedId, segmentedIndex, segmentedOffset)` 缺 `queueIndex`）、`:514`（`deliveries: ConcurrentHashMap<Int64, Int64>`，实际为 `ConcurrentHashMap<String, Int64>` 且键含 `queueIndex`，见 `MQSubscription.cj:37,51-53`）、`:524`（`MQNodePool.init(hosts, checkDuration, pingTimeout)`，实际只接受 `hosts`，见 `MQNodePool.cj:36`）、`:570-571`（publish「目标节点 = 缓存第一个可用节点」+「`NOT_OWNER` 缓存并集修正」，实际为 `candidateNodes` 全序 + 用 `[node]` 覆盖缓存，见 `MQClient.cj:84,289-307`）
- **现象**：`queueIndex` 的引入（`tasks.md:115` 记录的正是一次有意的 ACK 串台修复）没有回写到详细设计，`MQNodePool` 构造签名与 `MQOwnershipCache` 的 TTL 注入也未回写；`publish` 的「并集修正」实现为「整体失效 + 单节点覆盖」，行为描述不成立。
- **影响**：`详细设计.md` 是本模块唯一成体系的设计文档，签名级漂移会让后续按文档实现的调用方直接编译失败（`ack` 少一个参数即歧义），并误导对路由优先级的理解。
- **建议**：同步 §5.13–5.16 与 §6.2 到当前实现（`ack` 四参、`deliveries` 键含 `queueIndex`、`MQNodePool.init(hosts)`、`publish` 的候选顺序与缓存覆盖语义）。

#### [G13] [一般] `MQClientConfig_test` 泄漏全局配置，且未验证「配置缺失」与「非法项」

- **位置**：`f_mq/src/client/MQClientConfig_test.cj:28`（`Config.set([(MQConfigKey.CLIENT_HOSTS, ...)])`，用例结束不还原）、`:34-43`（只覆盖空串）
- **现象**：`Config` 是进程级静态状态（`f_config/src/Config.cj`），两条用例写入后不清理，后续任何依赖 `MQClient()`（无参构造，`MQClient.cj:56-58`）的用例都会读到上一个用例残留的 `127.0.0.1:2351`，测试结果与执行顺序相关；`spec.md:16-19` 的「配置缺失」与 `spec.md:21-24` 的「非法地址」两个场景均无用例。
- **影响**：测试隔离性缺陷 + 规格场景未覆盖；并行执行 `cjpm test` 时可能出现偶发失败或静默使用错误节点表。
- **建议**：用例 `finally` 中恢复原值（或按 `Config` 既有清理 API 复位）；补「键不存在」「端口为 0 / 越界 / 缺端口」用例。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 1 |
| 一般 | 13 |
| 建议 | 8 |

建议级明细（不改变结论，仅列位置与要点）：

1. `MQClient.cj:198-199`：`while (true)` 之后的 `throw MQConnectionException("unreachable")` 为不可达代码，删除以免误导读代码的人。
2. `MQClient.cj:166-168`：`sub.owners.size == 0` 分支不可达（`subscribe` 保证 `accepted.size > 0` 才会建 `MQSubscription`，`MQClient.cj:137-142`），属防御性死代码。
3. `MQNodePool.cj:55-57` 的 `hostOf` 无任何调用方；`MQSubscription.cj:31-33` 的 `tags`/`filter` 在客户端侧只写不读（过滤在服务端做，`fmq/src/queue/MQMatcher.cj:107-113`），可删或注明用途。
4. `MQClient_test.cj:78-81`：`case PUBLISH(_) => @Assert(true)` 是空断言，建议改为断言 `request.command` 的实际形状（如 `is PUBLISH` 后取载荷校验），避免「只为让 match 穷尽」的占位。
5. `MQOwnershipCache.cj:58-66` 的 `clear()` 无用例；`MQOwnershipCache_test.cj:37-44` 的过期用例只断言返回 `None`，未断言条目已删除（`ownersOf` 内含 `entries.remove`，无覆盖）。
6. 测试文件放置不一致：`MQClientConfig_test.cj`、`MQOwnershipCache_test.cj` 直接位于 `f_mq/src/client/`（包 `fountain::f_mq.client`），其余用例在 `f_mq/src/client/test/`（包 `…client.test`），建议统一。
7. `MQSubscription.cj:37` 的 `deliveries` 只在 `ack` 时删除，不 ack 的投递会无限累积（长跑消费者 + 不 ack 场景），建议按订阅设置上限或在 `unsubscribe`/`close` 之外提供清理策略。
8. `MQClient.cj:117-132` 订阅向所有节点串行广播、每节点 5s 超时，最坏 `N × 5s`；节点较多时建议并发发送后再汇总（同时也能缩短 `SUBSCRIBE_TIMEOUT` 的实际等待）。

### 总评

客户端层结构清晰，职责划分合理（`MQClient` 只做编排，连接池、所有权缓存、订阅状态各自独立），公开 API 与 `spec.md`/README 的签名完全一致，异常族形态规整，`queueIndex` 进入 ack 键这一关键修复有专门用例保护，`MQStubServer` 这套进程内桩也让大部分路径可测——这些都达到较高水准。

主要问题集中在**故障路径**：连接只在建池时创建一次、失败即永久放弃（F1），叠加 `consume` 无连接失败退出条件（G1），使「节点短暂抖动」这个最常见的运维事件会演变为客户端永久失去该节点；ack/unsubscribe/rollback 三处把发送结果全部丢弃（G2–G4），使可靠性语义（at-least-once）在客户端侧没有可观测的失败面；`consume` 的并发规格要求既未实现也未真正验证（G9）。测试侧的问题同样明显：17 条用例覆盖了正常流与少数错误码，但 `NOT_OWNER` 聚合、全不可达订阅、关闭并发、publish 超时回退、解码失败等分支零覆盖，且 `tasks.md` 对用例资产的描述与实际不符（G10、G11）。

另需说明两点非缺陷事实，供后续轮次对齐：其一，客户端**没有服务发现**（节点表只来自构造参数或 `mqClient_hosts`，不拉取元数据快照），这与 `spec.md` 只要求静态节点表一致，不作为问题记录，但 README 未点明「节点表变更需重建客户端」；其二，客户端不做注册/主题管理（`详细设计.md:589` 已说明，属有意设计）。

整体评价：**可用但故障韧性不足**。建议优先修 F1（重连）、G1（consume 失败退出）、G2–G4（错误上报），再补齐 G10 的 8 条用例；其余为文档与整洁度问题，可随后续迭代处理。
