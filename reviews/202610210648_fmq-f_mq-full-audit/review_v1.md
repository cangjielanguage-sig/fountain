# R1: f_mq 基础层（协议编解码 / 常量 / 载荷 / 消息记录 / 错误码 / 模型）

审查时间：2026-10-21 06:48（全树审计，只读，HEAD 5a133474）

### 审查范围

代码（46 个 `.cj` 中属于 base 的 33 个）：

- `f_mq/src/base/`：`MQProtocol.cj`、`MQConstants.cj`、`MQMessageRecord.cj`、`MQFilter.cj`、`MQHost.cj`、`MQTopic.cj`
- `f_mq/src/base/model/`：`MQMessage.cj`、`MQMessageContent.cj`、`MQSubscribeGroupMeta.cj`、`MQTopicMeta.cj`
- `f_mq/src/base/payload/`：`MQAckPayload.cj`、`MQBackupPayload.cj`、`MQBackupState.cj`、`MQConsumePayload.cj`、`MQConsumeResult.cj`、`MQDeadLetterMessage.cj`、`MQDeregisterPayload.cj`、`MQInternalMessage.cj`、`MQMetaSnapshot.cj`、`MQMetaSyncRequest.cj`、`MQResult.cj`、`MQSubscribePayload.cj`、`MQTopicAssignment.cj`、`MQUnsubscribePayload.cj`
- 测试（8 个 `*_test.cj`，共 54 个 `@TestCase`、252 处 `@Assert`）：`MQProtocol_test.cj`、`MQMessageRecord_test.cj`、`MQPayload_test.cj`、`MQModel_test.cj`、`MQFilter_test.cj`、`MQErrorCode_test.cj`、`MQHost_test.cj`、`MQTopic_test.cj`

文档：

- `f_mq/doc/详细设计.md`（§3 协议与记录格式、§4.1 顶级声明、§5.1–5.11a）
- `f_mq/doc/开发计划.md`（A6/A7）
- `f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/protocol/spec.md`
- `f_mq/doc/spec/add-fmq-metrics-and-delay/specs/f-mq/protocol/spec.md`
- `f_mq/doc/spec/fix-fmq-verify-followups/specs/f-mq/protocol/spec.md`
- `openspec/specs/f-mq/protocol/spec.md`（合并后的主规格）
- `f_mq/README.md`、`f_mq/README_en.md`

参照实现（只用于确认契约，不计入审查对象）：`f_protocol/src/default/MessageID.cj`、`f_codec/src/default/DefaultCodec.cj`、`f_data/src/base/{CollectionData,MutableField,DataObject,NumberData,global_objects}.cj`、`fmq/src/server/MQCommandExecutor.cj`、`f_mq/src/client/MQClient.cj`。

### 发现

#### [严重] 超过 4096 字节的记录经「对象载荷」传输时被静默降级为空数组——大消息永远消费不到

- **位置**：
  - `f_mq/src/base/payload/MQConsumeResult.cj:32`（`private var record: Array<Byte> = []`）
  - `f_mq/src/base/payload/MQBackupPayload.cj:28`（`records: Array<Array<Byte>>`）、`MQInternalMessage.cj:32`（`payload: Array<Byte>`）、`MQDeadLetterMessage.cj:35`（`record: Array<Byte>`）
  - `f_mq/src/base/MQProtocol.cj:189-191`（`asConsumeResult`）、`:143-145`（`asRecord` 走的 `MQBytes` 路径只保护了 publish 一种形态）
  - 相关测试盲区：`f_mq/src/base/MQProtocol_test.cj:72-79`、`MQPayload_test.cj:100-115`
