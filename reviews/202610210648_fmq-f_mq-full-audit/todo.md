# f_mq / fmq 审查问题清单（严重 + 一般）

来源：`reviews/202610210648_fmq-f_mq-full-audit/review_v1.md` ~ `review_v6.md`（对应 R1–R6）
整理口径：仅收录「严重」与「一般」；保留题目、位置、描述，忽略建议。

## R1

### [严重] 超过 4096 字节的记录经「对象载荷」传输时被静默降级为空数组——大消息永远消费不到

- **位置**：
  - `f_mq/src/base/payload/MQConsumeResult.cj:32`（`private var record: Array<Byte> = []`）
  - `f_mq/src/base/payload/MQBackupPayload.cj:28`、`f_mq/src/base/payload/MQInternalMessage.cj:32`、`f_mq/src/base/payload/MQDeadLetterMessage.cj:35`
  - `f_mq/src/base/MQProtocol.cj:189-191`（`asConsumeResult`）、`:143-145`（`asRecord` 的 `MQBytes` 路径只保护了 publish 一种形态）
  - 测试盲区：`f_mq/src/base/MQProtocol_test.cj:72-79`、`f_mq/src/base/MQPayload_test.cj:100-115`
- **描述**：`DefaultCodec` 解码 `INPUTSTREAM` 片段时，`size > fileThreshold`（默认 4096）会返回 `DataInputStream` 而非 `Array<Byte>`；而上述类的字节字段是**对象字段**，解码时由 `MutableField.new` 的 setter 以 `convert<F>(data, flag: SILENCE)` 转换，`Array<UInt8>.tryFromData(DataInputStream, SILENCE)` 落入 `case _` 分支后返回**空数组**，全程不抛异常、不告警。于是 `asConsumeResult` 得到 `record.size == 0`，恰好等于协议里「本次没有消息」的哨兵，客户端 `consume` 见空 record 就 `continue` + `sleep` 再轮询，服务端每次仍返回同一条记录 ⇒ consumer 永久阻塞、游标不推进、同组其它订阅者也被卡住。同一机制使 `MQInternalMessage.payload`（备份批次 ≥ 4KB 必然触发）在 `asInternal` 阶段变成空数组 → `decodePayload<MQBackupPayload>([])` 返回 `None` → 服务端回 `INTERNAL`，大消息副本永不落盘；此外 `decodeData` 创建的 `/tmp/tmpFile<UUID>/` 被静默丢弃，没有任何清理路径，每次解码大载荷泄漏一个临时文件/目录。影响：body 约 4KB 以上时用户消息收不到（阻塞而非报错）、备份/死信/内部信封数据静默丢失、`/tmp` 持续增长，且被「空 record = 无消息」语义完全掩盖。

### [严重] `publishTime` 的「UTC 23 位」与 `MessageID.toString()` 实际写入的本地时间不一致，跨时区部署时延迟投递与滞后统计整体偏移

- **位置**：`f_mq/src/base/MQMessageRecord.cj:99-129`（注释 `:101`、`:124` 的推理与结论自相矛盾）；取证 `f_protocol/src/default/MessageID.cj:39-41`；文档断言 UTC `f_mq/doc/详细设计.md:458-459`、`openspec/specs/f-mq/protocol/spec.md:286-294`；用例 `f_mq/src/base/MQMessageRecord_test.cj:144-148`
- **描述**：`MessageID.toString()` 用 `time.format("yyyyMMddHHmmssSSS")` 输出，而 `DateTime.now()` 是**本地时区**实例（`f_codec/src/default/DefaultCodec.cj:520-525` 的注释亦说明本地时间会多算一个 UTC 偏移），故记录里的 23 位是生产者的本地墙钟时间；而 `publishTime` 用 `DateTime.parse` 按本地解释后再加 `parsed.zoneOffset`，等价于把这串数字当 UTC。二者只在生产者时区为 UTC 时相等：`Asia/Shanghai` 客户端写入 18:30（真实 10:30Z），服务端 `publishTime` 得到 18:30Z，比真实发布时间晚 8 小时 ⇒ `now - publishTime` 为负，延迟投递多等一个时区偏移（`fmq/src/queue/GroupCursor.cj:425`、`QueueLog.cj:116` 用它算到期时间/滞后）。影响：非 UTC 部署下延迟消息到期判定、`lagMs`/backlog 统计整体偏移且随客户端时区漂移；现有用例在 +08 环境下该格式断言本身会失败，说明用例也依赖环境时区。

### [一般] `decodePayload<T>` 只对 `SimpleDataObject` 做类型校验，标量/其它载荷会被静默转成「默认对象」

- **位置**：`f_mq/src/base/MQProtocol.cj:210-236`（校验分支 `:219-225`，转换 `:226-230`）
- **描述**：类型守卫只覆盖 `case o: SimpleDataObject`；若 `payload` 解出来是 `DataString` / `DataReal` / `DataNone`，直接落到 `T.tryFromData(data, SILENCE)`。`SILENCE` 下 `DataObject<T>.populate` 对非可迭代输入走 `case _ => target`（`f_data/src/base/DataObject.cj:194-206`），返回**字段全默认值的 `T`** 而不是 `None`。因此 metaSync 信封里塞一个字符串/整数，`decodePayload<MQMetaSyncRequest>` 会返回 `Some(MQMetaSyncRequest(-1))`，服务端按「合法的快照请求」处理并回全量快照；`decodePayload<MQTopicAssignment>` 同样会得到 `topic=''`、`owners=[]` 的分配结果。与函数注释「类型不匹配返回 `None`」不符，恶意/错误载荷不会被拒绝而是触发正常业务分支，且无用例覆盖。

### [一般] `MQMessage.get<T>()` 对空 BODY / 异类型对象 BODY 返回「字段全默认的对象」，与文档契约相反

- **位置**：`f_mq/src/base/model/MQMessage.cj:53-63`（注释 `:49-52` 声明「BODY 为空或类型不匹配时返回 `None`，不抛异常」）；用例盲区 `f_mq/src/base/MQModel_test.cj:64-94`
- **描述**：`get<T>` 只处理 `body == None`；当 `body = Some(DataAny(DataNone))`（发布空 BODY 经 `MQMessageContent.toMessage` 必然变成该形态，`MQMessageContent.cj:31-33`）或 `body` 是**另一个** `@DataAssist` 类型时，`convert<T>` 在 `SILENCE` 下返回默认对象：`DataObject.populate(DataNone)` → `case _ => target`，字段不匹配时 `set` 也静默跳过。影响：业务侧 `msg.get<Order>()` 会拿到 `id=0/title=''` 的「空订单」并当成真实消息处理（静默错误数据），异类 BODY 也表现为全默认值，掩盖类型不匹配。现有用例只验证了「对象 BODY 取标量返回 `None`」，恰好绕开该路径。

### [一般] 错误码 `INVALID_GROUP`（6）没有任何产生路径，订阅组名校验整体缺失

- **位置**：`f_mq/src/base/MQConstants.cj:30`；规格 `openspec/specs/f-mq/protocol/spec.md:156`；服务端入口 `fmq/src/server/MQCommandExecutor.cj:230-250`
- **描述**：全仓库（`f_mq/src` + `fmq/src`）对 `MQErrorCode.INVALID_GROUP` 的引用数为 0，base 层也没有对标 `MQTopic.isValid` 的组名校验工具。`MQSubscribeGroupMeta` / `MQSubscribePayload.subscribeGroup` 可为任意字符串（空串 = 默认组），`fmq manager registerGroup` 同样不校验。影响：错误码表是对外契约但第 6 号是死码；非法组名（含空白、`:`、路径分隔符等）会被写进元数据并落到 `metas/` 目录文件名里，只能靠下游文件名编码兜底。

### [一般] `metaSync` 的三个重载与内部子载荷解码分支没有用例，`metaSync(MQDeregisterPayload)` 映射到 `DEREGISTER` 无人守护

- **位置**：`f_mq/src/base/MQProtocol.cj:82-97`；用例 `f_mq/src/base/MQProtocol_test.cj:40-58`、`:149-165`
- **描述**：`metaSync` 有 4 个重载，分别产出 `REGISTER`/`REGISTER`/`REGISTER`/`DEREGISTER`；`factoriesUseExpectedCommands` 只覆盖第一个，`internalEnvelopeCarriesSubPayload` 只覆盖 assignment 与 backup。`MQSubscribeGroupMeta`、`MQDeregisterPayload`、`MQMetaSyncRequest`、`MQMetaSnapshot` 四种没有任何「编码→解码→类型/字段」级断言，`decodePayload<MQMetaSyncRequest>` 也无正向用例，而生产代码在用它们（`fmq/src/cluster/MetaSyncer.cj:162-166`、`MQCommandExecutor.cj:137-165`）。影响：唯一映射到 `DEREGISTER` 的删除同步若写错命令，现有用例全绿；信封 4 个解码分支只测 1 个，回归不可见。

### [一般] 16KB 大记录用例没有验证「确实走了临时文件形态」与「临时文件已清理」，正好掩盖了大消息降级缺陷

- **位置**：`f_mq/src/base/MQProtocol_test.cj:72-79`；计划要求 `f_mq/doc/开发计划.md:176`；规格场景 `openspec/specs/f-mq/protocol/spec.md:71-74`
- **描述**：用例只断言 `record.size > 16 * 1024`（由构造必然成立，等于同义反复）与帧往返后字节相等；既没有断言 `MQProtocol.asRecord` 走的是 `DataInputStream` 分支，也没有断言临时目录被删除，`MQMessageRecord_test.cj:230-266` 只对 `MQBytes` 做单独验证，未覆盖「同一条消息的载荷被解两次」这种非幂等场景。影响：`fileThreshold` 相关的临时文件形态、清理、二次读取在协议层无守护，上述严重缺陷因此完全不可见。

### [一般] `publish(record, id!)` 重载没有任何用例，帧 id 与记录 `MESSAGE_ID` 的一致性无守护

