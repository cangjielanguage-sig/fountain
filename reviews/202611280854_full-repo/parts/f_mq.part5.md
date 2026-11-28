# f_mq 模块审查报告（第 5/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mq`（全模块 61 个 `.cj` + 36 个 `.md`；**本报告只覆盖第 5/6 部分**：`src/base/payload/` 12 个载荷类 + `src/client/` 8 个文件，共 20 个 `.cj`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比；`git blame` 显示本部分代码均为 2026-10-18 / 10-21 提交，故所有问题来源记「存量」）
- **审查重点**：消息队列投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（分报告，待与第 1~4、6 部分合并为 `docs/review/2026-11-28/f_mq.md`）

## 发现

### [严重] [存量] 未 ack 的投递位置永久占位：服务端重投被客户端静默跳过，`deliveries` 无上界

- **位置**：`f_mq/src/client/MQClient.cj:246-254`（认领）、`f_mq/src/client/MQClient.cj:326`（唯一移除点）、`f_mq/src/client/MQSubscription.cj:37`（容器本体）
- **来源**：存量（`git blame -L 246,254` → 89c6fd44c2 / 2026-10-21；`-L 315,326` → 89c6fd44c2 / 2026-10-21）
- **判据**：review-checklist §11（错误处理缺失 / 边界）、§5（无界容器）、§12.1（共享状态无生命周期）；契约源 `f_mq/README.md:122`「投递语义为 **at-least-once**：未确认消息在超时或服务重启后会重复投递」
- **证据**：静态确定 —— 全仓 `deliveries` 只有 5 处出现（1 行声明 `MQSubscription.cj:37`、1 行文档注释、`MQClient.cj:250/315/326` 三处代码），其中 `remove` 仅有一处，位于 ack 收到成功响应的分支（`:319-326`）；`addIfAbsent` 命中已有键时直接 `continue`（`:251`），没有任何过期、替换或容量判断。
- **描述**：`consume` 在把消息交给业务**之前**就用 `(queueIndex, segmentedIndex, segmentedOffset)` 认领（`:250`），业务侧一旦没有 ack（处理逻辑抛异常、消息被有意丢弃、ack 被放到下一轮批处理、消费者线程崩溃），该键就永久留在 map 中。服务端按 `ackTimeout` 重投同一位置后（`fmq/src/server/ConsumeService.cj:67-126`，`GroupCursor` 负责超时退回），客户端在 `:250` 命中 `Some(_)` 直接 `continue`，业务永远看不到这条消息，也就永远不会 ack —— 该位置对该订阅**永久卡死**，README:122 承诺的 at-least-once 在客户端层退化成「不投递」。同时每个被放弃的位置会永久占用一个 String 键 + 哈希节点，长时间运行（消费侧持续失败）下无界增长（§5）。注意：阻塞本身是有意的（`f_mq/src/client/test/MQClient_test.cj:530-566` 断言「另一线程必须一直被认领失败挡住」），缺的是**时间上界**——去重窗口没有边界，等价于永久去重。
- **建议**：认领时同时记时间戳（Value 改为 `(node, claimAtMs)` 或独立并行数组），为键设 TTL = 服务端 `ackTimeout` + 余量；命中已过期项时用 `add`（覆盖语义，见 `std.collection.concurrent` 文档 `collection_concurrent_class.md:1082-1097`）接管并计数 redelivery；对 `deliveries` 加容量上限（超限拒绝或告警）；命中跳过时打 DEBUG/计数器，否则线上无法区分「正常去重」与「永久丢投递」。

### [一般] [存量] 订阅的 owner 集合订阅后不再刷新：主题重分配后 `consume` 静默空转

- **位置**：`f_mq/src/client/MQClient.cj:146-181`（owners 只在订阅时算一次）、`f_mq/src/client/MQClient.cj:223-231`（只轮询 `sub.owners`）、`f_mq/src/client/MQSubscription.cj:36`（`let owners: Array<Int64>`）
- **来源**：存量（`git blame -L 178,181` → 6303d88db0 / 2026-10-18；`MQSubscription.cj:36` → 同上）
- **判据**：review-checklist §11（契约与实现不符 / 静默失效）、§12.1（有界性、可见性）
- **证据**：静态确定 —— `MQSubscription` 的 `owners` 是不可变字段且无任何 setter/替换路径（全仓搜 `owners =` 只出现在构造）；服务端 `ConsumeService.consume` 在本地没有该主题队列时返回 `None`（`fmq/src/server/ConsumeService.cj:68-71`），最终回的是**空 `MQConsumeResult`** 而不是 `NOT_OWNER`，客户端无从发现 owner 已迁移。
- **描述**：节点数变化时元数据会重算队列归属（`fmq/src/meta/MetaStore.cj:225-235` → `MQAssignment.allocate`），主题队列被分配到新节点。已有订阅仍只向老 owner 请求，收到空响应后走 `:241 continue` → `:298 sleep(200ms)`，既无异常也无日志；消息在新 owner 上持续积压，直到客户端重新 `subscribe`（换新 `subscribedId`）。对比之下 `publish` 有 `NOT_OWNER` 重试 + `ownership.invalidate`（`:96-101`）能自愈，`consume` 没有对等机制。「是否会在生产触发」取决于是否会扩缩容，触发频率待确认。
- **建议**：三条任选或组合——(1) `consume` 侧统计连续「全部 owner 空」轮数，超过阈值（或 `ownership` 条目过期）时重新解析 owner 并向新 owner 补发一次 `SUBSCRIBE`；(2) 服务端在本地无该主题队列时回 `NOT_OWNER`，客户端据此重算 owner（与 publish 对称）；(3) 至少给一条 WARN + 指标（`consumeEmptyRounds`），让「订阅空转」可观测。