- **现象**（代码链路，逐段可核）：
  1. `DefaultCodec` 解码 `INPUTSTREAM` 片段时，`size > fileThreshold`（默认 4096，`f_codec/src/default/DefaultCodec.cj:51-52`）会落临时文件并返回 `DataInputStream`（同文件 `:962-966`、`:994-1035`），而不是 `Array<Byte>`。
  2. `MQConsumeResult` / `MQBackupPayload` / `MQInternalMessage` / `MQDeadLetterMessage` 里的字节字段是**对象字段**，解码时由 `MutableField.new` 的 setter 用 `convert<F>(data, flag: SILENCE)` 转换（`f_data/src/base/MutableField.cj:44-95`）。
  3. JSON 式的 `Array<UInt8>.tryFromData(DataInputStream, SILENCE)` 走 `case _` 分支 → `UInt8.tryFromData` 返回 `None` → 最终返回**空数组**（`f_data/src/base/CollectionData.cj:75-97`、`NumberData.cj:59-90`）。全程不抛异常、不告警。
  4. 于是 `MQProtocol.asConsumeResult` 得到 `record.size == 0`，而 `record` 为空正是协议里「本次没有消息」的哨兵（`MQConsumeResult.cj:22`、`:43-45`）。客户端 `MQClient.consume` 见 `record.size == 0` 就 `continue` + `sleep` 再轮询（`f_mq/src/client/MQClient.cj:181-195`），服务端每次仍返回同一条记录 ⇒ **consumer 永久阻塞，游标不推进，同组其它订阅者也被卡住**。
  5. 同一机制使 `MQInternalMessage.payload`（备份批次 ≥ 4KB 时必然触发）在 `asInternal` 阶段变成空数组，`decodePayload<MQBackupPayload>([])` 返回 `None` ⇒ 服务端回 `INTERNAL`（`fmq/src/server/MQCommandExecutor.cj:100-110`、`:186-200`），**大消息的副本永远不会落盘**，故障切换即丢数据。
  6. 另外，`decodeData` 已经创建了 `/tmp/tmpFile<UUID>/`，而该 `DataInputStream` 被静默丢弃，没有任何路径清理它 ⇒ **每次解码大载荷都泄漏一个临时文件/目录**。
- **影响**：单条记录编码后超过 4096 字节（body 约 4KB 即触发）时：用户消息收不到（阻塞而非报错）、备份/死信/内部信封的数据静默丢失、`/tmp` 持续增长。这是数据正确性问题，且被「空 record = 无消息」的哨兵语义完全掩盖，没有任何日志或错误码。
- **建议**：
  - 提供 `Array<Byte>` 字段的 `@DataConverter`（`MutableField.new` 在 `convert` 返回 `None` 时会回退到 `ReadableField.tryGetAnnotation<DataConverter<F>>`，见 `MutableField.cj:73-81`），在转换器内部对 `DataInputStream` 调用 `MQBytes.fromData`（并在读后清理临时文件）；把该注解加到 `MQConsumeResult.record`、`MQBackupPayload.records`、`MQInternalMessage.payload`、`MQDeadLetterMessage.record`。
  - 或在 `MQProtocol.asConsumeResult` / `asInternal` 落地后做一次「字段为空 + 原始对象对应字段是 `DataInputStream`」的一致性校验，宁可回 `INTERNAL` 也不要把大消息当成「没消息」。
  - 必须补用例：`body = 5KB` 的 `publish → respond<MQConsumeResult> → 帧往返 → asConsumeResult → MQMessageRecord.decode` 全链路；以及 `MQBackupPayload` / `MQInternalMessage` 大子载荷的入口校验（4KB 附近取 4095/4096/4097 三点）。当前没有任何 >4KB 的**消费/备份**用例，只有 publish 大记录用例，见下一条。

#### [严重] `publishTime` 的「UTC 23 位」与 `MessageID.toString()` 实际写入的本地时间不一致，跨时区部署时延迟投递与滞后统计整体偏移