- **位置**：`f_mq/src/base/MQProtocol.cj:33-39`；用例 `f_mq/src/base/MQProtocol_test.cj:43`、`:63`、`:77`、`:94`；生产使用点 `f_mq/src/client/MQClient.cj:77`
- **描述**：带 id 的重载是「记录内 MESSAGE_ID 与帧头 `Message.id` 取同一个值」的唯一实现（设计 §3.2 的明确约定），客户端 publish 全部走这条路，但 base 层没有断言 `message.id == mid`，也没有断言该 id 在帧往返后仍与记录里的 `MESSAGE_ID` 相同。影响：若有人把 `Message.build` 换成 `Message.publish`（生成新 id），单测全绿但记录 messageId 与请求 id 脱钩，排障对不上号，延迟计算依赖的 id 来源也会漂移。

### [一般] `详细设计.md` 与当前实现多处不一致（字段、签名、kind 数量、分派表）

- **位置**：`f_mq/doc/详细设计.md:128`（register 载荷缺 `delayingMs`）、`:137`（consume 响应缺 `queueIndex`）、`:138`（ack 载荷缺 `queueIndex`）、`:158`（kind 写两种实际三种，`:217` 同）、`:153`（分派表声称所有 MQ 载荷都能被 `kindOf` 分派，实现只认三种）、`:195-223`（§4.1 总表缺 `MQHost`）、`:252-258`（§5.1 `MQTopicMeta` 缺 `delayingMs`）、`:275-291`（§5.3 `MQMessage` 缺 `queueIndex`）、`:301-308`（`toMessage` 少一个 `queueIndex` 参数）、`:420-444`（签名清单缺 `stats`、三个 `metaSync` 重载、`publish(record, id!)`、`publishTime`）、`:450-451`（仍称 `asRecord` 用 `convert<Array<Byte>>`，实现已改为 `MQBytes.fromData`）
- **描述**：设计文档是 R1 的判定依据之一，但上述条目会让读者误判协议字段（尤其 `queueIndex` 缺失，正是历史上修过的多队列 ACK 缺陷），也会让后来者按旧签名写代码。

### [一般] `MQDeregisterPayload.isTopic()` 不校验 `kind`，未知/拼错的 kind 被当成「删订阅组」

- **位置**：`f_mq/src/base/payload/MQDeregisterPayload.cj:40-42`；消费方 `fmq/src/server/MQCommandExecutor.cj:175-185`
- **描述**：`isTopic()` 只做 `kind == "topic"`；`kind` 为 `""`、`"Topic"`、`"subscriber"` 等值时一律返回 `false`，调用方据此走「删组」分支（`consume.removeGroup` / `subscribers.removeByGroup` / `cursors.removeGroup`），静默删掉订阅组而不是报错；默认值 `kind = ''`（`:27`）会直接落入该分支。影响：一个拼错的删除请求会误删组且不返回任何错误；结合「默认对象」问题，空 `MQDeregisterPayload` 也能造成删除。

## R2

### [严重] 节点连接一次性使用，故障后永不重建（重连链路缺失）

- **位置**：`f_mq/src/client/MQNodePool.cj:68-75`（`clientOf` 命中已关闭 `Client` 时直接抛异常）、`:110-114`（`aliveNodes` 把已关闭连接视为死亡）、`:79-89`（`clients[nodeIndex]` 只在首次创建时写入，此后无重建路径）
- **描述**：`MQNodePool` 对每个节点只创建一次 `Client<DataAny>`，一旦 `isClosed()` 为真，`clientOf` 永久抛 `MQConnectionException`，`clients[nodeIndex]` 也不会被清空重建。而 `f_net` 的 `Client` 在全部 `SocketBuffer` 关闭后的心跳轮次会自行 `close()`（`f_net/src/client/client.cj:171-181`），`close()` 后 `transfer` 直接返回 `None`（`:270-277`）。因此节点重启或网络中断超过 3 个心跳周期（`checkDuration=30s`）后，MQ 侧永久放弃该节点，直到整个 `MQClient` 重建。影响：与 `详细设计.md:531`「心跳/重连/失败容忍全部复用 `f_net` 内建实现」的承诺矛盾；滚动重启、短暂网络抖动后客户端容量永久缩水，若该节点是某订阅的唯一 owner，`consume` 将永远取不到消息。现有用例（含 e2e 停机段，停机后 1 秒内即验证）都在重连窗口之内，无法暴露。

### [一般] 全部 owner 不可达时 `consume` 永久静默空转，不抛连接异常

- **位置**：`f_mq/src/client/MQClient.cj:164-197`（`while (true)` 内对每个 owner 调 `transferOf`，`None` 时只 `continue`）、`:280-286`（`transferOf` 把连接异常吞成 `None`）
- **描述**：所有 owner 都拒绝连接时，每轮耗时 `N × 1s`（`CONSUME_TIMEOUT`）+ 200ms，循环永不退出也不抛任何异常。影响：与 `详细设计.md:500`「`consume` 连接类故障抛出 `MQConnectionException`」矛盾；调用方无法区分「暂时没有消息」与「集群全挂」，只能靠外部超时兜底，故障期间无任何日志。与上一条叠加后 `consume` 成为不可恢复的挂死点。

### [一般] `ack` 静默忽略全部失败与全部错误码

- **位置**：`f_mq/src/client/MQClient.cj:208-220`
- **描述**：`ack` 先 `sub.deliveries.remove(...)` 再 `transferOf(...)`，返回值被丢弃（`:214`、`:217`），广播分支同样丢弃；既未区分 `ACK_UNKNOWN` 与 `INTERNAL`/连接失败，也不向调用方返回结果，映射条目在发送前已删除导致失败后无法重试定位。影响：ack 丢失时调用方完全无感知，只能等服务端 ack 超时重投，表现为「重复消费」且无线索；规格只要求忽略 `ACK_UNKNOWN`，实现放宽成「忽略一切」。

### [一般] `unsubscribe` 忽略发送结果，服务端订阅可能残留

- **位置**：`f_mq/src/client/MQClient.cj:229-240`（`:231` 先 `subscriptions.remove`，`:237-239` 逐个 `transferOf` 且不检查）
- **描述**：本地订阅先被删除，再向 owner 发送 `UNSUBSCRIBE`，任一发送失败（超时/断链）都不会重试、不会抛错；失败后本地已无该订阅，调用方也无法补发。影响：服务端 `SubscriberRegistry` 会留下孤儿订阅直到该连接断开才被清理（`fmq/src/server/MQCommandExecutor.cj:268-280`），期间仍占用组游标/参与分配，造成「已退订仍在消费位点上推进」的假象，客户端无任何途径感知。

### [一般] `subscribe` 回滚路径同样忽略失败，回滚可能不完整

- **位置**：`f_mq/src/client/MQClient.cj:147-152`（`rollback` 内 `transferOf` 返回值丢弃）
- **描述**：`GROUP_NOT_EXIST`/`TOPIC_NOT_EXIST` 时向已接受节点补发 `UNSUBSCRIBE`，失败被静默吞掉；`fatal` 只保留最后一个错误。影响：回滚失败时服务端残留订阅，与 `unsubscribe` 同源；`spec.md:82-85` 只断言「向节点 0 发送 `UNSUBSCRIBE`」，用例 `MQClient_test.cj:200-221` 也只断言条数，无法发现回滚失败。

### [一般] 客户端零日志：所有链路异常被无条件吞掉，解码失败的消息静默丢弃

- **位置**：`f_mq/src/client/MQClient.cj:280-286`（`catch (_: Exception) { None }`）、`:173-194`（`asConsumeResult` 返回 `None` 或 `MQMessageRecord.decode` 返回 `None` 时直接 `continue`）
- **描述**：`MQClient.cj` 整个文件没有任何 `LoggerFactory`；连接拒绝、超时、协议解码失败、记录解码失败全部表现为「没拿到消息」，无日志、无异常、无返回值区分。`autoAck = true` 时服务端在投递时已推进游标，客户端解码失败即真丢消息。影响：`f_net` 侧有完整日志而 MQ 客户端把异常统一抹平，线上排障只能看到「消费很慢」；规格只规定「空 `record` 换下一个 owner」，未覆盖「非空 `record` 但解码失败」，实现选择丢弃属未定义的静默数据丢失路径。

### [一般] 建连在节点池全局锁内同步进行，一个慢节点阻塞所有节点

- **位置**：`f_mq/src/client/MQNodePool.cj:67-76`（`synchronized(lock)` 内调用 `createClient`）→ `:91-100`（`buildClient` → `Client.builder(...).build()`）→ `f_net/src/client/client.cj:378-386`（`build()` 内同步 `TcpSocket(address).connect()`）
- **描述**：首次访问某节点会在池锁内完成 TCP 连接（含 DNS 与 SYN 等待），连接不可达主机的超时可达数十秒。影响：多线程并发 `publish`/`consume` 时，只要一个节点首次建连卡住，全部节点（含健康节点）的请求都被阻塞在 `clientOf` 的锁上，客户端整体停顿。现有用例只覆盖 `127.0.0.1:1`（本地立即 `ECONNREFUSED`），无法暴露。

### [一般] 全部节点回 `NOT_OWNER` 时错误分类为连接异常

- **位置**：`f_mq/src/client/MQClient.cj:87-95`（`NOT_OWNER` → `invalidate` + `continue`，循环结束后统一 `throw MQConnectionException`）
- **描述**：链路完全正常但所有节点都认为自己不是 owner（节点表漏了持有队列的节点、重平衡窗口）时，抛的是 `MQConnectionException`。影响：调用方会把「拓扑不认识该主题」误判为「网络故障」而做无意义的重试/降级；`spec.md:29-30` 只约定「全部节点不可达 → `MQConnectionException`」，未约定全 `NOT_OWNER` 的语义，实现把两种情形合并了。

### [一般] `publish` 未做 tags 校验，与客户端规格矛盾

