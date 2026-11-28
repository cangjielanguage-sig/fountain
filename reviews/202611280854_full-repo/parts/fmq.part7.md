# fmq 模块审查报告（第 7/7 部分：服务端装配、订阅表与测试支撑）

- **审查日期**：2026-11-28
- **模块路径**：`fmq/src/server`（装配/订阅表 4 个源文件 + 3 个测试文件）、`fmq/src/test`（1 个测试辅助）
- **本部分文件**：`fmq.part7.txt` 全 8 个（`.cj` 8 / `.md` 0）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源为「存量」
- **审查重点**：投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑（本部分落到「服务生命周期状态机 + 订阅表 + 测试基建」）
- **报告版本**：分部分报告 v1，由主 Agent 合并进 `docs/review/2026-11-28/fmq_v2.md`

## 发现

### [一般] [存量] `SubscriberRegistry.generations` 只增不减，键是客户端每次新生成的 UUID

- **位置**：`fmq/src/server/SubscriberRegistry.cj:33`（声明）、`:49-54`（每次 `register` 写入）、`:128-133`（`clear()` 不清）；键来源 `f_mq/src/client/MQClient.cj:141`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「无界容器」/「缓存键无界：用户 ID / 请求 ID 做 key，没有容量、TTL、淘汰」；§12.1「有界性」
- **证据**：静态确定 —— 全仓只有 `register` 写入 `generations`，`unregister`（`:76-90`）与 `clear()`（`:128-133`）都不删条目，`byId`/`byGroup` 清了它不清；`subscribedId` 由客户端 `UUID.random().toString()` 生成，同一逻辑订阅每次重连都是新键
- **描述**：生产者侧每次 `SUBSCRIBE` 必然产生一个从未被回收的映射项，`unsubscribe`、断链清理、`close()` 都不会移除。长期运行的服务端，条目数 = 进程生命周期内的 SUBSCRIBE 总次数（与当前在线订阅数无关）。按 `HashMap` 节点 + 36 字符 UUID 串估算约 100–150 B/条：100 万次订阅约 100–150 MB 常驻且不回落；客户端可用「反复订阅/退订同一主题」（只需一个已存在的主题与组）稳定推高。`byGroup` 同理：`removeFromGroup`（`:200-209`）把组内列表清空后不删 key，残留空 `ArrayList`，但其数量受 `(topic, group)` 组合数约束，量级远小于 `generations`。本条按单请求增量小、需百万级累计才到 OOM 量级定为「一般」；若从严按 §5 的「无界增长」口径，可直接升为「严重」。
- **建议**：给 `generations` 加 TTL 或按「无活跃订阅」修剪。代次只需要覆盖一次巡检快照的存活期（`MQServer.CLEANUP_INTERVAL = 2s`），因此可在 `unregister` 成功后把该 id 的条目降级为「待修剪」并记录时间戳，定时器里删除「距上次登记 > 若干倍 CLEANUP_INTERVAL 且 `byId` 中已无该 id」的条目；`clear()` 里应一并 `generations.clear()`（关闭语义已由 `closeCompleted` 保证，不需要跨 close 保留代次）。`byGroup` 的空列表在 `removeFromGroup` 内顺手 `byGroup.remove(key)`。

### [一般] [存量] 生命周期状态机不完整：`start()` 不看 `closed`，且 `server`/`cleanupTimer` 与 `close()` 无同步

- **位置**：`fmq/src/server/MQServer.cj:57`（`private var server`）、`:60`（`cleanupTimer`）、`:166-190`（`start()`）、`:187-189`（`spawn`）、`:239-263`（`close()`）、`:206-232`（`closeSteps()` 的 `"server"` 步骤）；调用序 `fmq/src/main.cj:102-111`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「资源不对称 / 语义与注释不符」、§12.1「可见性：用普通字段当跨线程信号」「发布逸出」
- **证据**：静态确定 —— `start()`（`:166`）只做 `started` 的 CAS，没有读 `closed`；`close()`（`:244`）只置 `closed`，两个入口之间没有互斥；`server`/`cleanupTimer` 是普通 `var`，写入在 `start()`、读取在 `closeSteps()`/`cancelCleanupTimer()`，而 `close()` 由 `ExitCallbacks` 的信号回调在另一线程执行（`f_base/src/signal.cj:39-47` 注册 handler，`onExit()` 内直接同步调用回调）
- **描述**：两个可复现的状态机缺口。
  1. `close()` 之后调用 `run()`（`run()` 无条件 `start()`）：`started` 仍为 `true` 时 `start()` 直接返回，`closed` 已为 `true` 使 `run()` 立即返回 0 —— 这没问题；但**从未启动**的实例先 `close()` 再 `run()` 时，`started=false`，`start()` 会重新起 `backup`/`cleaner`/反熵/巡检定时器并 `new Server(bindAt: port)` 绑端口，随后 `run()` 因 `closed` 立刻返回 —— 留下一个已绑定端口、定时器在跑、无人关闭的实例。现有用例 `MQServer_test.cj:489-501` 先在 490 行 `start()` 过，恰好绕开了这个分支。
  2. `SIGTERM` 在 `this.server = Some(srv)`（`:185`）之前到达：`close()` 的 `"server"` 步骤把 `None` 当成功（`:208-213`），写入 `closeDone` 并把 `closeCompleted` 置 `true`；随后 `start()` 继续 `new Server(...)` 并 `spawn`，这个 Server 永远不会被关闭（端口被占、accept 线程常驻），而 `close()` 已宣告完成。窗口窄但确实存在，且注释 `:178`「端口最后绑定：装配失败或定时器启动失败都不会留下已占用端口」只覆盖了抛异常路径，没覆盖 close 并发路径。