- **位置**：`f_mq/src/base/MQMessageRecord.cj:99-129`（注释 `:101`、`:124` 的推理与结论自相矛盾）；取证：`f_protocol/src/default/MessageID.cj:39-41`；文档断言 UTC：`f_mq/doc/详细设计.md:458-459`、`openspec/specs/f-mq/protocol/spec.md:286-294`；用例：`MQMessageRecord_test.cj:144-148`
- **现象**：`MessageID.toString()` 用 `time.format("yyyyMMddHHmmssSSS")` 输出，`DateTime.now()` 是**本地时区**实例（同模块 `f_codec/src/default/DefaultCodec.cj:520-525` 的注释明确说明「本地时间会多算一个 UTC 偏移」），所以记录里的 23 位是**生产者的本地墙钟**。而 `publishTime` 按规格「按 UTC 解析」：`DateTime.parse` 以本地时区解释后再加上 `parsed.zoneOffset`（`:122-125`），得到的是「把这串数字当 UTC」的时刻。二者只在生产者时区为 UTC 时相等：`Asia/Shanghai` 的客户端写入 `20261018183000...`（本地 18:30 = 10:30Z），服务端 `publishTime` 得到 18:30Z，比真实发布时间晚 8 小时 ⇒ `now - publishTime` 为负，延迟投递会**多等一个时区偏移**（`fmq/src/queue/GroupCursor.cj:425`、`QueueLog.cj:116` 用它算到期时间/滞后）；两个不同时区的客户端产生的 messageId 也不可比。
  反过来，`MQMessageRecord.cj:124` 的注释写「parse 按本地时区解释，时间戳本身是 UTC：加回本地偏移得到 UTC 时刻」——若时间戳真是 UTC，加偏移就是错的；这句注释恰好说明作者知道 `parse` 是本地语义，却把「生产者写的也是本地」这一点漏掉了。
- **影响**：非 UTC 部署（生产服务器常用 `Asia/Shanghai`）下延迟消息的到期判定、`lagMs`/backlog 统计整体偏移，且偏移量随客户端时区漂移；现有用例在 UTC 环境下通过（`format` 断言），在 +08 环境下该断言本身会失败，说明用例也依赖环境时区。
- **建议**：统一口径——二选一：(a) `MessageID.toString()` 改用 `time.inUTC().format(...)`，并保持 `publishTime` 按 UTC 解析；(b) 若不能动 `f_protocol`，则 `publishTime` 改为 `DateTime.parse(stamp, ...)` 直接返回（按本地解释），并把设计/规格从「UTC」改为「生产者本地时间」。选定后补一条跨时区用例（例如注入 `DateTime` 或断言 `publishTime` 与构造 messageId 时使用的 `DateTime` 相等，而不是断言字符串往返）。

#### [一般] `decodePayload<T>` 只对 `SimpleDataObject` 做类型校验，标量/其它载荷会被静默转成「默认对象」

- **位置**：`f_mq/src/base/MQProtocol.cj:210-236`（校验分支在 `:219-225`，转换在 `:226-230`）
- **现象**：类型守卫只覆盖 `case o: SimpleDataObject`；若 `payload` 字节解出来是 `DataString` / `DataReal` / `DataNone`，直接落到 `T.tryFromData(data, SILENCE)`。`SILENCE` 下 `DataObject<T>.populate` 对非可迭代输入走 `case _ => target`（`f_data/src/base/DataObject.cj:194-206`），即返回**字段全默认值的 `T`**，而不是 `None`。因此 `metaSync` 信封里塞一个字符串/整数，`decodePayload<MQMetaSyncRequest>` 会返回 `Some(MQMetaSyncRequest(-1))`，服务端按「合法的快照请求」处理并回全量快照（`fmq/src/server/MQCommandExecutor.cj:137-142`）；同样的宽松转换会让 `decodePayload<MQTopicAssignment>` 得到 `topic=''`、`owners=[]` 的分配结果，一旦分支顺序调整就会把空主题应用到元数据里。
- **影响**：与函数注释「类型不匹配返回 `None`」不符；恶意/错误载荷不会被拒绝，而是触发正常业务分支。没有用例覆盖（见下条）。
- **建议**：把守卫改成「解出的 `data` 必须与 `TypeInfo.of<T>()` 精确一致，否则 `None`」，即对非 `SimpleDataObject`（`T` 为对象时）直接 `return None<T>`；或对 `T.tryFromData` 传 `IGNORE_FIELD_NOT_CONVERTABLE` 之外的更严格 flag（不用 `SILENCE`）。补 `decodePayload` 的负向用例：空字节、随机字节、`encodePayload<String>` 后按对象解、对象 A 按对象 B 解。