- **位置**：`f_mq/src/client/MQClient.cj:68-77`（只校验 `MQTopic.isValid(topic)`，随后直接 `MQMessageRecord.encode(topic, tags, ...)`）
- **描述**：`spec.md:28` 要求「`publish<T>(topic, body, tags!)` SHALL 先在本地校验主题与 tags」，实现只校验 topic；`f_mq/src/base` 中也无任何 tags 校验函数。影响：规格能力缺失；同时 `spec.md` 未定义 tags 合法性规则，实现与文档都无法判定「什么算非法 tags」，后续补齐校验或修订文档都缺少依据。

### [一般] `consume` 无客户端侧「认领」语义，并发用例无法验证规格要求

- **位置**：`f_mq/src/client/MQClient.cj:185-191`（拿到记录后仅 `deliveries.add(key, node)`，无去重/认领）、`f_mq/src/client/test/MQClient_test.cj:533-569`（并发用例的桩按调用序号发唯一位置，`:539-540`）
- **描述**：`详细设计.md:617` 声称「`consume` 的『拿到即删』语义：同一 `(index, offset)` 不会被两个线程同时取出（在 `deliveries` 上用 `remove` 的返回值判定归属）」，实现里既没有 `remove` 也没有去重；并发用例的桩每次都返回新位置，因此无论客户端是否去重，`seen.size == 200` 恒成立。影响：规格「同一位置不得被两个线程同时认领」在客户端层没有实现，完全依赖服务端串行化；一旦服务端在重投窗口内重复投递同一位置，两个消费者线程可同时拿到同一条消息。该用例给出的是虚假保证——删除客户端任何逻辑它仍然通过。

### [一般] 关键失败路径与规格场景缺用例（覆盖缺口清单）

- **位置**：`f_mq/src/client/test/MQClient_test.cj`（全文 17 个 `@TestCase`）、`f_mq/src/client/test/MQNodePool_test.cj`、`f_mq/src/client/MQClientConfig_test.cj`
- **描述**：8 条规格场景/关键分支零覆盖：①「节点 0 成功、节点 1 回 `NOT_OWNER` → owner 集合为 `[0]`」（`MQClient.cj:123-124` 的跳过分支未执行）；② `subscribe` 侧「所有节点都非 owner / 都不可达 → `MQConnectionException`」（`:137-139` 无覆盖）；③「一个线程 `close()`、其它线程持续调用公开 API」（`closeIsIdempotentAndBlocksApis:497-531` 是单线程顺序调用）；④ `publish` 的 5s 超时回退路径（`MQClient.cj:77-79`，无用例让桩「不响应」）；⑤ `consume` 中 `ERROR` 且 code ≠ `SUBSCRIBE_NOT_EXIST` 的跳过分支（`:179`）；⑥ `consume` 记录解码失败分支（`:185` 为 `None`）；⑦ 节点故障恢复（e2e 停机段在重连窗口内）；⑧ `MQClientConfig` 非法 `host:port` 项（`tasks.md:39` 声称已测）。影响：`MQClient.cj` 至少 6 个分支零覆盖，当前 17 条用例只覆盖 happy path（+ 少量显式错误码），实现回退到「只跑通主流程」不会被任何用例拦住。

### [一般] 任务清单虚报用例文件与用例内容

- **位置**：`f_mq/doc/spec/add-fmq-message-queue/tasks.md:39`、`:42`、`:44`、`:45`
- **描述**：实际不存在 `MQClientPublish_test.cj` / `MQClientLifecycle_test.cj`，全部并入 `MQClient_test.cj`；「非法项解析」「对象 BODY」「关闭与调用并发」三处用例均不存在；「多 tags」用例只用了 2 个 tag（`MQClient_test.cj:74`），与 `spec.md:35` 的「10 个 tags」不符。影响：任务清单是验收依据，标 `[x]` 的条目与实际测试资产不一致，后续按清单核对覆盖度会得出错误结论，也直接污染需求-实现-用例矩阵。

### [一般] 详细设计 §5.13–5.15/§6.2 的签名与行为描述已与实现漂移

- **位置**：`f_mq/doc/详细设计.md:490`（`ack` 缺 `queueIndex`）、`:514`（`deliveries` 类型错误，实际为 `ConcurrentHashMap<String, Int64>` 且键含 `queueIndex`）、`:524`（`MQNodePool.init` 实际只接受 `hosts`）、`:570-571`（publish 实际为 `candidateNodes` 全序 + 用 `[node]` 覆盖缓存）
- **描述**：`queueIndex` 的引入（`tasks.md:115` 记录的正是一次有意的 ACK 串台修复）没有回写到详细设计，`MQNodePool` 构造签名与 `MQOwnershipCache` 的 TTL 注入也未回写；`publish` 的「并集修正」实际实现为「整体失效 + 单节点覆盖」，行为描述不成立。影响：签名级漂移会让后续按文档实现的调用方直接编译失败（`ack` 少一个参数即歧义），并误导对路由优先级的理解。

### [一般] `MQClientConfig_test` 泄漏全局配置，且未验证「配置缺失」与「非法项」

- **位置**：`f_mq/src/client/MQClientConfig_test.cj:28`（`Config.set(...)` 后不还原）、`:34-43`（只覆盖空串）
- **描述**：`Config` 是进程级静态状态，两条用例写入后不清理，后续任何依赖 `MQClient()`（无参构造）的用例都会读到上一个用例残留的 `127.0.0.1:2351`，测试结果与执行顺序相关；`spec.md:16-19` 的「配置缺失」与 `:21-24` 的「非法地址」两个场景均无用例。影响：测试隔离性缺陷 + 规格场景未覆盖，并行执行 `cjpm test` 时可能偶发失败或静默使用错误节点表。

## R3

### [严重] 重同步只做「补缺」，删除不可传播：被删主题/组会在离线节点上复活

- **位置**：`fmq/src/cluster/MetaSyncer.cj:145-159`（`mergeSnapshot` 仅 `topicOf(...).isNone()` 时 `applyTopic`）、`:105-121`（`syncFromPeers` 直接用该合并逻辑）、`fmq/src/meta/MetaStore.cj:178-192`（删除只删本地文件，不留删除标记/版本）
- **描述**：整套复制协议是「全量快照 + 只增合并」，元数据没有墓碑（tombstone）、没有版本号/纪元（全树 `grep` 为空）。节点 X 在 `deleteTopic /t` 期间离线、`broadcastDelete` 落空，重启后 `MQServer.cj:74` 拉取 peer 快照，`mergeSnapshot` 只补 peer 有本地无的条目，对「本地有、peer 无」的 `/t` 不做处理，X 于是继续把 `/t` 当作已注册主题，`MQServer.cj:77-79` 还会为该主题打开本地队列目录并对外提供写入。影响：与 spec「每个节点 SHALL 保存全部主题与订阅组元数据」「由死转活 SHALL 触发重同步」及 `详细设计.md:617` 直接矛盾——一次普通重启即可让已删除主题长期存活；派生后果包括客户端向幽灵主题发布并持续堆积、同名主题重新注册时 `applyRemote` 返回 `Conflict` 保留旧 owners 造成两节点分配分歧、幽灵组使重建后的主题 `registerGroup` 永远返回 `GROUP_ALREADY_EXIST`。这也是「反熵」完全缺失的根因：`MetaSyncer.cj:29` 注释声称 peer 恢复后由启动期全量同步补齐，实际只能补缺。

### [严重] 备份副本的「消息状态」是伪造值，接收端也完全忽略

- **位置**：`fmq/src/cluster/BackupReplicator.cj:114-116`（`MQBackupState(seq, offset, 0, false)` 硬编码 `deliverCount=0`、`acked=false`）、`fmq/src/server/MQCommandExecutor.cj:194-196`（接收端只 `backupStore.append(...)`，`payload.states` 未读取）
- **描述**：`详细设计.md:738` 与 spec 要求在副本里保留投递次数与确认位；实现里 `record()` 的入参根本不含状态（`BackupReplicator.cj:65`），落盘状态恒为「未投递、未确认」，接收端连这个假状态也不存。影响：备份目录与主队列在「消费进度」维度完全等价于「全部未消费」；一旦按设计 §6.8「人工指定数据目录」做恢复，所有已 ack 的消息会被重新投递，at-least-once 退化为「重放历史全量」。`fmq/doc/backlog.md:8-11` 已登记为 P0，本轮仍未修复。

### [严重] 备份批次达到 64 条时在发布线程内同步发送，直接阻塞发布

- **位置**：`fmq/src/cluster/BackupReplicator.cj:69-80`（`shouldFlush` → 直接 `flush()`）、`:107-124`（`flush` 内对每个目标逐个 `transport.send`）、`fmq/src/cluster/NodeRegistry.cj:130`（`transfer(message, pingTimeout * 5)`，默认 5s/目标）
- **描述**：`record()` 在临界区外调用 `flush()`，而 `flush()` 是同步 RPC：分组后对 `targets` 中每个节点串行 `send`，每个都能阻塞到 5s 超时。注释与 README:37「发布路径不阻塞」、spec「队列有界，溢出时 SHALL 丢弃并记 WARN，不得阻塞发布」均与此矛盾。最坏一次 publish 被拖住 `backup × 5s`（`backup=2` 即 10s），同一批 64 条还会被多个 queue/主题分组放大成多次 RPC。影响：`mqServer_backup > 0` 是常规配置，只要一个后继节点网络抖动，每第 64 条消息的发布延迟就从毫秒级跳到秒级，客户端 `PUBLISH_TIMEOUT` 仅 1s 级（`f_mq/src/client/MQClient.cj:77`）→ 大量误判超时并换节点重试，进一步放大负载。现有用例只用 `FakeTransport`（无耗时），无法暴露。

### [严重] `registerTopic`/`registerGroup` 丢弃 `MetaApplyResult`，「检查-执行」非原子