- **建议**：把 `start`/`close` 放进同一个 `Mutex`（或让 `close()` 复用 `closeLock` 并在 `start()` 的绑定段内取同一把锁），`start()` 入口先 `if (closed.load()) { return }`；`closed` 置位与 `started` 的检查放在同一临界区，避免「close 先于 bind」。若要保持无锁，至少把 `server` 改成在 `start()` 内先构造、再在锁内发布，且 `closeSteps` 的 `"server"` 步骤在 `None` 时不要计入 `closeDone`。

### [一般] [存量] `MQManager_test` 的端口探测与就绪等待不 `connect()`，用例可能在服务未监听时继续

- **位置**：`fmq/src/server/MQManager_test.cj:49-62`（`freePort`）、`:64-80`（`waitReady`）；正确实现对照 `fmq/src/server/MQServer_test.cj:50-65`（`isListening` 显式 `connect()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「近似重复：两块代码相似度高，但其中一块少了边界判断 —— 这往往同时是缺陷」、§11「边界 / 错误处理缺失」
- **证据**：静态确定 —— 同仓 `MQServer_test.cj:50` 的注释就是作者自己的结论：「该端口是否已有监听者：TCP 构造函数不建连，必须显式 `connect()`」。`MQManager_test` 的两处都只 `TcpSocket(IPSocketAddress(...))` + `close()`，从不 `connect()`
- **描述**：`freePort()`（`:52-56`）永远第一次就返回 `nextPort.fetchAdd(1) % 60000` 的结果，即使该端口已被别的进程/用例监听（构造不连通不报错），因此「找空闲端口」退化为「取下一个自增端口」；`waitReady()`（`:69-71`）更严重 —— `probe.close()` 恒成功，`ready` 第一轮就为 `true`，等于完全不等待，`startServer`（`:93-95`）返回后用例立刻发管理请求，服务端尚未绑定端口时会走到「无法连接」分支，表现为**偶发失败**，或把真实的启动失败掩盖成连接失败。`MQManager_test` 的 18 个 `@TestCase` 里有 14 个经由 `startServer`/`freePort`/`waitReady` 拿端口与就绪信号（其余 4 个不连服务端）。
- **建议**：删除 `MQManager_test` 的私有实现，改为复用 `MQServer_test` 的 `ServerPortAllocator.freePort()`/`waitReady()`（同包，直接把 `ServerPortAllocator` 提成两文件共用的测试 helper，或并入 `TestDirs` 所在包）；至少把探测改成 `connect()` 并 `catch` 判定。

### [一般] [存量] 服务线程异常无处传播：`spawn { srv.start(...) }` 无 catch，`run()` 只轮询 `closed`

- **位置**：`fmq/src/server/MQServer.cj:187-189`（`spawn`）、`:193-199`（`run()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失或静默」、§12.1「异步语义：`Future` 异常被吞」
- **证据**：静态确定（无传播路径）+ 待确认（触发条件落在 `f_net`）—— `MQServer` 侧既没有 `try` 也没有保存 `Future`/状态位，`run()` 的唯一退出条件是 `closed.load()`；而 `f_net` 的 accept 循环里 `params.populate(socket)`（`f_net/src/server/server.cj:136`）与 `SocketBuffer(bufferQueueSize, socket)`（`:137`）在 `try` 之外，任一抛异常都会让 `start()` 直接返回
- **描述**：一旦 accept 循环因非 `SocketException` 的异常退出（socket 选项设置失败、缓冲分配失败、以及 `:138` 的 `buffers.add`），`MQServer` 的 `spawn` 线程结束、服务端不再接受任何连接，但 `isClosed()` 仍为 `false`、`closed` 仍为 `false`，`run()` 继续 200ms–500ms 空转，进程既不退出也不告警 —— 表现为「进程活着、端口不通、日志无线索」。这与「`run()` 阻塞运行（生产入口）」的契约相冲突：调用方没有任何手段分辨「在服务」与「服务线程已死」。
- **建议**：在 `spawn` 内 `try { srv.start(executor.execute) } catch (e: Exception) { log.error(...); closed.store(true) }`，并新增一个「服务线程已退出」的原子状态供 `run()` 判定（退出码非 0）；或把 `srv.start` 的返回/异常通过 `Future`/`AtomicBool` 回传，让 `run()` 在服务线程死亡时返回非 0 而不是继续空转。

### [轻微] [存量] `MQSubscriptionInfo.connectionKey` 是死字段，`buffer` 声明为 `var` 但从不重赋值