#### [一般] `MQMessage.get<T>()` 对空 BODY / 异类型对象 BODY 返回「字段全默认的对象」，与文档契约相反

- **位置**：`f_mq/src/base/model/MQMessage.cj:53-63`（注释在 `:49-52` 声明「BODY 为空或类型不匹配时返回 `None`，不抛异常」）；用例盲区 `MQModel_test.cj:64-94`
- **现象**：`get<T>` 只处理 `body == None` 的情况；当 `body = Some(DataAny(DataNone))`（发布空 BODY 的记录，客户端经 `MQMessageContent.toMessage` 一定会变成这种形态，见 `MQMessageContent.cj:31-33`）或 `body` 是**另一个** `@DataAssist` 类型时，`convert<T>` 在 `SILENCE` 下返回默认对象而不是 `None`：`DataObject.populate(DataNone)` → `case _ => target`（`DataObject.cj:194-206`），字段不匹配时 `set` 也会静默跳过（`MutableField.cj:44-95` + `DataObject.cj:117-126`）。现有用例只验证了「对象 BODY 取标量返回 `None`」，恰好绕开了这条路径。
- **影响**：业务侧 `msg.get<Order>()` 会拿到一个 `id=0/title=''` 的「空订单」并当成真实消息处理（静默错误数据），而不是 `None`；异类 BODY 也表现为全默认值，掩盖了类型不匹配。
- **建议**：`get<T>` 里先做与 `MQProtocol.asPayload` 相同的运行时类型判断（`body.data` 是 `SimpleDataObject` 时比较 `typeInfo`），再 `convert`；对 `DataNone` 直接返回 `None<T>`。补用例：`DataNone` BODY 取对象、对象 A 取对象 B、对象 BODY 取标量（已有）。

#### [一般] 错误码 `INVALID_GROUP`（6）没有任何产生路径，订阅组名校验整体缺失

- **位置**：`f_mq/src/base/MQConstants.cj:30`；规格 `openspec/specs/f-mq/protocol/spec.md:156`；服务端入口 `fmq/src/server/MQCommandExecutor.cj:230-250`（只校验主题存在/组存在，不校验组名）
- **现象**：全仓库（`f_mq/src` + `fmq/src`）对 `MQErrorCode.INVALID_GROUP` 的引用数为 0；base 层也没有对标 `MQTopic.isValid` 的组名校验工具（`MQTopic.cj` 只有 topic 版）。`MQSubscribeGroupMeta` / `MQSubscribePayload.subscribeGroup` 可以是任意字符串（空串 = 默认组），`fmq manager registerGroup` 同样不校验。
- **影响**：错误码表是对外契约（`:21` 注释、规格要求数值稳定），但第 6 号是死码；非法组名（含空白、`:`、路径分隔符等）会被写进元数据并落到 `metas/` 目录文件名里，只能靠下游文件名编码兜底，错误契约形同虚设。
- **建议**：新增 `MQGroup.isValid(name)`（空串合法 = 默认组；非空时禁空白/控制字符/`/` 等），在 `fmq manager registerGroup` 与客户端 `subscribe` 本地快速失败处调用并返回 `INVALID_GROUP`；补正/负向用例，并在 `MQErrorCode_test` 中增加「每个码至少有 1 条产生路径」的守护说明。

#### [一般] `metaSync` 的三个重载与内部子载荷解码分支没有用例，`metaSync(MQDeregisterPayload)` 映射到 `DEREGISTER` 无人守护