### [一般] [存量] 所有权缓存过期条目只在被读到时清理，无清扫与容量上限

- **位置**：`f_mq/src/client/MQOwnershipCache.cj:37-48`（仅 `ownersOf` 命中过期项才 `remove`）、`:50-52`（`put` 无容量判断）
- **来源**：存量（`git blame -L 37,52` → 6303d88db0 / 2026-10-18）
- **判据**：review-checklist §5（缓存键无界、TTL 无淘汰）
- **证据**：静态确定 —— 过期删除只发生在「恰好又读了同一个 topic」；`invalidate` 只在 `NOT_OWNER` 与 `close` 时调用；无迭代清扫、无容量上限、无 LRU。
- **描述**：客户端每发布一个新 topic 就留一条 `(String key, Array<Int64>, DateTime)`。topic 名由调用方传入（只校验格式与长度，`MQTopic.isValid`），若命名带租户/业务维度，条目在 TTL 到期后仍常驻到该 topic 下次被读为止，内存随历史 topic 基数单调增长。影响规模取决于 topic 基数（待确认），不影响正确性。
- **建议**：加容量上限 + LRU 淘汰，或 `put` 时按计数器每 N 次做一次采样清扫（遍历 key 快照 → `ownersOf` 触发过期删除）；或改为「整表快照原子替换」（定期重建一个只含未过期条目的新 map）。

### [轻微] [存量] 多点请求逐条串行、ack 广播无提前退出

- **位置**：`f_mq/src/client/MQClient.cj:146-162`（subscribe 广播）、`:191-203`（rollback）、`:340-358`（ack 广播）、`:395-408`（unsubscribe）
- **来源**：存量（`git blame -L 146,162`、`-L 340,358` → 6303d88db0 / 89c6fd44c2，2026-10-18~21）
- **判据**：review-checklist §6.3（并发串行）、§6.4（已知成立即可提前返回）
- **证据**：静态确定（结构层面）—— 四处都是 `for (node) { transferOf(...) }` 串行，单节点超时分别为 5s（subscribe/ack/unsubscribe）与 5s（rollback 用 `ACK_TIMEOUT`），最坏耗时为 N × 超时；`:342-352` 在 `accepted = true` 之后没有 `break`，仍会向其余 owner 各发一次必然回 `ACK_UNKNOWN` 的请求。
- **描述**：N=3 且有一个节点 hung 时，`subscribe` 最坏 15s（首个请求即被一个慢节点拖住，而订阅是启动/扩缩容路径上的同步调用）；ack 广播路径在「未知来源」场景（autoAck 或重启后重投）会多发 N-1 个无意义 RTT，且每次 5s 超时时同样线性叠加。**未做任何测量，不主张端到端收益占比**。
- **建议**：fan-out 改为「先提交全部 `transfer`，再统一汇合」（`f_net` 的 `Client.transfer` 内部有 pending 表，可并发使用），保留每节点独立结果与现有错误文案；ack 广播在 `accepted` 后 `break`（语义仍是「任一节点接受即成功」）。

### [轻微] [存量] `close()` 与在途 `subscribe` 的检查-然后-写入竞态：关闭后仍可能留下本地订阅与缓存条目

- **位置**：`f_mq/src/client/MQClient.cj:129`（`ensureOpen`）→ `:179`（`subscriptions.add`）、`:422-437`（`close`）
- **来源**：存量（`git blame -L 129,129`、`-L 179,179`、`-L 422,437` → 6303d88db0 / 2026-10-18）
- **判据**：review-checklist §11（并发正确性）、§12.1（检查-然后-写入）
- **证据**：静态确定 —— `ensureOpen` 与 `subscriptions.add` 之间隔着 N 次网络往返（最长 5s/节点），`close()` 的 CAS 只保证「唯一执行一次」，不阻止已经通过 `ensureOpen` 的调用在 `close()` 返回后再写 map 与 ownership 缓存。
- **描述**：后果限于本进程：多出一条永不使用的 `MQSubscription` 与一条 ownership 条目（服务端订阅随连接关闭被释放，`ConsumeService.releaseSubscription`），不崩溃、不泄漏句柄。但它让 `close()` 之后 `subscriptions` 可能非空，与「关闭并清空订阅」的契约在时序上不一致，也让后续排障误判为「关闭后还在订阅」。
- **建议**：`subscriptions.add` 之前再检查一次 `isClosed()`，是则先 `rollback`/`unsubscribe` 已接受的节点再抛 `MQConnectionException`；或在 `close()` 内置位后做二次清空（CAS 成功线程再清一遍 map）。