- **位置**：`fmq/src/cluster/MetaSyncer.cj:54-67`（`store.topicOf` 预检查 → 读 `nextStartNode` → `applyTopic` 丢弃返回值 → 无条件 `broadcastTopic` → 返回本地算出的 `assignment`）、`:74-80`（`groupExists` 预检查 + `applyGroup` 结果丢弃）
- **描述**：典型 TOCTOU：`MQCommandExecutor` 用 200 线程的 executor 处理请求（`MQServer.cj:93-94`），两个并发 `registerTopic` 可同时通过 `topicOf().isNone()`；随后只有一方 `Applied`，另一方得到 `Duplicated`/`Conflict`，但代码不看返回值，仍把**自己算出的分配**广播出去并作为成功响应返回。`start = store.nextStartNode % nodeCount`（第 61 行）也读在锁外，两个并发注册可能拿到同一起点。影响：响应与本地状态不一致（manager 拿到 assignment A，本节点落盘却是 B）；对端收到 A 后 `applyRemote` 若先到则落 A（全集群 A，注册节点 B），若后到则被 `Conflict` 丢弃（注册节点 B、对端 A），两种结果都让某些队列的 owner 与实际持有日志的节点不匹配，发布方持续收到 `NOT_OWNER` 并在节点间打转。设计 §8 Q2 只约束了跨节点并发，**同一节点内的并发注册**未被约束，而这条路径最容易发生。

### [一般] 死转活触发的重同步不会打开新主题的本地队列，节点长期处于「元数据有、队列无」状态

- **位置**：`fmq/src/server/MQServer.cj:96`（`onRevived = {=> syncer.syncFromPeers()}`）、`fmq/src/cluster/MetaSyncer.cj:145-159`（`mergeSnapshot` 只写 `MetaStore`）；对照 `openTopic` 的生产调用点 `MQServer.cj:77-79`、`MQCommandExecutor.cj:104`、`:141`
- **描述**：节点 X 离线期间其它节点注册了 `/new`（X 是其中若干队列的 owner），X 复活后只拉到元数据，`QueueManager` 里没有 `/new`；`openTopic` 只在启动期、本节点处理注册、收到主题广播三条路径被调用，均不会再触发。影响：X 对 `/new` 的所有 publish/subscribe 一律回 `NOT_OWNER`（`MQCommandExecutor.cj:215-216`），X 名下队列在整个进程生命周期内不可用，分配器承诺的负载分散被永久破坏；若某主题只有 1 个队列且 owner 恰为 X，则该主题在 X 重启前完全不可发布（客户端遍历所有节点后抛 `MQConnectionException`）。spec「由死转活 SHALL 触发一次重同步」的语义因此只完成了一半。

### [一般] 备份批次发送失败后整批丢弃，无重试

- **位置**：`fmq/src/cluster/BackupReplicator.cj:88-92`（先把 `pending` 换成空表）、`:107-110`（`targets` 为空直接 return，`batch` 丢失）、`:119-123`（`send` 失败仅 WARN）
- **描述**：一批数据在发送前就脱离队列，任何失败都没有回到待发送集合的路径；`targets.size == 0`（单节点）时整批静默丢弃。影响：备份可靠性退化为「尽力而为」，节点重启窗口内的备份全部丢失且无补发，主节点随后故障时副本缺少一段连续区间，而备份的用途正是应对该场景。`backlog.md:12-14` 已登记为 P0。

### [一般] 运行期广播失败只记 WARN，注释与文档承诺的「补齐」并不存在

- **位置**：`fmq/src/cluster/MetaSyncer.cj:173-183`（失败仅 `log.warn`）、`:29`（类注释「peer 恢复后由启动期全量同步补齐」）、`fmq/src/cluster/NodeRegistry.cj:166-184`（复活回调只在本节点发往该 peer 成功后才触发，且执行只增合并）
- **描述**：注册/注消广播失败后没有任何补偿队列；后续补只有在「本节点再次成功给该 peer 发消息」时才触发一次 `syncFromPeers`，而该同步又只补缺，因此**删除类变更永远补不回来**，新增类变更也只能在碰巧发送成功时补。影响：文档与代码注释给出「最终一致」承诺，实际是「最终补新增、永不补删除」；运维视角表现为某节点元数据比集群旧且没有任何告警可定位。

### [一般] `mergeSnapshot` 不检测冲突、不发 WARN，与设计的冲突处理不一致

- **位置**：`fmq/src/cluster/MetaSyncer.cj:145-159`
- **描述**：设计 §5.6（`详细设计.md:248`）明确「已存在但不同 → 记 WARN、保留先到者」，但 `mergeSnapshot` 对同名主题直接跳过（第 147 行），既不比较 `owners`/`queueNum`/`delayingMs`，也不打日志；快照中的 `delayingMs` 差异同样被静默吞掉。影响：启动同步阶段的元数据分歧完全不可观测，排障时缺少唯一线索；`add-fmq-metrics-and-delay` spec 要求「快照携带 `delayingMs`」，实现只在「本地无该主题」时才落该值，本地已有主题的延迟漂移不会被纠正。

### [一般] `applyRemote` 在乱序到达时会让本机轮转指针回退

- **位置**：`fmq/src/cluster/MetaSyncer.cj:123-131`；`fmq/src/meta/MetaStore.cj:148-151`
- **描述**：远端应用时无条件用 `assignment.startNodeIndex` 重算 `nextStart` 并交给 `applyTopic`，后者在 `Applied` 时直接覆盖 `assign.meta`，不做「只增」比较；广播与快照之间没有顺序保证：先收到 `/b`（start=1 → next=2）、后收到 `/a`（start=0 → next=1）时，指针从 2 回退到 1。影响：注册节点指向 2、该节点指向 1，若后续注册（manager 故障转移）落到该节点就会选出不同起始节点；assignment 自包含所以不直接丢消息，但分配语义在节点间不一致，每次重启/乱序都可能重现。另外 `startNodeIndex` 与 `owners[0]` 之间无一致性校验，畸形载荷可把指针推到任意值。

### [一般] 远端元数据缺少结构校验，畸形分配会污染本地状态

- **位置**：`fmq/src/meta/MetaStore.cj:135-154`（`applyTopic` 只比较 `queueNum` 与 `owners`，从不校验二者关系）、`fmq/src/cluster/MetaSyncer.cj:123-135`、`fmq/src/server/MQCommandExecutor.cj:138-144`
- **描述**：`applyTopic` 接受任意可解码的 `MQTopicAssignment`。`owners.size != queueNum` 时，`QueueManager.openTopic` 按 `owners.size` 建队列（`QueueManager.cj:70-75`），而 `TopicQueueSet.queueNum` 取 `assignment.queueNum`（`QueueManager.cj:76`），二者不一致；`owner(i)` 越界返回 `None` 但调用方多按 `owners` 直接用。远程节点（版本不一致、载荷损坏但能解码）可把这种结构写进 `topics/` 并持久化。影响：一旦落盘就跨重启持续存在，统计（`queueNum`）与实际队列数背离，消费/发布路径对同一主题给出不同视图，`MetaStore` 的 `Conflict` 判定也被脏数据固化。

### [一般] `removeTopic` 的删除顺序留下崩溃窗口：重启后出现「无主题的孤儿组」

- **位置**：`fmq/src/meta/MetaStore.cj:178-192`（顺序：清内存 → 删 `topics/*.meta`（183-185）→ 递归删 `groups/<topicEsc>`（186-189））
- **描述**：两次删除之间进程崩溃/掉电，磁盘上只剩组文件而主题文件已消失；`loadGroups`（`:302-322`）不校验主题是否存在，直接按 `meta.topic` 建索引，于是 `groupsOf("/t")`、`groupExists("/t", g)` 重启后仍为真而 `topicOf("/t")` 为 `None`。影响：同名主题重新注册后，原组的 `GROUP_ALREADY_EXIST` 会阻止再次注册（`MetaSyncer.cj:74-77`），且这些组没有任何主题承载；`snapshot()` 还会把孤儿组复制给所有 peer（`:232-237`），把局部脏数据扩散到集群。

### [一般] `applyGroup` 不校验主题存在，组广播可与主题广播乱序

- **位置**：`fmq/src/meta/MetaStore.cj:156-175`（无 `topicIndex` 检查）、`fmq/src/cluster/MetaSyncer.cj:133-135`（`applyRemoteGroup` 直接落盘）
- **描述**：`MetaSyncer.registerGroup` 有「主题必须存在」的检查（第 71 行），但远端应用路径没有；注册主题与注册组是两条独立广播消息，网络/线程调度可让组先到，或主题已被删除而组的广播仍在途。影响：对端产生孤儿组并持久化，后果与上一条相同（阻塞后续组注册、被快照扩散）；对「乱序」这一重点场景，当前实现没有顺序或依赖保证。

### [一般] 元数据写入没有 `flush`/`fsync`，掉电可能得到空 `.meta`

- **位置**：`fmq/src/meta/MetaStore.cj:328-346`（`File.create(tmp)` → `write` → `close` → `rename(overwrite: true)`，全程无 `file.flush()`）
- **描述**：设计 §5.5 只承诺「`.tmp` + rename 避免半写文件」，但 rename 与数据块落盘的顺序在多数文件系统上不保证；掉电后可能得到「已改名但长度为 0」的正式文件。影响：`loadTopics`/`loadGroups` 会把它当坏文件跳过（`:294-297`、`:309-318`），即主题/组在重启后静默消失，而消息日志仍然存在（`SegmentedLog` 默认 `syncInterval=1`，每条 append 都 fsync），消息比元数据更耐久，语义上是反的；该路径无用例覆盖。

### [一般] `record()` 在关闭后静默丢弃，与 README 的「记 WARN」不符

- **位置**：`fmq/src/cluster/BackupReplicator.cj:66-68`
- **描述**：`backup <= 0 || closed.load()` 直接 `return`，无任何日志；README:37 写的是「备份队列满或关闭阶段到达的写入会被丢弃并记 WARN」，而 README:111 的「静默丢弃」是另一处，两处自相矛盾。影响：关闭阶段丢备份是允许的，但完全没有痕迹，线上排查「为什么副本比主队列少一截」时缺少依据。

### [一般] `NodeRegistry.clientOf` 命中已关闭连接直接抛，不重建