- **位置**：`f_mq/src/base/MQProtocol.cj:82-97`；用例 `MQProtocol_test.cj:40-58`（只测 `metaSync(MQMetaSyncRequest)` 的命令）、`:149-165`（只测 `MQTopicAssignment` 与 `MQBackupPayload` 的子载荷解码）
- **现象**：`metaSync` 有 4 个重载，分别产出 `REGISTER`/`REGISTER`/`REGISTER`/`DEREGISTER`；`factoriesUseExpectedCommands` 只覆盖第一个，`internalEnvelopeCarriesSubPayload` 只覆盖 assignment 与 backup。`MQInternalKind` 与子载荷类型的组合中，`MQSubscribeGroupMeta`、`MQDeregisterPayload`、`MQMetaSyncRequest`、`MQMetaSnapshot` 四种没有任何「编码→解码→类型/字段」级断言，`decodePayload<MQMetaSyncRequest>` 也没有正向用例。生产代码却在用它们（`fmq/src/cluster/MetaSyncer.cj:162-166`、`MQCommandExecutor.cj:137-165`）。
- **影响**：唯一映射到 `DEREGISTER` 的内部广播（删除同步）若写错命令，现有用例全绿；`metaSync` 信封的 4 个解码分支只测了 1 个，回归不可见。这也与 `f_mq/doc/开发计划.md:174`（“对每个构造函数：帧往返”）的要求不符。
- **建议**：补 4 条 `metaSync` 命令断言 + 4 条 `encodePayload/decodePayload` 往返（包含 `MQMetaSnapshot` 嵌套）+ 1 条「未知 kind 返回 `INTERNAL`」用例；把 `MQProtocol_test` 的帧往返改成表驱动，覆盖全部工厂。

#### [一般] 16KB 大记录用例没有验证「确实走了临时文件形态」与「临时文件已清理」，正好掩盖了上面第一条缺陷

- **位置**：`f_mq/src/base/MQProtocol_test.cj:72-79`；对应计划要求 `f_mq/doc/开发计划.md:176`；规格场景 `openspec/specs/f-mq/protocol/spec.md:71-74`
- **现象**：用例只断言 `record.size > 16 * 1024`（由 `big` 的构造必然成立，等于同义反复）、帧往返后字节相等。既没有断言 `MQProtocol.asRecord` 走的是 `DataInputStream` 分支（`MQBytes` 的另一半逻辑无人验证），也没有断言临时目录被删除（计划里明确写了「且临时目录已清理」）；`MQMessageRecord_test.cj:230-266` 只对 `MQBytes` 做了单独验证，没有覆盖「同一条消息的载荷被解两次」这种非幂等场景。
- **影响**：`fileThreshold` 相关的所有行为（临时文件形态、清理、二次读取）在协议层没有守护，S1 描述的降级因此完全不可见。
- **建议**：用例中断言 `message.data` 的运行时类型是 `DataInputStream`（构造前后对比 `/tmp` 目录数），并在 `asRecord` 之后断言临时目录消失；另加一条「`asRecord` 调用两次，第二次返回 `None`」把这个已知限制显式化（或改成非破坏性实现，见建议 T1）。

#### [一般] `publish(record, id!)` 重载没有任何用例，帧 id 与记录 `MESSAGE_ID` 的一致性无守护

- **位置**：`f_mq/src/base/MQProtocol.cj:33-39`；用例 `MQProtocol_test.cj:43`、`:63`、`:77`、`:94` 全部走无 id 版本；生产使用点 `f_mq/src/client/MQClient.cj:77`
- **现象**：带 id 的重载是「记录内的 MESSAGE_ID 与帧头 `Message.id` 取同一个值」的唯一实现（设计 §3.2 的明确约定），客户端 publish 全部走这条路，但 base 层没有任何断言 `message.id == mid`、也没有断言该 id 在帧往返后仍与记录里的 `MESSAGE_ID` 相同；`publishTime` 恰好依赖记录里的这个字符串。
- **影响**：若有人把 `Message.build` 换成 `Message.publish`（生成新 id），单测全绿，但记录 messageId 与请求 id 脱钩，排障对不上号、延迟计算依赖的 id 来源也会漂移。
- **建议**：补一条用例：`let mid = MessageID(); let m = MQProtocol.publish(record, id: mid); @Assert(m.id == mid)`，并做帧往返后断言 `MQMessageRecord.messageId(asRecord(decoded)) == mid.toString()`。

#### [一般] `详细设计.md` 与当前实现多处不一致（字段、签名、kind 数量、分派表）