### [轻微] [存量] 配置错误与服务错误统一折进 `MQConnectionException`

- **位置**：`f_mq/src/client/MQClientConfig.cj:34`、`:38`（配置缺失 / 非法 host）；`f_mq/src/client/MQClient.cj:409-415`（`failed` 里既可能是服务端 code 也可能是 timeout，统一抛 `MQConnectionException`）
- **来源**：存量（`git blame -L 32,40` → 6303d88db0 / 3856fcebda，2026-10-18）
- **判据**：review-checklist §11（语义与命名不符 / 错误分类）
- **证据**：静态确定 —— 异常层次只有 `MQException` / `MQConnectionException` / `MQServiceException`（`f_mq/src/exception/MQException.cj:25-75`），没有配置类异常。
- **描述**：永久性错误（配置缺失、`host:port` 非法、服务端返回非 `SUBSCRIBE_NOT_EXIST` 的 code）与可重试的链路错误共用同一类型，调用方无法只按类型决定「快速失败」还是「重试」，只能解析 message 文本。注：README:34 与客户端 spec 也这样写，故这是分类学问题、不是文档冲突，不阻塞。
- **建议**：新增 `MQConfigException <: MQException`（spec 里本来就用这个名字）；`unsubscribe` 的部分失败保留 `MQConnectionException`，但把纯服务端 code 的情况拆成 `MQServiceException`（调用方已有 `code` 可分支）。

### [轻微] [存量] 已退订 id 集合的 FIFO 淘汰用 `ArrayList.remove(at: 0)`

- **位置**：`f_mq/src/client/MQRetiredSubscriptions.cj:46-49`
- **来源**：存量（`git blame -L 40,53` → 6303d88db0 / 2026-10-18）
- **判据**：review-checklist §6.4（`remove(at: 0)` 当队列头 → 每次 O(n)）
- **证据**：静态确定（复杂度）；触发频率低——只有容量打满（默认 4096）后每次 `add` 才淘汰一个。
- **描述**：每次淘汰搬移 4096 个 `String` 引用；单次开销在微秒级（未实测），不影响正确性与淘汰顺序语义。属低效实现 + 轻微 CPU 浪费。
- **建议**：环形缓冲（定长数组 + head/tail 索引，满时覆盖最旧），或一次性淘汰 1/8 把搬移摊薄；两者都保持「先进先出、不刷新重复项位置」的现有语义（`:42-45`）。

### [轻微] [存量] `MQNodePool.slots` 声明为 `var` 却从不重赋值；`close()` 的 `closeLock` 与 CAS 重复互斥

- **位置**：`f_mq/src/client/MQNodePool.cj:40`、`f_mq/src/client/MQClient.cj:50` 与 `:426`
- **来源**：存量（`git blame -L 39,44` → 6303d88db0；`MQClient.cj:426` → 6303d88db0，2026-10-18）
- **判据**：review-checklist §10（语言特性 / 可读性）、§12.2（锁的必要性）
- **证据**：静态确定 —— `slots` 只做 `slots[i] = ...` 元素写入，从未整体替换；`close()` 的 `closed.compareAndSwap(false, true)` 已保证函数体只执行一次，`synchronized(closeLock)` 内没有额外的跨字段不变量需要保护。
- **描述**：`var` 让读者怀疑「数组会被整体替换」，进而怀疑元素写入与锁的对应关系（实际所有写入都在 `nodeLocks[i]` 内）；`closeLock` 给人「close 会被并发执行」的错觉，实际上永远只有一个线程进入该块。两者都是可维护性负担，无正确性影响。
- **建议**：`slots` 改 `let`；`close()` 去掉 `closeLock`（或保留但用一行注释说明「保留仅为防御未来改动」）。

### [轻微] [存量] `MQClientConfig_test` 在未保存原值的情况下先 `Config.remove`，跑完不恢复原值