- **位置**：`fmq/src/cluster/NodeRegistry.cj:102-108`
- **描述**：`case Some(client) => if (client.isClosed()) { throw Exception(...) }`，且 `clients[index]` 不会被清空；`send` 捕获异常后只 `markFailed`，下一次调用依旧命中同一个已关闭对象。影响：与 R2 的 `MQNodePool.clientOf` 完全同型：`f_net` 的 `Client` 会在连续心跳失败后自我 `close()`，此后本节点对该 peer 的元数据广播与备份永久失败，直到整个进程重启——而「节点间复用 `f_net` 心跳重连」正是 spec「节点表与身份」的要求。`backlog.md:18-21` 已登记。

### [一般] 存活标记初值为「全部存活」，且 `isAlive` 是死代码

- **位置**：`fmq/src/cluster/NodeRegistry.cj:58`（`alive = Array<AtomicBool>(nodes.size) {_ => AtomicBool(true)}`）、`:192-198`；对照 `fmq/doc/开发计划.md:373`（用例 `isAliveFalseBeforeSeen`「未成功交互 → false」）
- **描述**：所有节点（含从未连上的 peer）一开始就被视为存活，只有一次失败后才转 false；`isAlive` 在生产代码中无任何调用点（仅 `NodeRegistry_test.cj:64` 使用），`markFailed` 只被 `send` 的 catch 调用。影响：开发计划承诺的存活语义没有实现，`详细设计.md:461` 中的 `isAlive` 未参与任何决策；「由死转活」判定完全依赖「先失败一次再成功一次」，因此**从未成功连过的 peer** 在第一次成功时会触发一次多余的 `syncFromPeers`，而「曾经存活、后来静默死亡」的 peer 会一直保持 alive 标记。当前可见后果有限，但一旦按设计接入路由/告警就会误判。

### [一般] `LogCleaner.cleanOnce` 无异常隔离，单点失败中断整轮清理

- **位置**：`fmq/src/cluster/LogCleaner.cj:51-69`（`queue.removeById(meta.index)` 在双重循环内，无 try）
- **描述**：任一段删除抛异常（文件被占用、f_io 拒绝删除、目录权限）都会让 `cleanOnce` 抛出；对 `Timer.repeat` 回调（第 72 行）而言，异常会终止本轮并可能让后续轮次不再执行，且已删除部分与未删除部分没有汇总日志。影响：一个坏主题目录可让整个节点的 TTL 清理长期停摆，磁盘持续增长且无告警；死信清理（第 64 行）也一并被跳过。

### [一般] 测试覆盖缺口：关键失败/乱序/持久化路径无用例

- **位置**：`fmq/src/cluster/MetaSyncer_test.cj:176-275`、`fmq/src/meta/MetaStore_test.cj:26-204`、`fmq/src/cluster/BackupReplicator_test.cj:25-130`、`fmq/src/cluster/NodeRegistry_test.cj:23-104`、`fmq/src/cluster/LogCleaner_test.cj:69-71`
- **描述**：`MetaSyncer` 无 `applyRemoteDelete` 用例（删除复制完全无测试）、无「广播失败仍返回成功且只 WARN」用例、无乱序/重复到货用例、无 `mergeSnapshot` 冲突用例、无「重同步后队列已打开」的装配级用例；`MetaStore` 的 `removeGroup` 零用例，无「坏 `assign.meta` → `nextStart=0`」「`applyGroup` 缺主题」「删除不存在的主题」用例，`atomicWriteSurvivesStaleTmp` 未覆盖 spec 原意（已有有效 `.meta` + 残留 `.tmp` 时正式文件不被污染），坏文件用例未断言坏条目未进入索引；`BackupReplicator` 对 `deliverCount`/`acked`（即伪造值）零断言，无多主题/多队列分批用例，`closeFlushesPending` 未断言定时器已停止，无「`record` 不被慢发送阻塞」用例；`NodeRegistry` 无 `clientOf` 惰性建连/缓存复用用例，`failedSendMarksNodeDead` 依赖真实网络，对「已关闭连接不重建」无用例；`LogCleaner` 的 `@Assert(meta.last || after.size == 1)` 在只剩 1 段时恒真，属弱断言。测试目录固定为 `/tmp/fmq_test_*`，同一用例重复执行/多进程并行会互相清理。影响：上述路径恰好覆盖本层最脆弱的部分，缺陷全部不可见。

### [一般] `syncFromPeers` 的失败分支与告警文案不准确，`snapshotFor` 参数未使用

- **位置**：`fmq/src/cluster/MetaSyncer.cj:110-121`（循环末尾无条件 `log.warn("no peer reachable ...")`）、`:100-102`（`requesterIndex` 未使用）
- **描述**：只要没有一个 peer 返回**可解码的快照**就会打「no peer reachable」，包括「peer 可达但响应是 `MQResult` 错误」「载荷解码失败」两种情况；`snapshotFor(requesterIndex)` 完全忽略入参，无法按请求方做任何差异/权限处理。影响：告警把「协议/版本不一致」误报成「网络不可达」，正好掩盖升级期最常见的故障；`requesterIndex` 的无用参数在接口上暗示了并不存在的按节点裁剪能力。

## R4

### [严重] 段 TTL 清理只认「内存游标」，持久化位点被忽略，慢组积压会被直接删掉

- **位置**：`fmq/src/server/ConsumeService.cj:202-214`（`references` 只遍历懒建的 `cursors`）、`:110-127`（游标只在消费时创建）、`fmq/src/queue/GroupCursor.cj:351-355`（`references = segmentIndex >= committed_.seq`）、`fmq/src/cluster/LogCleaner.cj:58`（删除条件只用该回调）
- **描述**：`GroupCursor` 采用懒建——只有某组真正发起过 `CONSUME`，内存中才会出现该组游标。服务重启后、或某组长时间无消费者在线时，磁盘上仍有 `metas/offsets/<topic>/<queue>/<group>.cursor`，但 `ConsumeService.cursors` 中没有对应项，`references()` 对该组一律返回 `false`，`LogCleaner.cleanOnce` 因此在「该组位点仍指向这些段」时照常删除（`updateTime + ttl < now` 即删）。`GroupCursor.recoverIfSegmentGone`（`:393-418`）随后把位点跳到现存最老段，`committed_` 可能**向前跳**，整段未消费消息永久丢失。影响：直接违反 `queue-storage/spec.md:150-168`「且没有任何游标引用该段」的保留要求；`segmentedLogTTL` 默认 72h、清理器每 5 分钟一轮，任何「离线超过 TTL 的订阅组 + 服务重启」都会命中，把 TTL 调小则立刻命中。现有用例用假回调替代真实 `ConsumeService.references`，从未把真实游标接进清理链路。

### [严重] 读取端对记录长度头没有任何上界校验，损坏/撕裂的段会触发 GB 级分配并导致进程 OOM

- **位置**：`fmq/src/queue/QueueLog.cj:201-206`（`length = getInt32BE(h, 0)`，只判 `length <= 0`）、`:241-262`（`readExact` 第 242 行直接按 `length` 分配）
- **描述**：4 字节大端头被解码成 `1 .. 2^32-1` 的任意值。只要头部字节不完整（掉电/撕裂写在段尾留下半条记录），读端就会按该值一次性申请最大 4 GiB 缓冲。写入侧有 `MAX_RECORD_SIZE = 64 MiB` 限制（`:33`、`:42-44`），读取侧完全没有对应限制，也没有「不超过本段剩余有效字节」的检查（`QueueRecordReader` 手里就有 `segments` 快照可算剩余量）。影响：单条损坏记录足以让 `fmq server` 进程被 OOM killer 杀掉（或 `Array` 分配抛异常打断整轮消费），与 `详细设计.md:321-323`「剩余字节不足视为损坏并停止读取」的承诺相反——当前是「先按声明长度分配，再发现读不满」。同类问题在 `f_codec` 已有专门防护（`DefaultCodec.checkedBuffer`），此处遗漏。

### [严重] 不可评估 BODY（`Unsupported`）会让该组队列永久停摆，且无日志、无指标、无可恢复路径

- **位置**：`fmq/src/queue/GroupCursor.cj:243-246`（本订阅 `Unsupported`）、`:256-258`（组内其它订阅 `Unsupported`）、`:271-276`（`scanPosition` 回退、关流、静默 `return None`）
- **描述**：扫描到「BODY 是未在本进程注册的对象类型 + 订阅 filter 非空」的记录时，游标既不建未决项、也不标记已决、也不推进 `committed`，直接返回 `None`（连 `logger.warn` 都没有，而同类异常在 `:427-429` 的延迟分支里会告警）。由于队列 FIFO 且 `scanPosition` 停在该位置，此后该组对该队列的**每一次** `CONSUME` 都只会重扫这一条并返回空——组内所有后续消息永久不可达。影响：发布侧的 `bodyIsEvaluable` 只检查「**当下**有非空 filter 的活跃订阅」（`MQCommandExecutor.cj:230-241`），因此「先在没有 filter 订阅时发布，之后才 subscribe 带 filter 的订阅」这条完全正常的时序就会把整组卡死。规格要求「该记录 MUST NOT 被投递，并 SHALL 以 `FILTER_UNSUPPORTED_BODY` 语义报错」，实现既没有把错误面暴露给任何一方，也没有超时/死信等出口；54 条用例无一走到该分支。

### [一般] `scanAfter` 在位点段被删（但非最老段）时静默返回 `(0, None)`，`backlog`/`lagMs` 被报成 0

- **位置**：`fmq/src/queue/QueueLog.cj:98-129`（`101-103` 只处理 `start.seq < 最老段`；`125-127` 任何异常都 `return (0, None)`）、`fmq/src/server/ConsumeService.cj:161-166`（stats 直接采信）
- **描述**：只有「位点段号小于现存最老段」才会把起点修正到最老段。若位点段号落在「比最老段大、但已被删除」的区间（上一条的后果，或手工删段、先删后建），`openRecordsFrom` 抛 `IllegalArgumentException` 被 `catch` 吞掉后返回 `(0, None)`，统计口径上表现为「积压 0、延迟 0」，与实际积压相反。影响：违反 `metrics/spec.md`「`backlog` 必须与查询时刻的持久化状态一致，不得使用可能失真的估算值」，运维会据此误判「没有积压」而放过已积压的组；与「段 TTL 清理」缺陷叠加时问题被完全掩盖。