- **位置**：`f_mq/doc/详细设计.md`
  - `:128` register 主题载荷字段只写 `topic/queueNum`，缺 `delayingMs`
  - `:137` consume 响应字段缺 `queueIndex`；`:138` ack 载荷缺 `queueIndex`（与规格「ACK 必须携带队列身份」冲突）
  - `:158`「`MQInternalMessage.kind` 目前有两种」，实际有三种（`:217` 同样只列 `metaSync`/`backup`，与 `MQConstants.cj:76-78` 不符）
  - `:153` 分派表声称所有 MQ 载荷类都能被 `kindOf` 分派，实现只认 `TopicMeta`/`GroupMeta`/`Internal`，其余一律 `Unknown`（`MQProtocol.cj:127-137`）
  - `:195-223` §4.1 顶级声明总表缺 `MQHost`（`:469-472` 才出现）
  - `:252-258` §5.1 `MQTopicMeta` 代码块缺 `delayingMs`；`:275-291` §5.3 `MQMessage` 代码块缺 `queueIndex`（README 的 `ack` 示例已经在用 `message.queueIndex`）
  - `:301-308` §5.4 `MQMessageContent.toMessage` 少一个 `queueIndex` 参数（实现是 3 个参数，`MQMessageContent.cj:31`）
  - `:420-444` §5.11 `MQProtocol` 签名清单缺 `stats`、三个 `metaSync` 重载、`publish(record, id!)`、`publishTime`（`publishTime` 只出现在 §5.11a）
  - `:450-451` 称 `asRecord` 内部用 `convert<Array<Byte>>` 并「拒绝非原始字节块」，实现已改为 `MQBytes.fromData`（`MQProtocol.cj:143-145`）
- **现象/影响**：设计文档是 R1 的判定依据之一；这些条目会让读者误判协议字段（尤其 `queueIndex` 缺失，正好是历史上修过的多队列 ACK 缺陷），也会让后来者按旧签名写代码。
- **建议**：按当前代码整体刷新 §3.3、§3.4、§4.1、§5.1/5.3/5.4/5.11；或在文档开头标注「§3.3/§5.11 为初版快照，字段以代码为准」并指明差异表。

#### [一般] `MQDeregisterPayload.isTopic()` 不校验 `kind`，未知/拼错的 kind 被当成「删订阅组」

- **位置**：`f_mq/src/base/payload/MQDeregisterPayload.cj:40-42`；消费方 `fmq/src/server/MQCommandExecutor.cj:175-185`（`cleanupAfterDelete`）
- **现象**：`isTopic()` 只做 `kind == "topic"`；`kind` 为 `""`、`"Topic"`、`"subscriber"` 等值时一律返回 `false`，调用方据此走「删组」分支（`consume.removeGroup` / `subscribers.removeByGroup` / `cursors.removeGroup`），静默删掉订阅组而不是报错。默认值 `kind = ''`（`:27`）会直接落入该分支。
- **影响**：一个拼错的删除请求会误删组、且不返回任何错误；结合上一条「默认对象」问题，空 `MQDeregisterPayload` 也能造成删除。
- **建议**：增加 `isGroup()` 并在 `MQDeregisterPayload` 中提供 `kindOf()` 三态（Topic/Group/Unknown），服务端对 Unknown 回 `INTERNAL`（或新增参数错误码）；补用例：`kind="Topic"`、`kind=""`、`kind="group"` 三态。

#### [建议] `MQBytes.fromData` 是破坏性操作且异常路径不清理临时文件

- **位置**：`f_mq/src/base/MQMessageRecord.cj:187-240`（正常路径 `:215-231`，异常路径 `:232-239`）
- **现象**：读取成功即 `close()` + 删除文件与父目录，对同一个 `Message` 第二次调用 `asRecord` 会返回 `None`；`catch` 分支只 `close()`，不删 `/tmp/tmpFile<UUID>/`。文档只在 `:182-185` 说明了「读回后删除」，没有说明不可重复调用。
- **影响**：任何「先 `kindOf`/日志取一次、再取一次」的调用序都会静默失败；读失败时残留目录。
- **建议**：把清理放进 `finally`；在注释里显式标注「消费型 API，同一 Message 只能取一次」，或缓存首次结果/改为不删（由调用方释放）。

#### [建议] `publishTime` 存在不可达分支，且缺「23 位但非数字/非法日期」用例