- **位置**：`fmq/src/server/MQSubscriptionInfo.cj:35`（字段）、`:52-56`（唯一赋值，每次构造多算一次 `remoteAddress.toString()`）、`:36`（`var buffer`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「无调用者 / 兼容残留」；`fn` 全仓检索范围：整个 `fountain` 工作区
- **证据**：静态确定 —— 全仓 `connectionKey` 仅命中定义处 `:35` 与赋值处 `:52`（`grep -rn connectionKey` 另有文档与历史报告，无读取点）；`buffer` 的写入仅 `:51` 构造赋值，全仓无 `\.buffer\s*=` 的其他命中
- **描述**：`connectionKey` 是 `removeByBuffer` 链（已删除）的残留：构造时对每个 `SUBSCRIBE` 多做一次 `SocketAddress.toString()` 分配，之后没有任何读取者，属于「算了不用」。`buffer` 被声明为 `var` 会让读者以为断链后会被替换为 `EMPTY_SOCKET_BUFFER`，实际从未发生（测试是新建 `MQSubscriptionInfo`），`var` 徒增「可变共享状态」的误解。
- **建议**：删除 `connectionKey` 字段与 `:52-56` 的构造逻辑（顺带去掉一次字符串分配）；`buffer` 改 `let`。若确实需要「连接标识」，应真正接回 `unregister` 的归属判定（当前用 `generation` 承担，二者不要并存）。

### [轻微] [存量] `byGroupOf` 与 `activeIds` 对同一 `(topic, group)` 列表做两遍过滤，调用方连续调用两者

- **位置**：`fmq/src/server/SubscriberRegistry.cj:98-112`（`byGroupOf`）、`:168-187`（`activeIds`）；调用点 `fmq/src/server/ConsumeService.cj:73` 与 `:83`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「表现形式不同的重复逻辑：换控制流 / 只改类型名」，差异点必须点名
- **证据**：静态确定 —— 两个函数的体逐行对齐：都 `synchronized(lock)`、都取 `byGroup.get(groupKey(topic, group))`、都对每个 id 做 `byId.get` 存在性检查、都 `ArrayList → toArray`。差异只有两点：（a）`activeIds` 多一个 `!info.isDisconnected()` 过滤；（b）返回 `Array<String>` 还是 `Array<MQSubscriptionInfo>`
- **描述**：`ConsumeService.consume` 先 `byGroupOf` 拿全部成员并在调用方按 `!isDisconnected()` 过滤出 `members`（`:73-78`），紧接着 `activeIds`（`:83`）把同一个列表再遍历一遍、再判一次 `isDisconnected()`。每次 `CONSUME` 因此多一次全局锁获取、一次 O(组内订阅数) 扫描、一个 `ArrayList` + 一个 `Array` 分配，且两份结果必须保持一致（新增过滤条件时极易只改一处 —— 这正是「重复逻辑导致行为漂移」的典型形态）。
- **建议**：保留一个「按组快照」入口，`activeIds` 由调用方从 `members` 派生（`Array<String>(members.size) {i => members[i].subscribedId}`），或让 `byGroupOf` 增加 `activeOnly!: Bool = false` 参数并在内部一次遍历完成；`ConsumeService` 只调用一次。注意保留语义差异：`byGroupOf` 的其它调用点若需要「含断链订阅」的全量视图，必须显式传 `activeOnly: false`。

### [轻微] [存量] 测试装配与断言 helper 重复（跨文件两套端口/就绪/装配代码 + 两个近乎逐行相同的用例）

- **位置**：`fmq/src/server/MQManager_test.cj:82-96`（`startServer`）vs `fmq/src/server/MQServer_test.cj:76-84`（`options`）；`MQManager_test.cj:98-116`（`manager` / `managerWithOutput`）；`MQManager_test.cj:118-128`（`joined`）；`MQServer_test.cj:525-569` 与 `:596-640`（两个断链释放用例）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「同文件内两两比对函数体」「跨文件搜相同字面量/同一套装配」
- **证据**：静态确定 —— `startServer` 与 `options` 都用同一串 12 个参数（`Duration.second*10, 3, Duration.hour*72, "${root}/logs", "${root}/dead", 1024*1024, Duration.hour*72, 0, "${root}/metas"`）构造 `MQServerOptions`，只有「是否顺带 `start()`+`waitReady`+拼地址」不同；`manager(args)` 与 `managerWithOutput(args)` 的差异只有第二个 sink 参数；`joined` 是 `String.join(lines.toArray(), delimiter: "\n")` 的手写版本；两个 cleanup 用例的步骤完全一致（注册主题/组 → 订阅 → publish "held" → consume 断言 → 造断链订阅 → cleanup → 新订阅取到 "held" → ack），只差「怎么把订阅标成断链」。
- **描述**：测试基建重复本身不是缺陷，但这里的重复已经产生实际后果：同一份「端口探测」在两处实现、其中一处漏了 `connect()`（见上一条「一般」），且两个 cleanup 用例维护成本翻倍（A55/A60/A70 的断言分散在两处，改一处漏一处）。`joined` 手写拼接还多了一层 `StringBuilder` 逻辑，与 `String.join` 的语义需要人工对齐。
- **建议**：把 `MQServerOptions` 的测试构造、`freePort`/`waitReady`、`manager(...)` 收敛成一份（放 `fmq.test` 包的测试 helper，与 `TestDirs` 同级）；`manager`/`managerWithOutput` 合并为带 `sink!: ?(String) -> Unit = None` 的单函数；`joined` 换成 `String.join`；两个 cleanup 用例合并为「注入断链方式」参数化的一个用例。