### [一般] 记录「不可读」时静默标记已决，消息丢失且无任何日志

- **位置**：`fmq/src/queue/GroupCursor.cj:143-147`
- **描述**：重投路径上 `readAt(entry.position)` 返回 `None`（段内偏移越界/记录被截断）时，直接把 `entry.decided = true` 并 `continue`，注释写着「记录已不可读（段被清理）：标记已决，避免阻塞」，没有 WARN、没有指标、也没有记录位置。影响：一旦发生（损坏段、TTL 与位点竞态），该消息对该组永久消失且事后无法定位（不知道丢了哪条、哪一段）。同一函数在 `:407`、`:415` 的段缺失场景是有 `logger.warn` 的，此处不一致。

### [一般] `next` 的读流异常恢复分支自相矛盾：全段缺失时开流返回 `None`、读中却 `throw`

- **位置**：`fmq/src/queue/GroupCursor.cj:188-198`（开流失败：`recoverIfSegmentGone` 为真但 `segmentsOrEmpty().size == 0` → `return None`）对比 `:199-207`（读中失败：同样条件 → `throw e`）
- **描述**：两个分支对「所有段都没了」给出相反结果：一个当作空队列，一个把原始异常抛给调用方（`ConsumeService` → `MQCommandExecutor` → 客户端 `INTERNAL`）。影响：主题目录被外部清理/磁盘异常时，同一状态在「首次打开」和「读到一半」表现不同，客户端会间歇收到 `INTERNAL`；`allSegmentsMissingReturnsNone`（`GroupCursor_test.cj:445-458`）只覆盖开流分支，读中分支零覆盖。

### [一般] `ack` 不校验「是否真的投递过」，可确认一个尚未取走的分配项

- **位置**：`fmq/src/queue/GroupCursor.cj:290-310`（只判断 `decided`、位置相等、`owner` 归属，不判断 `entry.delivered`）
- **描述**：组内 s2 的分配项（`owner = s2, delivered = false`，扫描时为其它订阅创建，见 `:270`）在 s2 从未 `CONSUME` 到它的情况下，只要 s2 发出 `ACK(position)` 就会被接受并推进 `committed`。影响：与 `详细设计.md:687-691` 的 ack 口径及 `consume-semantics/spec.md:116-134` 的「只接受属于本游标且属于该订阅的位置」存在偏差；客户端一旦复用/重放旧 `ACK`，会推进一个尚未投递的位置，导致消息对该组静默消失（at-least-once 退化为 at-most-once）。现有用例只覆盖「他人已取走」的情形。

### [一般] 游标落盘没有 fsync，「重启后能读回最后一次写入的值」在掉电场景下不成立

- **位置**：`fmq/src/queue/CursorStore.cj:84-93`（`File.create(tmp)` → `write` → 直接 `rename`，无 `flush`/`fsync`，也不 fsync 父目录）
- **描述**：`write` 只到页缓存，`rename` 是原子替换但内容可能尚未落盘；掉电后 `.cursor` 可能是 0 字节/半条记录（`load` 返回 `None`，位点回到 `(1,0)`，整主题重投）或回退到上一个值。影响：`queue-storage/spec.md:93-113` 明确要求「重启后 SHALL 能读回最后一次写入的值」；每次 `advance` 都写盘说明设计取向是「消息不丢优先」，但没有 fsync 使该保证只对进程崩溃成立、对机器掉电不成立，而现有用例只能验证进程内语义。

### [一般] `QueueManager.openTopic` 是「先查后插」的非原子操作，并发下会泄漏 `QueueLog` 并多开一个段

- **位置**：`fmq/src/queue/QueueManager.cj:65-77`（`if (topics.contains(topic)) return` … `topics.add(...)`）
- **描述**：两个线程同时进入时都可能通过 `contains` 检查，各自为同一批队列构造 `QueueLog`（构造 `SegmentedLog` 会**立即建一个新段文件**），随后 `topics.add` 对已存在的 key 失败抛异常，先建的那批 `QueueLog` 既没被登记也没被关闭（mmap 与 fd 泄漏 + 目录里多一个空段）。影响：设计文档与用例都只描述「重复调用为空操作」，没有覆盖并发；当前注册路径经 `MetaStore.applyTopic` 的互斥大多能挡住重复注册，但这属于「靠上游巧合」，且 `openTopic` 中途抛错（如磁盘错误）时同样留下未关闭的日志对象。

### [一般] `详细设计.md` 的队列章节与实现多点不一致，其中「投递后 `target = None`」与 ack 归属校验直接矛盾

- **位置**：`fmq/doc/详细设计.md:664`（`entries` 写作 `TreeMap`，实现为 `ArrayList`）、`:673`（「命中：`target = None`」，实现保留 `owner = 订阅 id`）、`:372`（`sweep` 签名不符）、`:366`（`next` 两参实为三参）、`:350-355`（`DeliveryRecord` 缺 `next`/`decided` 字段）、`:753`（列出的 `GroupCursor.sweep` Timer 不存在）；对照 `fmq/src/queue/GroupCursor.cj:57`、`:160-163`、`:333`、`:110-111`
- **描述**：`:673` 的 `target = None` 若照做，`ack` 的「owner 是别人则拒绝」（`:690`，`GroupCursor.cj:296-300`）就失去依据——当前是实现对、文档错。`:753` 的定时器缺失会让读者以为「断链订阅的分配项有兜底定时清理」，实际只在同组有人消费时才清理。`entries` 结构漂移掩盖了性能问题，签名漂移会让按文档写的调用方直接编译失败。

### [一般] `ackTimeout` 没有正数校验，配成 0/负数时同一位置会被无限重投并饿死后续消息

- **位置**：`fmq/src/config/MQConfig.cj:68-72`（`getDuration(...) ?? DEFAULT`，`validate()` 只校验 `deadMsgThreshold`，见 `:249-251`）、判定点 `fmq/src/queue/GroupCursor.cj:130`
- **描述**：`ackTimeout <= 0` 时，刚投递出的未决项在下一次 `next` 立刻满足「已超时」，队首位置会被连续重投（`deliverCount` 很快越过阈值 → 直接进死信），后续消息长期得不到调度。影响：配置层无任何拦截，属于「一个合法写法的配置项把队列打成重复投递风暴」；`validate` 对其它几项（`deadMsgThreshold`、`delayingMs`、`backup`）都有显式校验，此处遗漏。

### [一般] 传给 `sweep` 的「活跃订阅」包含已断链订阅，断链名下的分配项要等巡检周期才可能被退回

- **位置**：`fmq/src/server/ConsumeService.cj:71-75`（`active = subscribers.activeIds(...)` 后立刻 `cursor.sweep(active)`）、`fmq/src/server/SubscriberRegistry.cj:159-171`（`activeIds` 不判断 `isDisconnected()`；对照 `MQServer.cj:157-166` 的巡检会先判断）
- **描述**：连接断开后、`cleanupSubscribers` 巡检运行前，`sweep` 认为断链订阅仍「活跃」，因此不会复位其名下的 `owner`，这段时间里同组其它订阅者拿不到这些记录。影响：规格「连接断开时其名下已分配未确认的记录 SHALL 退回组内」在时间上被延迟到一个巡检周期；叠加「组内只剩断链订阅」时该组整体空转。`sweepReleasesInactiveOwner` 用手工构造的 id 数组覆盖 `sweep` 本身，未覆盖「`activeIds` 真实包含断链订阅」这一上游缺陷。

### [一般] 规格场景与关键分支缺用例（含「测试无法发现段清理/长度头/Unsupported 缺陷」的证据）

- **位置**：`fmq/src/queue/*_test.cj`（共 54 条）
- **描述**：12 类场景零覆盖：被真实游标引用则保留段（仅 `LogCleaner_test.cj:88` 用假回调）、长度头损坏/越界、`Unsupported` BODY 在消费侧的行为、跨组各自消费、组内无人在线时 `committed` 不前进（`GroupCursor.cj:113` 的 `groupMembers.size == 0` 分支）、从中间记录位置开流、`scanAfter`/`countAll`/`segmentsOrEmpty`（`QueueLog_test` 零覆盖）、`MAX_RECORD_SIZE` 拒绝、死信损坏尾与 `deadMsgTTL` 边界（`== ttl`）、`openTopic` 关闭后重新打开保留消息、topic/tags 解码失败 → `NoMatch`、并发 `committed` 单调性（`concurrentNextAndAckProduceUniquePositions` 只断言 `seen.size == 200`）。影响：三个严重问题全部落在这些盲区里，说明用例是「按实现写」而不是「按规格写」，`GroupCursor_test` 22 条主要覆盖 happy path + 超时/死信/延迟，异常与规格边界几乎空白。

### [一般] `consume-semantics` 规格自相矛盾，「组内无匹配」到底越过还是保留没有唯一解释，用例固化了其中一种

- **位置**：`fmq/doc/spec/add-fmq-message-queue/specs/fmq/consume-semantics/spec.md:136-149`（Requirement 正文要求「保留该位置为未决，**不得跳过推进**」；同一 Requirement 的 Scenario「组内无匹配」却要求「标记为『不适用』并**允许越过**」）、实现 `fmq/src/queue/GroupCursor.cj:277-280`、用例 `GroupCursor_test.cj:288-303`
- **描述**：正文与 Scenario 给出相反要求；实现按 Scenario 执行（建 `decided = true` 的项并推进 `committed`），用例 `unmatchedRecordIsSkippedAndCommitted` 还把这一行为固定下来。影响：文档层面无法判定「消息该不该保留」——按正文实现，则「组内订阅 tags 永远不匹配某条消息」会让该组永久停摆（没有出口）；按 Scenario，则后加入组的匹配订阅永远看不到此前被越过的消息。必须由规格拍板，否则后续任何改动都会被判「违反规格」。

## R5