- **位置**：`f_mq/src/base/MQMessageRecord.cj:109-121`；用例 `MQMessageRecord_test.cj:150-154`
- **现象**：`split` 的结果至少 1 个元素，`parts.size == 0` 永远为假；负向用例只有 `mid-1` 与 `a_b_2026` 两种「长度不足」，没有覆盖「长度 23 但含非数字」（如 `...X`）与「23 位数字但日期非法」（如 `20261399999999999999999`）。
- **影响**：数字校验与 `DateTime.parse` 的 catch 分支无人验证，回归不可见。
- **建议**：删掉不可达分支；补两条负向用例（非数字、非法日期）。

#### [建议] 三处 `@Assert(true)/(false)` 模式断言可以写成直接断言

- **位置**：`MQProtocol_test.cj:47-48`、`:105-106`；`MQMessageRecord_test.cj:178-179`
- **现象**：这些是 `match` 分支里的恒真/恒假断言，实际判定靠「模式是否命中」，不是空断言，但可读性差、也容易被后续重构削弱。同类文件里已有 `commandIs(...)` 辅助函数。
- **影响**：只影响可读性与可维护性；不算空用例。
- **建议**：改为 `@Assert(commandIs(msg, CONSUME(...)))` / `@Assert(response.command == Command.RESP(0))`；`DataNone` 判断可写成 `@Assert(content.body.data is DataNone)`。

#### [建议] 载荷类的默认值与边界值往返没有用例

- **位置**：`f_mq/src/base/MQPayload_test.cj:49-186`；`f_mq/src/base/model/*.cj`
- **现象**：全部用例都用「显式全字段」构造，没有覆盖规格 `openspec/specs/f-mq/protocol/spec.md:220-221` 要求的「字段带默认值」：默认构造的 `MQSubscribePayload`/`MQDeregisterPayload`/`MQBackupPayload`（空 `records`/`states`）往返、`MQTopicMeta(queueNum=0, delayingMs=-1)`（服务端应拒绝而非编解码失败）、`MQDeregisterPayload("topic", ...).isTopic() == true`（现有只测了 false）、负 `queueIndex`。
- **影响**：默认值语义、空集合语义只在部分类型上被验证；`MQDeregisterPayload.isTopic()` 的正向分支完全没有断言。
- **建议**：补一组「默认构造 + 空集合 + 边界值」往返用例。

#### [建议] `MQPayloadKind` 手写 `==`/`toString` 偏冗余，`kindOf` 每次重复计算 `TypeInfo`

- **位置**：`f_mq/src/base/MQConstants.cj:82-112`；`MQProtocol.cj:122-140`
- **现象**：无参枚举的 `==` 手写了 6×6 分支，`toString` 又是一份 6 分支映射；`kindOf` 每次调用都执行 2–3 次 `TypeInfo.of<...>().qualifiedName`（字符串比较）。`asInternal` 在 `MQProtocol.cj:165-175` 里先做一次类型检查，再调用同样做检查的 `asPayload`，重复一次。
- **影响**：纯可维护性/热路径常数开销。
- **建议**：`MQPayloadKind` 用 `@Derive[ToString]`（或 `match` 保持）并确认枚举默认 `==` 是否可用；`kindOf` 把 3 个 `qualifiedName` 提成 `static let`；`asInternal` 直接复用 `asPayload`。

### 覆盖与空实现核查

**命令 / 载荷覆盖矩阵**（工厂 → 解析 → 用例）：