### [轻微] [存量] `TestDirs` 硬编码 `/tmp`，且 `cleanNamespace` 用空 catch 吞掉清理失败

- **位置**：`fmq/src/test/TestDirs.cj:39`（`"/tmp/fmq_test_..."`）、`:46`（同）、`:48-52`（`catch (_: Exception) {}`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符 / 跨平台」、§3「`catch {}` 静默吞异常（有意 no-op 需注释）」
- **证据**：静态确定 —— 路径字面量写死 `/tmp`，无 `os`/`TMPDIR` 分支；空 catch 体没有任何注释说明「为什么失败可以忽略」；同仓 `f_base/src/signal.cj:70-74` 明确存在 Windows 分支，说明该工程需要跨平台构建
- **描述**：Windows 上 `/tmp` 通常不可写，`Directory.create(dir, recursive: true)`（`:40`）会直接抛错，`fmq` 的全部单测（`TestDirs.of` 被 `MQServer_test`/`MQManager_test`/`ConsumeService_test`/`MQCommandExecutor_test`/`BackupStore_test` 共用）在该平台无法运行；这与 `f_base` 已做的 Windows 兼容形成不一致。空 catch 使得 `@AfterAll` 清理失败完全无声，残留目录会跨轮累积（`/tmp/fmq_test_*` 只在断言失败时被发现）。
- **建议**：路径改为 `Path`/环境变量派生（`TMPDIR` → 平台默认临时目录），与 `MQConfig` 的目录处理保持一致；空 catch 至少加一行 `// 清理失败不影响用例结果，残留目录由下一轮 cleanNamespace 覆盖` 并降级为可选告警。若确定只在 Linux/ohos 跑单测，应在 `TestDirs` 头部写明平台约束，而不是让调用方在 Windows 上碰到一个裸 `Directory.create` 异常。

### [轻微] [存量] 设计文档称 `byGroupOf` 返回「所有活跃订阅」，实现不过滤断链订阅

- **位置**：文档 `fmq/doc/详细设计.md:648-649`；实现 `fmq/src/server/SubscriberRegistry.cj:98-112`（对照 `activeIds` `:168-187` 的过滤与注释 `:176`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 语义与文档不符」，必须给两边位置
- **证据**：静态确定 —— 文档写「该主题该组下的所有活跃订阅（组内选人、匹配判定用）」，实现只做 `byId` 存在性检查并全部返回，断链过滤在 `activeIds`（`:177`）和调用方 `ConsumeService.cj:75`；`activeIds` 的注释「断链订阅不是『活跃』：否则它的记录永远不会退回组内（A55）」正是对「活跃」的定义
- **描述**：按文档字面理解，`byGroupOf` 的返回值可直接用于「组内选人」，实际会包含已断链订阅，调用方必须再过滤一次（`ConsumeService` 确实这么做了）。这正是上一条「重复遍历」的根因：文档把「活跃」的语义给了 `byGroupOf`，实现却把这个语义留给了调用方和 `activeIds`。
- **建议**：二选一并同步文档 ——（a）让 `byGroupOf` 真正过滤 `isDisconnected()`，`ConsumeService` 去掉 `:75` 的重复过滤；（b）文档改成「该组下全部登记中的订阅（含断链），活跃判定见 `activeIds`」。`详细设计.md` 属另一部分的文件，本条的修改落点需与那一部分合并处理。

### [轻微] [存量] `executors: 200` 与 `f_net.Server` 的默认值重复，巡检/检查周期硬编码

- **位置**：`fmq/src/server/MQServer.cj:183-184`（`checkDuration: CHECK_DURATION, executors: 200`）、`:40-41`（`CHECK_DURATION` / `CLEANUP_INTERVAL`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10「可读性 / 可维护性」、§2「字面量复制」
- **证据**：静态确定 —— `f_net/src/server/server.cj:110` 的签名就是 `executors!: Int64 = 200`，此处显式传 200 与库默认值完全相同，却让「线程池大小」看起来是本模块的策略
- **描述**：三个常量（30s 连接检查、2s 订阅巡检、200 线程）都在代码里写死，既没有配置项也不在 `MQConfig` 校验范围内；`executors: 200` 尤其容易误导——它暗示 MQ 侧做过容量决策，实际只是抄了默认值。200 个 executor 线程 + 每 2s 一次全量订阅巡检的线程/CPU 成本没有对应的配置入口，部署侧无法按节点规模调整。
- **建议**：删掉 `executors: 200`（用库默认，需要时再显式配置）；把 `executors` 与 `CLEANUP_INTERVAL` 提为 `MQConfig` 项（默认值保持不变），或在类注释里写明「与 f_net 默认一致，暂无配置入口」的理由。