### [严重] 生产路径没有任何退出钩子，`MQServer.close()` 不可达：备份末批丢弃、关闭顺序形同虚设

- **位置**：`fmq/src/server/MQServer.cj:121-127`（`run()` 只有 `while (!closed.load()) sleep(500ms)`）、`:130-133`（`closed` 仅由 `close()` 置位）、`:152-154`（`isClosed()` 无外部调用方）、`fmq/src/main.cj:71-83`（`runServer()` 直接 `server.run()`）
- **描述**：`fmq server` 的退出路径只有「进程被信号杀死」。`详细设计.md:490-491`、`:606` 明确要求 `close()` 由退出回调触发（`ExitCallbacks.toExitGracefully()` + `atExit`），但全仓 `fmq/src/**` 没有任何 `ExitCallbacks`/`atExit`/信号处理调用，因此 `MQServer.close()` 只可能被单元测试调用。影响：① SIGTERM/SIGINT 走默认处理直接终止，整条关闭链（停定时器 → `backup.close()` → `cleaner.close()` → `consume.close()` 各 `GroupCursor` 落盘 `committed` → `backupStore.close()` → `queues.sync()/close()` → `deadLetter.close()` → `meta.close()` → `registry.close()`）一次都不执行，与 server-runtime 规格「关闭时按相反顺序释放」直接矛盾；② `BackupReplicator.close()` 是唯一的「关闭前最后一次 flush」，不可达意味着 `backup > 0` 时最后一个 100ms 窗口内的在途批次（最多 64 条/批）必然丢失，与 `README.md:111-112` 承诺矛盾；③ `run()` 也不可能返回，退出码永远拿不到；④ `scripts/mq_e2e.sh` 的 cleanup 与停节点都用 `kill`，E2E 每次跑的都是「异常退出」路径，反而把崩溃式退出固化成默认行为。

### [一般] `close()` 无异常保护，任一环节抛错会中断后续释放且无法重试

- **位置**：`fmq/src/server/MQServer.cj:130-150`
- **描述**：`closed.compareAndSwap(false, true)` 置位后，`server.close()`、`timer.cancel()`、`backup.close()`、`cleaner.close()`、`consume.close()`、`queues.sync()`、`queues.close()`、`deadLetter.close()`、`meta.close()`、`registry.close()` 顺序裸调用，没有 `try/finally` 或逐项容错；`consume.close()` 内部会对每个 `GroupCursor` 调 `store.save`，文件系统异常即可中断整条链。影响：一旦中途抛错，`closed` 已为 true → 再次 `close()` 直接返回（CAS 失败），剩余资源（队列日志句柄、死信日志、元数据、peer 连接）永远不会释放；在退出钩子补齐后这将成为退出阶段的真实风险（退出码/落盘都可能不完整）。

### [一般] 「断链清理」规格场景零用例；清理依赖 2s 轮询，且与重订阅存在竞态

- **位置**：`fmq/src/server/MQServer.cj:157-169`（`cleanupSubscribers`）、`:117`（`Timer.repeat(2s, 2s)`）、`fmq/src/server/SubscriberRegistry.cj:174-182`（`infos()` 快照）
- **描述**：全仓测试中 `isDisconnected`/`cleanupSubscribers`/`断链` 无命中，server-runtime 规格的「连接关闭后订阅消失…同组其它订阅者能取到被释放的消息」没有任何用例覆盖。清理逻辑是「先取全量快照 → 逐个 `releaseSubscription` + `unregister`」，若在快照与 `unregister` 之间同一 `subscribedId` 已在新连接上重新 `SUBSCRIBE`（`MQCommandExecutor.cj:262-264` 用同一 id 直接覆盖登记），会误删新订阅并释放其名下在途记录。影响：断链后未确认记录只能等组内其他成员下一次 `consume` 时的 `sweep` 才释放，组内无其他在线成员时 `backlog` 与「组内无人在线则暂停」的语义无法区分；清理竞态会把正常重连的客户端打成「订阅不存在/消息丢失」，而这类缺陷当前无任何用例能发现。

### [一般] `acked` 指标不含 autoAck 投递；删除主题/组后计数器残留

- **位置**：`fmq/src/queue/GroupCursor.cj:176-178`（`autoAck` 投递后直接 `entry.decided = true`，不经过 `ack()`）、`:301-305`（`incAcked` 只在 `ack()` 内）、`fmq/src/server/ConsumeService.cj:184-192`、`fmq/src/metrics/MQMetrics.cj:27-28`（`counters` 无清理入口）、`fmq/src/server/MQCommandExecutor.cj:174-185`（删除时不触碰 metrics）
- **描述**：`autoAck = true` 的组每投递一条都推进 `committed`（`backlog` 归零），但 `acked` 恒为 0；`delivered` 正常累加。另一方面 `MQMetrics` 的键是 `topic\0group`，主题/订阅组被删除后计数仍在，同名重建会直接继承旧值。影响：`stats` 是本模块唯一运行期可观测面，`acked` 与 `backlog` 对 autoAck 组自相矛盾（`backlog=0` 而 `acked=0`），用 `acked/delivered` 判断消费进度会误判；删除重建后的残留值会掩盖真实流量（巡检会看到「刚建的组已 acked 1e6」）。

### [一般] `stats` 在扫描异常时静默给出 `backlog=0/lagMs=0`，且按「组 × 队列」重复全量扫描

- **位置**：`fmq/src/server/ConsumeService.cj:161-166`、`:157-179`；`fmq/src/queue/QueueLog.cj:125-126`（`catch (_: Exception) { return (0, None<DateTime>) }`）
- **描述**：段被并发清理、目录不可读、记录损坏等任何异常都被 `scanAfter` 吞成 `(0, None)`，`stats` 据此输出「无积压、无延迟」且不记日志，而 metrics 规格明确「指标必须与查询时刻的持久化状态一致，不得使用可能失真的估算值」——「读失败 = 0」正是失真值。另外 backlog/lag 对每个 `(topic, group)` 的所有本地队列各做一次全量扫描，组数 G、记录数 N 时是 O(G×N) 重复 IO。影响：故障被伪装成「消费跟上了」，是最容易被误信的假绿；大主题 + 多组时 `manager stats` 会长时间占满执行线程（无采样、无缓存）。

### [一般] 配置校验不足，非法值静默回落默认值

- **位置**：`fmq/src/config/MQConfig.cj:225-254`（`validate` 仅校验 `backup < 0`、`nodes` 为空、端口重复/缺失、`deadMsgThreshold < 1`）、`:98-108`（`segmentedLogMaxSize` 解析失败直接返回 `1G`）、`:62-66`（`port` 取值失败直接返回 2350）
- **描述**：`mqServer_segmentedLogMaxSize=-1G` 或 `0`、`mqServer_ackTimeout=0s`、`mqServer_deadMsgTTL=-1h`、`mqServer_segmentedLogTTL=0s` 全部能通过 `validate()`，负/零 `maxFileSize` 一路传到 `QueueLog`/`SegmentedLog`，把「启动期报错」推迟成「首次发布/首次轮转时行为异常」；解析失败（`not-a-size`、`port=abc`）静默回落默认值且无 WARN，`MQConfig_test.cj:82-85` 甚至把这个行为固化成期望。影响：配置错误无法在启动期暴露，与 `详细设计.md:597`「配置读取与校验 → 失败退出码 2」的承诺不符；最坏情况是「以为改了大段上限，实际没生效」。

### [一般] `MQConfig.parsePort` 自实现 host:port 解析，违反「统一复用 `MQHost`」的增量规格且与装配期语义不一致

- **位置**：`fmq/src/config/MQConfig.cj:216-222`（`parsePort` 自切 `:` + `UInt16.tryParse`）；对照 `fmq/src/cluster/NodeRegistry.cj:49-52`（`MQHost.parseHost`）；规格 `fmq/doc/spec/fix-fmq-verify-followups/specs/fmq/server-runtime/spec.md:7-19`
- **描述**：增量规格要求「`host:port` 解析 SHALL 位于 `f_mq.base`（`MQHost.parseHost`），`f_mq.client` 与 `fmq` 均复用它…端口为 0 或越界时返回 `None`」。`NodeRegistry` 已复用，但 `MQConfig.selfIndex`/`validate` 仍用自实现的 `parsePort`：接受 `h:0`（规格要求 `None`）、接受任意非空主机名（含非法字符）、只按端口字符串相等比较。于是 `mqClient_hosts="h:0,127.0.0.1:2350"` 时配置校验通过、`selfIndex` 定位成功，随后 `NodeRegistry` 构造抛 `IllegalArgumentException`。影响：配置校验结论不可信；同一份配置在两处判定不一致，`fix-…/server-runtime` 的「解析语义不变」Scenario 在 `MQConfig` 侧不成立，后续改 `MQHost` 语义会分裂成两套。

### [一般] `listTopics` / `listSubscribeGroups` 把服务端 `ERROR` 响应报成「无法连接消息队列服务」

- **位置**：`fmq/src/manager/MQManager.cj:263-269`（`requestSnapshot` 只用 `asPayload<MQMetaSnapshot>`，不判 `Command.ERROR`）、`:137-156`、`:158-179`（`case None => connectionFailed()`）
- **描述**：服务端对 `metaSync` 请求返回 `ERROR(MQResult(INTERNAL))`（如 `MQCommandExecutor.cj:154` 的 `unrecognized metaSync payload`）或返回非 `MQMetaSnapshot` 载荷时，`asPayload` 返回 `None`，manager 打印「错误：无法连接消息队列服务」并返回 1，而连接其实成功、错误原因被替换。影响：与 manager-cli 规格「SHALL 把服务端的 `MQResult.code != 0` 视为失败：打印错误码对应文案」不一致，排障会被误导去查网络/端口。

### [一般] 备份副本段没有任何清理路径，长期运行磁盘无界增长