- **位置**：`f_mq/src/client/MQClientConfig_test.cj:89`
- **来源**：存量（`git blame -L 86,94` → 6303d88db0 / 2026-10-18）
- **判据**：review-checklist §11（测试污染进程级状态；与「用例隔离」的约定冲突）
- **证据**：静态确定 —— `withHosts` 在 `:28` 捕获 `previous`，而 `:89` 的 `Config.remove` 发生在调用 `withHosts` **之前**，因此 `previous` 恒为 `None`，`finally` 恢复的是「不存在」。若同进程内其它用例/夹具原本设置了 `mqClient_hosts`，会被本用例永久删除。
- **描述**：该用例的目的是验证「修改前键不存在 → 结束后仍不存在」，但为了造这个前提，它在捕获原值之前就删了键，于是「恢复原值」退化成「恢复为缺失」。同文件其它四个用例（`:42`、`:51`、`:65`、`:98`）都通过 `withHosts` 正确保存并恢复了原值，只有这一个绕过了保护，属于同文件内的不一致；`Config` 是进程级共享状态，一旦有用例依赖真实配置就会莫名失败。
- **建议**：先捕获 `previous` 再 `remove`，`finally` 恢复 `previous`；或给 `withHosts` 增加一个「断言以缺失为前提」的变体，把删除与恢复放在同一作用域。

### [轻微] [存量] `rollback` / `unsubscribe` 与三处 all-unreachable 异常构造是同构样板

- **位置**：`f_mq/src/client/MQClient.cj:185-209` 与 `:393-416`（近乎逐行同构）；`:109-117`、`:281-297`、`:359-368`（三处同构的「汇总 `lastConnectionError` → 有则带 caused、无则裸抛」）
- **来源**：存量（`git blame -L 185,209` → 6303d88db0 / 2026-10-18；`:393-416` → 89c6fd44c2 / 2026-10-21）
- **判据**：review-checklist §2（表现形式不同的重复逻辑：换控制流 / 字面量复制）
- **证据**：静态确定 —— 两段 `unsubscribe` 循环的差集只有三处：遍历源（`accepted` vs `sub.owners`）、失败后的动作（返回 `Array<String>` 供拼文案 vs 直接抛）、日志措辞；其余「构造载荷 → 逐节点 transfer → `ERROR` 且非 `SUBSCRIBE_NOT_EXIST` 记失败 → timeout/rejected 记失败」完全一致。
- **描述**：同构代码的风险是漂移：例如 `:196` 对 `SUBSCRIBE_NOT_EXIST` 的豁免、`:401` 的同名豁免、`failed` 文案格式（`"${node}(timeout)"` / `"${node}(${e.message})"`）三份副本必须同步修改；改一处漏一处会直接改变回滚/退订的判定结果。三处异常构造同理，文案差异（是否带 tried nodes、是否带 caused）已出现不一致。
- **建议**：抽 `private func unsubscribeOn(nodes: Array<Int64>, id: String, action: String): Array<String>`（内部统一日志），`rollback` 与 `unsubscribe` 复用；异常构造抽 `private static func unreachable(action: String, nodes: Array<Int64>, last: ?Exception): MQConnectionException`，把现有文案差异作为参数传入（保持 A15/A16 要求的定位信息）。

### [轻微] [存量] 三个载荷类的 `Array<Byte>` 重载整体复制字段赋值

- **位置**：`f_mq/src/base/payload/MQConsumeResult.cj:36-48`、`f_mq/src/base/payload/MQDeadLetterMessage.cj:39-61`、`f_mq/src/base/payload/MQInternalMessage.cj:33-41`
- **来源**：存量（`git blame` 这三个文件均为 6303d88db0 / 2026-10-18）
- **判据**：review-checklist §2（只改一行的重复）
- **证据**：静态确定 —— 每个类的两个构造函数只差最后一个字段（`this.record = MQBlob(x)` vs `this.record = x` / `payload`），其余 5~7 行字段赋值逐行相同。
- **描述**：仓颉的 `class` 不支持构造函数互相委托（语言文档 `class_and_interface/class.md:116-135` 只定义「多个普通构造函数必须构成重载」与主构造函数，无 `this(...)` 链式调用），因此**无法**靠委托消除。真实风险是字段增删时两处不同步：漏改一处 → 某条构造路径的字段静默为默认值（这类 bug 在编解码往返时才暴露）。
- **建议**：保留一个公共构造函数 + `static func of(record: Array<Byte>): X` 工厂（调用方改为工厂），或在用例里断言两条构造路径产出的 `toData()` 逐字节一致，把「两处必须同步」变成可测约束。

## 优化可行性方案

> 不是缺陷，是"还能更好"。四条均无改前/改后基线，仅作下一轮补数据的候选。

### [堆内存] `consume` 对每条记录先 `copyBytes()` 再解码，峰值多一份记录字节