## 优化可行性方案

> 以下均无改前基线，因此只作方案，不进 `todo.md` / `tasks.md`。

### [CPU] 消费路径合并两次组快照，复用 `views` 数组

- **现状**：每次 `CONSUME` 在 `SubscriberRegistry` 上取两次全局锁、做两次 O(组内订阅数) 遍历（`byGroupOf` `:98-112` + `activeIds` `:168-187`），再在 `ConsumeService.cj:82` 为每个成员生成一个 `MQSubscriptionView` 数组；单次消费至少 3 个短命容器（两个 `ArrayList`、两个 `toArray()` 结果、一个 views 数组）
- **方案**：`byGroupOf` 返回值直接带 `active` 标记或在内部完成 `isDisconnected()` 过滤，`ConsumeService` 用一份快照同时得出 `members` 与 `active` id 集合；`views` 改为 `Array<MQSubscriptionView>(members.size)` 一次填装（当前已是），进一步可把「同组成员」按 `generation` 缓存到订阅登记时
- **预期**：每次消费少一次加锁与一次 O(k) 遍历（k = 组内订阅数）；k=50、QPS=10k 时约省 50 万次/秒的比较与一次锁竞争名额。端到端收益需 profile 确认，按 §6.1 的 Amdahl 口径在未测前不给百分比
- **代价**：`byGroupOf` 语义变化会影响其它调用点（需保留 `activeOnly` 开关）；缓存 `views` 需要在 register/unregister 时失效，复杂度上升
- **验证**：`cjpm bench -O2`，固定 1 组 50 订阅 / 4 队列，测 `consume` p50/p99 与 `byGroupOf`+`activeIds` 的 `cjprof` self time 占比，改前改后各 5 轮取中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 订阅表单锁读写分离

- **现状**：`SubscriberRegistry` 用一把 `Mutex`（`:29`）同时保护 `byId` / `byGroup` / `generations`；`of()`（`:92-96`）在每次 `CONSUME`/`ACK`/`UNSUBSCRIBE` 都被调用（`MQCommandExecutor.cj:341,356,371`），`register`/`unregister` 是写。读多写少，但读也要排同一把锁
- **方案**：`byId` 换成不可变快照 + 原子替换（写时复制，读无锁）；或按 `subscribedId` 哈希分片成 N 把锁。`generations` 与 `byGroup` 的跨字段不变量（register 同时改三张表）仍需在同一临界区内完成，建议保持一把写锁、只把 `of()` 的读路径移出
- **预期**：`of()` 的锁等待消失；高并发 consume/ack 下减少 BLOCKED 线程。收益上限取决于锁等待占比（CPU profile 看不出来）
- **代价**：写时复制的 `HashMap` 每次写 O(n) 拷贝，订阅频繁变更时更慢；分片需要保证 `byGroup` 与 `byId` 的一致性协议
- **验证**：50 线程 × 10k 次 `consume`+`ack` 的压测，采线程状态（BLOCKED/WAITING 时长）与 p99 延迟，改前改后对照；`cjprof` 只作辅助
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 巡检/消费快照去副本