- **位置**：`fmq/src/server/BackupStore.cj:38-42`（`root = <segmentedLogDir>/backup`，只创建、只 append）、`fmq/src/server/MQServer.cj:83`、`fmq/src/cluster/LogCleaner.cj:51-66`（只遍历 `queues.allLogs()` + `deadLetter`）
- **描述**：`LogCleaner.cleanOnce` 的清理对象只有本地队列段与死信段，备份目录（`<segmentedLogDir>/backup/<owner>/<topicEsc>/<queueIndex>/log_*.log`）不在任何 TTL 策略内；`BackupStore` 除了 `close()` 没有任何段管理入口，`segmentedLogTTL`/`segmentedLogMaxSize` 对备份段只影响单段大小。影响：`mqServer_backup > 0` 的部署（e2e 脚本就是 `backup=1`）每条消息额外落一份副本且永不删除，长时间运行必然写满 `segmentedLogDir` 所在分区，进而影响主队列写入。

### [一般] 关键分支与开发计划要求的用例缺失（含「只断言退出码」的弱断言）

- **位置**：`fmq/src/server/MQCommandExecutor_test.cj`、`fmq/src/server/MQServer_test.cj:122-129`、`fmq/src/server/ConsumeService_test.cj:294-328`、`fmq/src/server/MQManager_test.cj:95-114`、`:158-170`、`scripts/mq_e2e.sh`
- **描述**：七项缺口：① 内部 metaSync 变更分支（`applyRemote` → `queues.openTopic`、`applyRemoteGroup`、`applyRemoteDelete` + `cleanupAfterDelete`）无对应用例，只覆盖「请求 → 快照」；② 未知命令分支（`MQCommandExecutor.cj:85-88`）无用例；③ `publishWithBackupEnqueues` 缺失（`ExecutorFixture` 固定 `BackupReplicator(registry, 0)`，无替身，发布→备份入队零断言）；④ `closeReleasesResources` 只验端口重绑，未验队列 `sync`、订阅表清空、`close()` 幂等；⑤ `stats` 的 `redelivered`/`deadLettered` 与多队列分组聚合未在输出层验证；⑥ manager 输出零断言（只断言退出码，`registerTopicPrintsAssignment`、`listTopicsShowsQueueNum` 实际不存在）；⑦ E2E 全程未调用 `manager stats`、未校验备份目录落盘、未出现 `deleteTopic`/`deleteSubscribeGroup`。影响：复制落地、备份、断连与关闭这几条最容易坏的路径没有用例兜底，弱断言无法发现「渲染错列/错行」。

### [一般] 服务端成功启动路径不可测：`dispatch` 没有可注入的装配点，`run()/close()` 生产路径零单测

- **位置**：`fmq/src/main.cj:71-83`、`:36-69`；`fmq/src/server/MQServer.cj:121-127`
- **描述**：`开发计划.md:444` 要求「`dispatch(["server"])` 走 `MQServer`（测试里用可注入的装配点，断言被调用而不真正 listen）」，实现没有该注入点；`Main_test.cj:54-66` 只能测「配置非法 → 返回 2」，`dispatch(["server"])` 的合法路径一旦进入就永久阻塞；`MQServer.run()` 同样无法在用例中调用。影响：`main` 与 `MQServer` 的生产入口是唯一「零覆盖」的可执行路径，「`run()` 永不返回」「`close()` 不可达」这类问题在测试层完全隐形（与严重问题互为因果）；`MQConfigException` → 退出码映射之外的所有分发行为都只能靠 E2E 进程级观察。

### [一般] 文档与实现不一致（README 的命令行覆盖、详细设计的子命令数量 / 输出格式 / sweep 定时器）

- **位置**：`fmq/README.md:21`；`fmq/doc/详细设计.md:782-796`、`:846`、`:683-685`、`:753`、`:733`；`fmq/src/main.cj:36-45`
- **描述**：① README 称「配置项均可用环境变量或命令行参数覆盖」，但 `main.cj` 只认 `args[0]` 为子命令，`fmq --mqServer_port=2400 server` 会被判未知子命令返回 2（而 `Config` 已改端口），只有 `fmq server --mqServer_port=2400` 生效，文档未写该限制；② 详细设计仍写 6 个子命令与旧输出格式，实现已含 `stats` 共 7 个，输出为「…，延迟：0s，分配：0→A,1→B」；③ 线程模型表列的 `GroupCursor.sweep` Timer 不存在，`sweep` 只由 `ConsumeService.consume` 驱动；④ 「清理…调用 `removeByBuffer`」与实际 `infos()` + `isDisconnected()` + `unregister` 不符，`removeByBuffer` 无调用方。影响：运维会写出「看起来生效、实际返回 2」的命令；设计文档的线程表与子命令清单会误导后续维护者按错误基线改动。

## R6

### [一般] 断链清理整条 Requirement 零用例（含「连接断开清理」场景）

- **位置**：`fmq/src/server/MQServer.cj:157-169`（`cleanupSubscribers`）、`:117`（2s 定时器注册）
- **描述**：`cleanupSubscribers` 遍历 `subscribers.infos()`，对 `isDisconnected()` 的订阅执行 `consume.releaseSubscription` + `subscribers.unregister`。全仓 `*_test.cj` 对 `isDisconnected` / `disconnect` 的引用为 **0**，该方法为 `private` 且无用例触达。影响：这是 at-least-once 语义的关键兜底路径——若清理逻辑失效，断线订阅会永久占住记录，同组消费者永远取不到，形成静默的消息停滞，而现有全部用例都无法发现；且该路径涉及 `try/catch` 吞掉异常后仅记 WARN，错误会被完全隐藏。

### [一般] 客户端「关闭与调用并发」场景零用例

- **位置**：`f_mq/src/client/test/MQClient_test.cj:497-531`（`closeIsIdempotentAndBlocksApis`）
- **描述**：用例仅在 `close()` **返回之后**顺序调用 `publish/subscribe/consume/ack` 并断言 4 次 `MQConnectionException`；规格要求的是一线程 `close()`、其它线程持续调用公开 API 的并发场景。影响：`MQClient.close()` 先 `pool.close()` 再清空订阅表（`MQClient.cj:243-258`），与在途 `consume` 的 `subscriptionOf` / `deliveries.add` 存在真实竞态窗口，顺序用例无法暴露「关闭后仍向已释放连接写入」「订阅表遍历时被清空」这类崩溃或永久阻塞。

### [一般] 死信「组间隔离」与「条目字节完整」未断言

- **位置**：`fmq/src/queue/GroupCursor_test.cj:245-265`（`deliveryOverThresholdGoesToDeadLetter`）
- **描述**：用例只构造单组 `g`，断言条目数、`segmentedIndex`、`subscribeGroup`、`deliverCount`；未构造 A/B 两组对照验证「A 组进死信不影响 B 组消费」，也未校验死信条目保存的**原始记录字节**可完整读回。影响：`GroupCursor.writeDeadLetter` 把 `record` 原样写入 `DeadLetterQueue`，若记录被截断或组名写错，现有用例无法发现；而按组隔离是「一个组卡死不影响其它组」的核心保证。

### [一般] 详细设计的消费结果、ACK 载荷与 `MQMessage` 缺 `queueIndex`，与规格明文冲突

- **位置**：`f_mq/doc/详细设计.md:137`（`MQConsumeResult` 行）、`:138`（`ack` 行）、`:490`（`MQClient.ack` 签名）、`:276-281`（`MQMessage` 成员）
- **描述**：前两处与 §5.13 均写作 `segmentedIndex, segmentedOffset`，无 `queueIndex`；§5.3 的 `MQMessage` 也只列 5 个字段。而规格 `f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/protocol/spec.md:122` 明确 `MQConsumeResult{queueIndex, segmentedIndex, segmentedOffset, record}`，`:127` 明确「`MQAckPayload` SHALL 携带 `queueIndex`」；实现与 README 均为四元组。影响：详细设计是协议实现的直接依据，按该文档实现客户端会漏传队列身份，导致多队列主题下 ACK 串台（`ConsumeService.ack` 按 `payload.queueIndex` 精确 `queueOf`，缺失时为 0，会误确认 0 号队列）。

### [一般] 详细设计 §5.1 的 `MQTopicMeta` 缺 `delayingMs`

- **位置**：`f_mq/doc/详细设计.md:253-256`
- **描述**：成员仅 `topic`、`queueNum`；实现 `MQTopicMeta.cj:29` 已有 `delayingMs`（构造器默认 0，`:33`），规格 `add-fmq-metrics-and-delay` 的「主题延迟字段」要求该字段随注册载荷传递。影响：§5.1 是「规格给定」的类型清单，缺字段会让人误以为延迟只能走 manager 侧解析、不能随 `REGISTER` 传输；实际 `MQAssignment`/`MetaSyncer`/`MetaStore` 全链路都依赖它。

### [一般] `tasks.md` 六项遗留任务全部已完成但未勾选

- **位置**：`f_mq/doc/spec/add-fmq-message-queue/tasks.md:156-161`
- **描述**：11.1–11.6 六项均为 `- [ ]`，逐项核对后全部已落地：11.1 `MQManager_test.cj`（8 例）、11.2 BODY 容器矩阵、11.3 备份定时 flush 与并发关闭、11.4 消除 `fmq → f_mq.client`（grep 0 命中）、11.5 4 字节前缀文档化、11.6 远端分配推进指针。影响：`tasks.md` 是项目唯一的实施进度台账，6/6 失真会让后续审查反复复查已完成项（本轮即为此消耗），也会掩盖真正的新增缺口。

## 统计

| 轮次 | 严重 | 一般 | 小计 |
| --- | --- | --- | --- |
| R1 | 2 | 8 | 10 |
| R2 | 1 | 13 | 14 |
| R3 | 4 | 15 | 19 |
| R4 | 3 | 11 | 14 |
| R5 | 1 | 11 | 12 |
| R6 | 0 | 6 | 6 |
| **合计** | **11** | **64** | **75** |

> 说明：R1 原文「本轮统计」表记为「一般 6」，但正文实际标记为 `[一般]` 的条目共 8 条，本表以正文条目数为准（差异 2 条为「`publish(record, id!)` 无用例」与「`详细设计.md` 与实现不一致」，原文统计表未计入）。