- **现状**：`MQClient.cj:244` 调 `MQMessageRecord.decode(result.record.copyBytes())`；`MQBlob.copyBytes()`（`MQBlob.cj:58-60`）是整段 `clone()`。单条记录大小受 `QueueLog.effectiveMaxRecord` 限制（README:118），大于 4096 字节的记录在解码侧可能落临时文件（README:129-130）。每条消息在解码期间同时持有「MQBlob 内部数组」+「副本数组」+「解码出的 `Data` 树」。
- **方案**：给 `MQMessageRecord` 增加基于 `MQBlob` 的 `decode(blob: MQBlob)`，直接对内部数组构造 `ByteBuffer` 视图（`ByteBuffer(record)` 只持引用，见 `MQMessageRecord.cj:171`），或让 `decode` 接收 `Array<Byte>` 并在解码结束后立刻放弃中间数组。
- **预期**：每条消息峰值 −S 字节（S = 记录字节数），大消息场景最明显；常驻不变。
- **代价**：需把 `MQBlob` 的内部数组以包内可见方式暴露（或加 `withBytes` 回调），存在「调用方长期持有内部数组」的误用风险；`MQMessageRecord` 属第 4 部分范围，改动跨文件。
- **验证**：固定 1 MB 记录、单线程消费 N 条，对照 `getAllocatedHeapSize()` 增量与 RSS 峰值（多轮取中位数）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `deliveries` 用拼接字符串做键

- **现状**：`MQSubscription.keyOf`（`MQSubscription.cj:48-50`）每次投递拼一个 `"${q}:${s}:${o}"`；`MQClient.cj:247-248` 与 `:314` 各拼一次。在途条目数 = 未 ack 数（见「发现」第 1 条的无界问题）。
- **方案**：改为 `struct DeliveryKey(queueIndex, segmentedIndex, segmentedOffset) <: Hashable & Equatable`（或把三个 Int64 打包进两个 Int64 做键），`ConcurrentHashMap<DeliveryKey, Int64>`。
- **预期**：每条在途消息少一次字符串分配（约 50~60 字节 + 哈希表节点中的引用），`ack` 路径少一次拼接；命中比较由字符串比较降为整数比较。
- **代价**：新增类型与 `hashCode` 实现；日志里需要 `toString()` 还原可读位置（`"${q}:${s}:${o}"` 的文案要保留）。
- **验证**：未 ack 积压 10k 条时对比堆占用与 `ack` 单次耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `candidateNodesOf` 每次调用分配两个数组

- **现状**：`MQClient.cj:524-541` 先 `Array(preferred.size + all.size)` 再做前缀去重，最后 `buf[0..len]` 又复制一份（Array 切片是拷贝）；每次 `publish`（`:86`）都走一次，`candidateNodes` 还把 `aliveNodes()` 的全量下标数组也新建一遍（`MQNodePool.cj:172-177`）。
- **方案**：返回「数组 + 有效长度」二元组（或用包内 `struct NodeCandidates`），调用方按长度遍历；`aliveNodes` 在节点表不可变的前提下返回缓存的只读数组（`hosts` 构造后不变）。
- **预期**：每次 publish 少 1~2 次分配（大小 ≈ 节点数）。本部分已有的 `MQCandidateNodes_test.cj:121-152` 只对照了旧实现（`legacyAlloc > producedAlloc * 2`），没有绝对基线，无法据此给百分比。
- **代价**：调用方循环写法改动（`for (i in 0..len)`），越界风险需靠用例守住；可读性略降。
- **验证**：`F_MQ_BENCH=1` 下扩展现有 `MQ_CANDIDATE_BENCH` 埋点，另加 `cjpm bench -O2` 的 publish 吞吐对照（同机、同输入、中位数）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `consume` 空轮询固定 200ms + 每轮 N 次请求