- **现状**：`infos()`（`:190-198`）、`byGroupOf`、`activeIds`、`byTopicOf` 每次调用都 `ArrayList → toArray()`；`MQServer.cleanupSubscribers` 每 2s 对全部订阅做一次 `infos()` 快照（`MQServer.cj:305`）。N 条订阅 ⇒ 每 tick 一个长 N 的数组 + 一个 `ArrayList` 的中间扩容，全部短命
- **方案**：把 `infos()` 的返回改为「直接遍历不可变快照」（维护一个写时复制的数组，register/unregister 时替换），或让 `cleanupSubscribers` 接受回调式遍历（`forEachInfo(f)`），在锁内只做 `isDisconnected()` 与代次判定，把 `releaseSubscription` 移出锁（当前已在锁外）
- **预期**：每 2s 少一次 O(N) 数组分配；N=10k 时约 80 KB/次、43 MB/天 的分配量下降（按 8 B 引用粗算，未计对象头）。是否影响 GC 停顿需实测
- **代价**：回调式遍历会把「锁内执行用户回调」引入 `SubscriberRegistry`，必须保证回调不重入该锁（`releaseSubscription` 取的是 `GroupCursor` 锁，顺序为 registry→cursor，与 `ConsumeService.consume` 一致，需在注释里固定该顺序）
- **验证**：10k 订阅 / 2s tick 跑 30 分钟，采 `getAllocatedHeapSize()` 增速、RSS 稳态、GC 次数，改前改后对照
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SubscriberRegistry` 的单锁在消费高峰成为串行段（每次 `CONSUME` 至少 3 次 `of`/`byGroupOf`/`activeIds` 取锁） | `SubscriberRegistry.cj:29,92-96,98-112,168-187` | 锁等待时长、BLOCKED 线程数、p99 | 50 线程压 `consume`+`ack`，采线程状态与 p99；`cjprof` 无法反映锁等待 |
| 2 | 2s 巡检在 timer 线程上串行处理全部断链订阅，订阅数大时单轮超过 2s（`Timer.repeat` 会顺延） | `MQServer.cj:174-177,304-320` | 单轮 `cleanupSubscribers` 耗时 vs 订阅数 | 注入 1k/10k 断链订阅，埋点计时单轮耗时与 `releaseSubscription` 累计耗时 |
| 3 | `close()` 的 `subscribers.clear()` 之后仍可能有在飞请求写入订阅表，使「关闭后订阅表为空」的断言偶发失败 | `MQServer.cj:217-219` 与 `f_net/src/server/server.cj:209-211`（`close` 最多 3 轮关 buffer，不等执行中的 executor） | 是否存在 close 后仍执行 `onSubscribe` 的窗口 | 并发压测：持续 `SUBSCRIBE` 的同时 `close()`，之后断言 `infos().size == 0`，重复 1000 次统计失败率 |
| 4 | `removeFromGroup` 的 `indexOf` + `remove(at:)` 在超大订阅组（>10k）下使注销/重订阅变成可见开销 | `SubscriberRegistry.cj:200-218` | 组规模上界、单次注销耗时 | 1k/10k/50k 同组订阅下测 `unregister` p99；组规模由客户端数决定，需先确认部署上限 |
| 5 | `MQServer` 每个节点固定 `executors: 200` 线程对 RSS 的贡献（线程栈默认大小 × 200） | `MQServer.cj:183` | 进程线程数、线程栈占用、RSS 构成 | `pmap`/`/proc/<pid>/status` 采线程数与栈 RSS，单节点空载与满载对照 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fmq/src/server/MQManager_test.cj` | .cj | ✅ | 见「一般」#3（端口探测/就绪等待）、「轻微」测试 helper 重复 |
| 2 | `fmq/src/server/MQServer.cj` | .cj | ✅ | 见「一般」#2（生命周期）、#4（服务线程）；「轻微」死字段/重复遍历/硬编码 |
| 3 | `fmq/src/server/MQServerOptions.cj` | .cj | ✅ | `protected struct`，14 个字段全部被 `MQServer.init` 或 `sweepTombstones`/`start` 读取，无死字段；`fromConfig` 与 `MQConfig.validate()` 一一对应，无配置项遗漏 |
| 4 | `fmq/src/server/MQServer_test.cj` | .cj | ✅ | 其 `isListening`/`waitReady` 为正确实现，被引作 #3 的对照；两个 cleanup 用例近乎重复（见「轻微」） |
| 5 | `fmq/src/server/MQSubscriptionInfo.cj` | .cj | ✅ | 见「轻微」`connectionKey`/`buffer` |
| 6 | `fmq/src/server/SubscriberRegistry.cj` | .cj | ✅ | 见「一般」#1（`generations` 无界）、「轻微」重复遍历/文档不一致 |
| 7 | `fmq/src/server/SubscriberRegistry_test.cj` | .cj | ✅ | 8 个用例覆盖 register/unregister/代次/断链活跃判定/并发登记，与实现一致；无死 helper |
| 8 | `fmq/src/test/TestDirs.cj` | .cj | ✅ | 见「轻微」`/tmp` 硬编码与空 catch |