| 命令 | 工厂 | 解析入口 | 命令断言 | 载荷往返 | 缺 |
|---|---|---|---|---|---|
| REGISTER(topic) | `registerTopic` | `asPayload<MQTopicMeta>` | ✅ | ✅ | — |
| REGISTER(group) | `registerGroup` | `asPayload<MQSubscribeGroupMeta>` | ✅ | ✅ | — |
| REGISTER(metaSync 请求) | `metaSync(MQMetaSyncRequest)` | `decodePayload<MQMetaSyncRequest>` | ✅ | ❌ | 子载荷解码用例 |
| REGISTER(metaSync 分配) | `metaSync(MQTopicAssignment)` | `decodePayload<MQTopicAssignment>` | ❌ | ✅ | 命令断言 |
| REGISTER(metaSync 组) | `metaSync(MQSubscribeGroupMeta)` | `decodePayload<MQSubscribeGroupMeta>` | ❌ | ❌ | 全缺 |
| REGISTER(stats) | `stats` | `decodePayload<String>` | ✅ | ✅（未帧往返） | 帧往返 |
| DEREGISTER | `deregister` / `metaSync(MQDeregisterPayload)` | `asPayload<MQDeregisterPayload>` | 前者 ✅ / 后者 ❌ | ✅（前者） | 后者全缺 |
| PUBLISH(记录) | `publish` / `publish(…, id!)` | `asRecord` | ✅（无 id） | ✅ | id 重载 |
| PUBLISH(备份) | `publishBackup` | `asInternal`+`decodePayload<MQBackupPayload>` | ✅ | ✅（小载荷） | ≥4KB |
| SUBSCRIBE / UNSUBSCRIBE / CONSUME / ACK | 4 个工厂 | `asPayload<…>` | ✅ | ✅ | — |
| RESP/ERROR | `respond`/`respondEmpty`/`fail` | `asResult` | ✅（`respondEmpty` 未断言 `RESP`） | ✅ | `asResult` 的 `INTERNAL` 分支 |

**空用例 / 空函数 / 占位代码**：

- 54 个 `@TestCase` 全部有实质断言，**未发现空用例、被注释或跳过的用例**（无 `@Ignore`/`@Skip`）。
- `f_mq/src/base` 内**未发现 TODO/FIXME/`NotImplemented`/仅 `return`/仅 `throw`** 的函数。
- 唯一的空函数体是 `@DataAssist` 要求的 18 个无参 `init() {}`（`MQTopicMeta.cj:31`、`MQResult.cj:28` 等），属宏契约所需，不是占位实现。
- `@Assert(true)` 共 3 处（见建议），均为 `match` 分支内的模式断言，不计为空断言。

### 本轮统计

| 严重程度 | 数量 |
|---------|------|
| 严重 | 2 |
| 一般 | 6 |
| 建议 | 5 |

### 总评

基础层的结构划分清晰（model / payload / 协议工厂 / 解析 / 记录编解码分层合理），`MQProtocol` 用「载荷运行时类型」代替新增命令号的约束执行得很彻底，`MQMessageRecord` 的四段布局、「恰好消费完才算完整」、「绝不返回空数组」等边界处理有明确注释与对应用例，错误码数值/文案、主题校验、过滤器规则也都与规格逐条对齐。文档密度高，`详细设计.md` 的决策记录（D1–D9、Q1–Q6）对理解取舍很有价值。

主要问题集中在两类：

1. **对象载荷内的字节字段绕过了 `MQBytes` 这一层**：`publish` 路径专门为 4096 临时文件阈值做了兼容，但 `MQConsumeResult.record`、`MQBackupPayload.records`、`MQInternalMessage.payload`、`MQDeadLetterMessage.record` 都是对象字段，超阈值时会被 SILENCE 语义静默转成空数组——对 consume 来说这恰好等于「没有消息」，表现为消费者永久阻塞、备份丢数据，且现有用例（只测 publish 大记录、只测小 record 往返）完全覆盖不到。这一条是本次审查最需要优先修复的问题。
2. **`publishTime` 的时区口径**：`MessageID` 写本地时间、`publishTime` 按 UTC 解释，非 UTC 部署下延迟投递与滞后统计会整体偏移，用例本身也依赖 UTC 环境才能通过。

除此之外是一批「覆盖盲区」性质的缺口：`metaSync` 的 3 个重载与 4 个内部子载荷分支、`publish(record, id!)`、`decodePayload` 的负向路径、16KB 用例的临时文件断言，以及 `INVALID_GROUP` 这个没有任何产生路径的死错误码。设计文档相对实现的漂移（`queueIndex`、`delayingMs`、kind 数量、`MQProtocol` 签名）也是本轮 R1 判定依据的一部分，建议一并刷新，否则后续轮次容易按过期字段做判断。