- **现状**：`MQClient.cj:298` 固定 `sleep(200ms)`；每轮先向 `owners` 逐个请求（`:229-231`），空队列时一轮 = N 次 RTT（`responded` 计数在 `:233`）。
- **方案**：空轮询改为有界指数退避（200ms → 1s 封顶）+ 有消息时立即复位；节点较多时先问上轮命中的 owner，命中即跳过其余节点。
- **预期**：低流量订阅的空转请求数下降（N 倍 → 1 倍量级）。属请求数减少，不等价于吞吐提升。
- **代价**：退避会拉长新消息的首次可见延迟（最坏 1s），需要按业务延迟要求定上限；语义从「固定间隔」变为「自适应」，要同步改 README:62 的描述。
- **验证**：单消费者、空队列 10 分钟，统计 CONSUME 请求数/秒与「发布→消费到」的 P95 延迟。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `candidateNodesOf` 的两次分配在 publish 总分配中占比可观 | `f_mq/src/client/MQClient.cj:524-541` | 每次 publish 的分配字节数与占比 | `cjprof record` 跑 10 万次 publish（8 节点、1KB 消息），看 `getAllocatedHeapSize()` 增量与 `candidateNodesOf` 采样 |
| 2 | `copyBytes()` 让大消息消费路径峰值翻倍 | `f_mq/src/client/MQClient.cj:244` | 峰值堆/RSS 与单条记录大小的关系 | 1MB 记录 × 1 万条，抓 `getUsedHeapSize()` 峰值与 RSS，对照去掉副本后的版本 |
| 3 | `MQNodePool` 锁内 `build()` 造成同节点请求排队 | `f_mq/src/client/MQNodePool.cj:122-133` | 锁等待时长与并发线程数（CPU profile 看不到） | 注入慢建连（`build` 钩子延迟 1s），20 线程并发 `clientOf`，抓线程状态（BLOCKED）与等待时长分布 |
| 4 | subscribe 串行 fan-out 在单节点 hung 时 P95 明显劣化 | `f_mq/src/client/MQClient.cj:146-162` | 订阅耗时 P95/P99 | 3 节点、1 节点挂起不响应，测 100 次 subscribe 的耗时分布（当前实现 vs 有界并行版本） |
| 5 | `retired` 的 `remove(at:0)` 与 `deliveries` 字符串键在实际退订/ack 频率下可忽略 | `MQRetiredSubscriptions.cj:46-49`、`MQSubscription.cj:48-50` | 单次耗时与调用频率 | 微基准：容量 4096 下连续 add 10 万次；以及 ack 10 万次的单次耗时中位数 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_mq.part5.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mq/src/base/payload/MQConsumePayload.cj` | .cj | ✅ | 单字段载荷，`@DataAssist` 生成 props/fields；无问题 |
| 2 | `f_mq/src/base/payload/MQConsumeResult.cj` | .cj | ✅ | 双构造函数重复，见「发现」#11；`record` 空 blob 作「无消息」哨兵（客户端 `MQClient.cj:241` 依赖） |
| 3 | `f_mq/src/base/payload/MQDeadLetterMessage.cj` | .cj | ✅ | 双构造函数重复，见「发现」#11 |
| 4 | `f_mq/src/base/payload/MQDeregisterPayload.cj` | .cj | ✅ | `kindOf` 精确判别 + `DeregisterKind` 封闭枚举，`Unknown` 不落删除分支；服务端 `MQCommandExecutor.cj:173` 已按此拒绝 |
| 5 | `f_mq/src/base/payload/MQInternalMessage.cj` | .cj | ✅ | 双构造函数重复，见「发现」#11 |
| 6 | `f_mq/src/base/payload/MQMetaSnapshot.cj` | .cj | ✅ | 可选 `tombstones`/`revision` 默认值；`nextStartNode` 与 `MQTopicAssignment.startNodeIndex` 语义一致 |
| 7 | `f_mq/src/base/payload/MQMetaSyncRequest.cj` | .cj | ✅ | 仅 `requesterIndex`，默认 -1；同步请求/回包共用（`MetaSyncer.cj:228`） |
| 8 | `f_mq/src/base/payload/MQMetaTombstone.cj` | .cj | ✅ | `key()` 用 `"\u{0}"` 分隔，避免 topic/group 拼接歧义；`isTopic` 只认 `KIND_TOPIC` |
| 9 | `f_mq/src/base/payload/MQResult.cj` | .cj | ✅ | 与 `MQErrorCode` 配合；`code=0` 为成功，空载荷由 `MQProtocol.asResult` 折成成功 |
| 10 | `f_mq/src/base/payload/MQSubscribePayload.cj` | .cj | ✅ | `autoAck` 默认 false（手动 ack 路径），`filter` 空串=不过滤 |
| 11 | `f_mq/src/base/payload/MQTopicAssignment.cj` | .cj | ✅ | `owner()` 越界返回 `None`（判据是 `owners.size`，非 `queueNum`；队列数一致性由服务端 `MQAssignment.cj:56` 校验） |
| 12 | `f_mq/src/base/payload/MQUnsubscribePayload.cj` | .cj | ✅ | 与 `MQConsumePayload` 结构相同，但协议按类型名分派，不能合并（见「覆盖自检」§2 说明） |
| 13 | `f_mq/src/client/MQCandidateNodes_test.cj` | .cj | ✅ | 去重用例覆盖 preferred/all 的去重与空输入；分配基准由 `F_MQ_BENCH=1` 门控，默认跳过 |
| 14 | `f_mq/src/client/MQClient.cj` | .cj | ✅ | 本部分主要缺陷集中处，见「发现」#1~#6、#8、#10 |
| 15 | `f_mq/src/client/MQClientConfig.cj` | .cj | ✅ | 顺序保留 + 非法项不静默跳过；异常类型见「发现」#6 |
| 16 | `f_mq/src/client/MQClientConfig_test.cj` | .cj | ✅ | 配置还原逻辑基本正确，`configIsRemovedWhenAbsentBeforeTest` 提前删键，见「发现」#9 |
| 17 | `f_mq/src/client/MQNodePool.cj` | .cj | ✅ | 逐节点锁 + 锁内复核 closed（A17/T7.1 落地正确）；背压/退避计算已核对；`slots` 的 `var` 见「发现」#8 |
| 18 | `f_mq/src/client/MQOwnershipCache.cj` | .cj | ✅ | TTL 只在读时清理，见「发现」#3；`put` 用 `add`（覆盖语义，`std` 文档 `collection_concurrent_class.md:1082-1097` 已核对） |
| 19 | `f_mq/src/client/MQOwnershipCache_test.cj` | .cj | ✅ | 命中/过期/替换三条路径均有断言，时间源注入正确 |
| 20 | `f_mq/src/client/MQRetiredSubscriptions.cj` | .cj | ✅ | 有界 FIFO、重复 add 不刷新位置；淘汰用 `remove(at: 0)`，见「发现」#7 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 2（#1 认领无过期、#2 owner 不刷新）、设计 1（#6 异常分类学）、语言特性 1（#8 无用 `var` + 冗余锁）、可读性 2（#9 测试污染全局配置、#10 四处同构样板须同步改）；安全性 0：本部分无 SQL/命令拼接，topic/tags/group 在客户端与服务端双向校验（`MQTopic`/`MQTags`/`MQGroup`），日志不含凭据与完整报文 |
| §1 死代码 | 0 | 已逐个符号搜引用：`MQClient` 的 `subscriptionOf`/`ensureOpen`/`transferOf`/`groupOf`/`nodeList`/`candidateNodes`/`rollback`、`candidateContains` 均有调用者；`candidateNodesOf` 被生产与用例共用；`MQOwnershipCache`/`MQRetiredSubscriptions` 全部成员有引用；`MQNodePool.isClosed` 只被 `MQNodePool_test.cj` 引用（internal 类成员、仅测试使用 → 属可见性建议，不算死代码）；12 个载荷类均为 `public` 顶层且被 `fmq` 跨模块使用（`MQDeadLetterMessage`/`MQMetaTombstone`/`MQTopicAssignment` 等），对外可达不判；`MQClient.cj:300-301` 的 `throw "unreachable"` 位于 `while(true)` 之后，是编译器返回类型检查需要，非缺陷。未发现 `return`/`throw` 后同层语句、恒真恒假分支或未使用 import |
| §2 重复逻辑 | 2 | 逐函数体比对后命中 2 条（#10 四份样板、#11 三个载荷构造函数）。**刻意不判**的两组：`MQConsumePayload` 与 `MQUnsubscribePayload` 形态相同但协议按 `typeInfo.qualifiedName` 分派（`MQProtocol.cj:158-190`），合并会破坏自描述；`MQCandidateNodes_test.legacyCandidateNodes` 是基准对照的旧实现，注释已说明用途 |
| §3 空实现 | 0 | 20 个文件无 `TODO`/`FIXME`/空函数体；`catch` 块均有日志（`MQNodePool.cj:110-113` DEBUG、`:190-192` DEBUG）；`case None => ()` 出现在 `MQClient.cj:252`（`addIfAbsent` 成功）与 `MQNodePool.cj:115/194`（槽位本就为空），都不是吞错误 |
| §4 栈溢出 | 0 | 无递归：`candidateContains`/`candidateNodesOf`/`nodeList`/`backoffOf` 均为循环；无自引用结构的深度遍历 |
| §5 OOM | 2 | #1（`deliveries` 无上界，随未 ack 数增长）、#3（ownership 缓存无清扫）。其余容器已核对为有界：`subscriptions`（用户订阅数）、`retired`（4096 FIFO）、`slots`/`retryAt`/`failures`（节点数定长）；无「按报文长度预分配」路径（`Array` 大小均来自配置/节点数） |
| §6.1 热点瓶颈 | 0 | 未提供 bench/profile 数据（`MQCandidateNodes_test` 的分配基准默认跳过且无绝对值记录），热点结论不成立，已转「待验证假设」#1~#5 |
| §6.2 大粒度锁 | 0 | 唯一的「锁内重活」是 `MQNodePool.cj:122-133` 在 `nodeLocks[i]` 内建连：这是「并发首次建连只建一条」（客户端 spec 的 Scenario）所必需，且锁按节点分片，一个节点建连慢不阻塞其它节点；其余临界区只有 map/数组读写（`MQRetiredSubscriptions.cj:41-52`、`MQOwnershipCache` 无锁）。`MQClient.close` 的 `closeLock` 无实际保护对象，已记 #8（轻微，非性能） |
| §6.3 并发串行 | 1 | #4：subscribe/rollback/ack/unsubscribe 四处逐节点串行，最坏耗时 N × 超时；未测量，不给端到端收益 |
| §6.4 低效算法 | 1 | #7（`retired` FIFO 用 `remove(at: 0)`）；另 #4 的 ack 广播无提前退出同源。`candidateContains` 是 O(节点数) 线性扫描，节点数为集群规模，属合理取舍，不判 |
| §7 降堆内存方案 | 2 | `copyBytes` 多一份记录、`deliveries` 字符串键；均无基线 |
| §8 降 CPU 方案 | 2 | `candidateNodesOf` 双分配、空轮询固定 200ms；均无基线 |
| §9 local mode 可行性 | 0 | 不可行：热路径对象全部逃逸——`MQMessageRecord.encode` 的字节进入 `Message` 并交给网络栈（`MQClient.cj:83-88`），`MQConsumeResult.record` 与解码出的 `Data` 树经 `MQMessage` 返回给调用方（`:255`）；没有「函数内创建、函数内释放」的临时大对象，`@ local!` 会在逃逸检查处失败。且本模块未开启 `--enable-local-mode`，混链会产生 SDK 锁版约束 |
| §11 现有代码的 BUG（存量） | 11 | #1~#11 全部为存量（blame 均为 2026-10-18/21）。已核对未成缺陷的边界：`MQTopicAssignment.owner` 负下标/越界；`DeregisterKind` 空串与大小写变体落 `Unknown`；`MQBlob` 空 vs `None` 的区分（客户端 `:241` 先判空再解码）；`backoffOf` 指数封顶 5s 不溢出；`MQNodePool.clientOf` 越界与关闭后复核 |
| §12 并发安全与锁粒度 | 2 | 并发安全：`subscriptions`/`deliveries`/`ownership.entries` 用 `ConcurrentHashMap`，`cursor` 用 `AtomicInt64`，`retired` 用 `Mutex`，`pool` 用逐节点 `Mutex`，`closed` 用 `AtomicBool`——共享点已列全；命中 #1（认领状态无生命周期，跨线程可见但永不过期）与 #5（`close` 与 `subscribe` 的检查-然后-写入）。`ack` 的 `get`+`remove` 非原子，但服务端 ack 幂等（重复 ack 回 `ACK_UNKNOWN` 被忽略），不构成缺陷。`nextStart` 的 `fetchAdd` 需 9.2e18 次调用才可能溢出成负下标，不构成现实风险 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 12 个载荷类在 `README.md:161` 全部登记；`MQTopicAssignment.owner`（README:174）、`MQMetaTombstone.key/isTopic`（README:170）、`MQDeregisterPayload.kindOf/isTopic`（README:163）、`MQClient`/`MQClientConfig`（README:39-52、144）均已覆盖。缺口仅符号级：`MQClientConfig.hosts` 属性与载荷的 `static const`（`MQDeregisterPayload.TOPIC/GROUP`、`MQMetaTombstone.KIND_TOPIC/KIND_GROUP`）未在 README 点名——README 属第 1 部分范围，此处只作提示，不计入本部分统计 |
| §13 文档一致性 / 文件覆盖 | 20/20 | 本部分清单不含 `.md`，故 §13 无对照对象；20 个 `.cj` 全部逐行读完，无「未读」项 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 2 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

存量 11 条（含 1 条严重），是否纳入修复待用户决定。

## 总评

客户端主链路的**失败分类与可观测性做得比较扎实**：`TransferOutcome` 把「服务端回包 / 超时 / 连不上」区分开（`MQClient.cj:517-521`），publish 能区分「全 `NOT_OWNER`」与「连不上」（`:109-112`），consume 不再把服务端错误当空轮询（`:234-238`），订阅回滚失败会把节点拼进异常文案（`:163-171`），连接池「锁内复核 closed」也正确落地（`MQNodePool.cj:97-101`）。载荷类都是 `@DataAssist` 纯数据 + 双构造函数，没有隐藏状态。

主要风险集中在**投递状态的生命周期**，而不是并发原语：

1. **阻塞项**：#1 认领状态无过期。业务侧只要有一次「拿到消息却没有 ack」，该位置对本订阅永久卡死，且 `deliveries` 无界增长——直接违反 README:122 的 at-least-once 承诺。这一点必须修（加 TTL + 容量上限），否则任何消费异常的累积都会把一部分消息静默吞掉。
2. **排期修复**：#2 owner 集合不刷新（扩缩容后订阅空转、无告警），这是集群能力与客户端状态模型之间的结构性缺口；#3 缓存无清扫，属于慢泄漏。
3. 其余为工程卫生：四处同构样板（改一处漏一处的风险）、构造函数双写、异常分类学、`remove(at: 0)`、无用 `var`/冗余锁、用例提前删除全局配置。

性能方面本轮**没有拿到任何测量数据**（本部分的分配基准用例默认跳过、也没有记录绝对值），因此全部性能判断都停在「待验证假设」：「优化可行性方案」里的 `copyBytes` 副本与 `deliveries` 字符串键是最值得先补数据的两个点，但按现有证据不能声称收益比例。

本报告为第 5/6 部分，仅统计本部分 20 个文件；`MQSubscription.cj`、`MQClient_test.cj` 等仅作调用链与旁证引用，未计入覆盖与统计。