合计：`.cj` 8 个 / `.md` 0 个 / 共 8 个，全部读完（与 `files/fmq.part7.txt` 8 行一一对应）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性 3（生命周期状态机、服务线程异常、代次表无界）、语言特性 1（`var buffer` 从不重赋值）、可读性 1（硬编码 200/2s/30s 重复库默认值，与「轻微」条目合并计）、设计 1（`close()` 粗锁持锁做 I/O，判定为关闭路径的幂等实现，不另计）。安全性：本部分无外部输入直接拼接 SQL/路径/命令，`subscribedId` 只作 map 键，未见注入面；敏感数据未进日志（记录内容不进日志）。分层：`server` 依赖 `queue`/`meta`/`cluster`，无反向依赖 |
| §1 死代码 | 1 | 已逐个符号机械核对：`MQServer` 的全部 private 成员（`log`/`CHECK_DURATION`/`CLEANUP_INTERVAL`/25 个字段/`reconcileDeletions`/`currentCloseSteps`/`cancelCleanupTimer`/`ensureDir`）全部有读取者或调用者；`MQServerOptions` 的 14 个字段全部被读；`SubscriberRegistry` 的 `groupKey`/`indexOf`/`removeFromGroup` 与 10 个公开方法全部有仓内调用（`clear`/`infos`/`byTopicOf`/`activeIds` 见 `MQCommandExecutor.cj:292,333,341`、`ConsumeService.cj:73,83`、`MQServer.cj:219,305`）；`TestDirs` 三个成员全部被 5 个测试文件使用。`MQServer` 的 10 个 `protected` 成员（`init(options:)`/`port`/`start`/`closeSteps`/`cleanupSubscribers`/`sweepTombstones`/`beforeBind`/`syncQueuesOverride`/`subscriptionRegistry`/`setCloseStepsOverride`）虽只被同模块测试使用，但**有引用**，按 §1「仅测试使用」记为可见性建议而非死代码：`public class MQServer` 未标 `open`，这些 `protected` 对外并无扩展点价值，若下游确实不需要自定义装配，可降为 `internal` 并让测试走 `@Test` 同包可见。唯一死代码是 `connectionKey`（全仓无读取） |
| §2 重复逻辑 | 3 | 已把本部分 11 个非测试函数体压成「输入→输出→副作用」两两比对（`init×2`/`reconcileDeletions`/`start`/`run`/`closeSteps`/`close`/`cleanupSubscribers`/`sweepTombstones`/`ensureDir`/`installExitHooks`），无同语义实现；命中 3：`byGroupOf` vs `activeIds`（同一遍历两种投影）、测试侧 `freePort`/`waitReady`/`startServer`/`options`/`manager`/`managerWithOutput`/`joined`（跨文件两套）、两个 cleanup 用例逐行对齐。另记录一处**同语义不同顺序**（有兜底、不计缺陷）：`MQServer.cleanupSubscribers` 先 `unregister` 再 `releaseSubscription`（`:309-314`），`MQCommandExecutor.onUnsubscribe` 先 `release` 再 `unregister`（`:345-347`）；`releaseSubscription` 抛 `IllegalArgumentException`（`ConsumeService.cj:137`，队列不再本机）时后者会把记录留在已删订阅名下，但 `ConsumeService.consume` 每轮先 `cursor.sweep(active)`（`:87`）会把 owner 不在活跃集合的记录退回组内，故不构成丢消息，仅建议统一顺序并在注释里说明兜底 |
| §3 空实现 | 1 | `TestDirs.cleanNamespace` 的 `catch (_: Exception) {}`（`:48-52`）为唯一空实现/静默吞异常，已按「轻微」计（仅测试收尾、无业务后果，但缺「为什么可以忽略」的注释）。`MQServer` 的四处 catch（`:151-155`、`:313-318`、`:334-336`、`:253-256`）均有 ERROR/WARN 日志，非静默 |
| §4 栈溢出 | 0 | 本部分无递归：`reconcileDeletions`/`close`/`cleanupSubscribers`/`sweepTombstones` 均为单层 for 循环，无自引用结构遍历，无每帧大对象；`MQSubscriptionInfo` 无父子引用 |
| §5 OOM | 2 | 命中 `generations` 只增不减（含 `byGroup` 空列表残留，合并计 1 条）、`closeDone`/`failures` 虽无界但受步骤名与固定 13 步约束（不计）。已量化：约 100–150 B/次订阅、百万级才到百 MB 量级；`TestDirs` 的临时目录只在测试进程内增长（不计） |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 `cjprof`/`cjpm bench` 数据，`of`/`byGroupOf`/`activeIds` 的锁与遍历成本一律进「待验证假设」#1、优化方案，不作缺陷。历史 `parts/fmq.part6.md` 已就 `byTopicOf` 的全表扫描记录过一条同类方案，本部分不重复 |
| §6.2 大粒度锁 | 0 | `close()` 在 `closeLock` 内执行 `server.close()`/`queues.sync()`（fsync）/`meta.close()`（`MQServer.cj:240-262`），属「锁内 I/O」，但只在关闭路径、无请求并发、且粗锁正是「幂等 + 失败步骤可重试」的实现基础（`closeDone`/`closeCompleted` 需与步骤执行原子），判定为可接受；`SubscriberRegistry` 的单锁是否成为热点见 §6.1/§12.2 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立即 `get()`；accept 循环每连接 `spawn`（`f_net`），执行器池 200；唯一的串行段是 2s 巡检 timer 线程上的 `cleanupSubscribers`（O(订阅数)），已列「待验证假设」#2 |
| §6.4 低效算法 | 1 | `removeFromGroup` 的 `indexOf`（O(n)）+ `ids.remove(at: index)`（O(n)）每次注销/重订阅扫两遍组内列表（`SubscriberRegistry.cj:200-218`），列「待验证假设」#4（组规模无数据，不作缺陷）；`byTopicOf` 的 O(全表) 已由 part6 记录，不重复 |
| §7 降堆内存方案 | 1 | 巡检/消费快照 `toArray()` 副本（方案已写，无基线）；`clear()` 只清元素不还物理内存的事实已在方案「代价」中提示；`generations` 的修剪归入「一般」#1 的修法，不重复计方案 |
| §8 降 CPU 方案 | 2 | 消费路径两次组快照合并、订阅表读写分离（均无基线） |
| §9 local mode 可行性 | 0 | 本部分函数内无「大对象 + 函数内销毁」形态：`start`/`close` 的临时对象是 13 个闭包 + 小数组（一次性），`cleanupSubscribers`/`byGroupOf` 的临时容器按订阅数增长但单元素是引用（不复制 `MQSubscriptionInfo`）；无峰值内存数据，无法证明 local region 收益，且需 `--experimental --enable-local-mode` 全模块开启、`SocketBuffer`/`MQSubscriptionInfo` 均要 `@ local!` 重建，收益/风险不成立 |
| §11 现有代码的 BUG（存量） | 7 | 本轮读到的存量问题：#1 代次表无界、#2 生命周期状态机（含 close-before-bind 漏关）、#3 测试端口探测不 connect、#4 服务线程异常不可观测、#5 死字段、#6 重复遍历、#7 `/tmp` 硬编码；另逐项核对过的边界：`close()` 空 `failures` 才算完成（`:258`）、`unregister` 代次不符返回 `SUBSCRIBE_NOT_EXIST` 且不删（`:80-83`）、`cleanupSubscribers` 在代次不符时 `continue` 且不释放（`:310-312`）、`freePort` 200 次上限后抛错、`reconcileDeletions` 对「墓碑对应条目已复活」`continue`（`:140-147`）、`sweepTombstones` 单步异常只 WARN（`:334-336`）—— 均与注释/规格一致 |
| §12 并发安全与锁粒度 | 4 | 已列出共享点与同步手段：`SubscriberRegistry` 三张表由 `lock` 保护（读写都在 `synchronized` 内，`removeByTopic` 先收 victims 再删，避免迭代中改容器）；`MQServer` 的 `started`/`closed` 用 `AtomicBool`；`close` 用 `closeLock` 保证幂等；`generation` 在 registry 锁内写、`infos()` 取锁建立 happens-before 后在锁外读（同一对象不再被并发改写，因为 `register` 总是新建 `MQSubscriptionInfo`）—— 判定无数据竞争。命中 4：`server`/`cleanupTimer` 普通字段跨线程读写（#2）、服务线程异常（#4）、代次表无界（#1）、订阅表单锁粒度（优化方案）。`beforeBind`/`syncQueuesOverride`/`closeStepsOverride` 是测试注入点，写入发生在 `start()` 之前，不构成并发缺陷 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分公开面仅 `MQServer`（`init`/`run`/`close`/`isClosed`）与 `installExitHooks`：`README.md:62-63` 描述 SIGTERM 关闭链路、`:185`/`:189` 符号表列出 `installExitHooks` 与 `MQServer.isClosed`，`doc/详细设计.md:607-618` 给出 `run`/`close` 与装配顺序、`:168` 说明 `installExitHooks` 的可注入设计；`MQServerOptions`/`MQSubscriptionInfo`/`SubscriberRegistry` 均为 `protected`，不进 README 属正确。承诺的「close 幂等 + 失败步骤重试」「关闭后端口可再绑定」「断链清理可由测试直接触发」均有实现与用例（`MQServer_test.cj:184-209,440-592`）。`installExitHooks` 只做转发、把 installer 交给调用方，是否为过宽接口属设计口味（文档已声明可注入），不作缺陷 |
| 文件覆盖（§13 等） | 8/8 | 无缺文件；本部分无 `.md`，文档一致性只就 `详细设计.md:648` 的 `byGroupOf` 语义作交叉核对（已计「轻微」一条，`.md` 本身由另一部分覆盖） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

这一部分是 fmq 的「装配层 + 订阅表 + 测试基建」，主体质量不错：装配顺序与关闭顺序严格按规格的相反序执行，`close()` 的「逐步 try/catch + `closeDone` 记账 + 只重试失败步骤」是全仓少见的完整实现，断链清理用「快照 + 代次」解决了重订阅误删（A60），并有针对性用例；`SubscriberRegistry` 的两个索引在单锁内维护，读路径都有锁，未见数据竞争。

风险集中在两处。**第一是生命周期状态机**：`start()` 不检查 `closed`、`server`/`cleanupTimer` 用普通字段在「启动线程—信号线程」之间传递，导致「close 后再 run 会留下绑了端口的僵尸实例」和「SIGTERM 早于 bind 时漏关 Server 却宣告关闭完成」两个缺口；再叠加 `spawn { srv.start(...) }` 无异常传播，服务线程死亡对 `run()` 不可见。这三条都在生产主路径（SIGTERM 是唯一的正常退出方式），建议优先于其它问题处理，修法不需要改架构，只需一把锁 + 一个失败状态位。**第二是 `generations` 无界**：客户端 UUID 作键、永不回收，长跑节点的内存随历史订阅次数单调增长，属于可预期的慢性 OOM 面。

测试基建的问题值得单独提：`MQManager_test` 的端口探测漏了 `connect()`，使「等待就绪」恒真 —— 这不是风格问题，而是会让 14 个用例在服务未起来时继续执行，把「启动失败」误报成「连接失败」，同时把仓库里已经写对的版本（`MQServer_test.cj:50-65`）复制成了两套。修掉它能显著降低 fmq 单测的偶发失败率。

存量共 10 条（一般 4 / 轻微 6），是否纳入本轮修复待用户决定；其中「一般」#2、#4 建议优先，#3 属于测试可信度问题建议一并处理，#1 可排期。「优化可行性方案」3 条与「待验证假设」5 条均无基线，仅在下一轮补数据后进入修复清单。
