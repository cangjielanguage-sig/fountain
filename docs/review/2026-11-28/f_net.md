# f_net 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_net`（15 个 `.cj`，共 1925 行；3 个 `.md`，共 588 行）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；`git status --porcelain f_net` 为空，本报告全部问题来源记为「存量」）
- **审查重点**：网络 I/O 正确性与超时、资源释放、并发安全、死代码、重复逻辑、存量 BUG、README 覆盖率（通用维度 + 全部专项扫）
- **报告版本**：v1

## 发现

### [严重][存量] `writeTimeout` 配置从不落到 socket：写超时完全无效，慢对端可让写线程无限阻塞

- **位置**：`f_net/src/SocketParams.cj:29`（字段）、`:44`（`copy()` 里拷贝）、`:114-117`（setter）；对照 `f_net/src/SocketParams.cj:51-80`（`populate()` 全文）
- **来源**：存量（`git blame -L 26,32 -- f_net/src/SocketParams.cj` → `4be871f2f`（2026-10-02，换行符统一提交）；`populate()` 自 `be8139810`（2026-09-27）起从未引用该字段，不在任何本轮 diff 内）
- **判据**：review-checklist §11（契约与实现不符 / 配置项被读取却从未使用）、§3（承诺的行为实现为空）、§13（README 把它列为可用设置）
- **证据**：静态确定 —— 全仓搜 `writeTimeout_` 只有 3 处命中：`SocketParams.cj:29` 声明、`:44` `copy()` 拷贝、`:115` setter 赋值。`populate()`（`:51-80`）依次设置 `bindToDevice` / `keepAlive` / `linger` / `noDelay` / `quickAcknowledge` / `readTimeout` / `receiveBufferSize` / `sendBufferSize` / 三组 `socketOption`，**唯独没有 `socket.writeTimeout`**。而 `TcpSocket` 确实支持该属性（`std.net` 文档 `net_package_classes.md:4794`，超时抛 `SocketTimeoutException`），`f_email/src/transport/MailConnection.cj:86` 就是直接赋值用法。三条入口全都指向这条死路径：`ClientBuilder.writeTimeout`（`client.cj:407-410`）→ `params.writeTimeout(...)`；`MultiClientBuilder.writeTimeout`（`MultiClient.cj:67-71`）→ `add()` 里转发（`MultiClient.cj:150`）；`ServerBuilder.socketWriteTimeout`（`server.cj:291-294`）。下游 `f_rpc/src/client/ClientConfig.cj:212` 也在按配置调用它。
- **描述**：README `:80` 把 `writeTimeout` 列为 `ClientBuilder` 的常用设置，`f_rpc` 也按配置下发，但值在 `SocketParams` 里存下后就没有任何代码把它写给 socket。后果链：① 写线程 `SocketBuffer` 消费队列时执行 `message.encode().copy(to: this)`（`SocketBuffer.cj:76-79`）→ `socket.write` 无超时；对端停止读取、窗口打满时该线程永久阻塞在 `write`；② 队列是 `ArrayBlockingQueue(queueSize)`，满后 `transfer()` 每 50ms 重试（`SocketBuffer.cj:81-84`），调用方的 `Client.transfer` 随之长时间阻塞（默认 `queueSize = 1024`，阻塞时长按对端何时恢复计，无上限）；③ `close()` 只能靠 `FRAME_CLOSE_WAIT = 2s` 硬断（`SocketBuffer.cj:105,110-123`），日志写 "a frame is still being written … closing anyway"，即**半帧**——正是 `awaitFrameWrite` 想避免的结果。也就是说这个配置即使配了也没有任何保护作用，反而把「有界超时」退化成「无界阻塞 + 强制截断」。
- **建议**：在 `populate()` 里补 `socket.writeTimeout = writeTimeout_`（与 `readTimeout` 同一处，`SocketParams.cj:63` 旁），并在 `net_test.cj` / `src/test/socket_params_test.cj` 里加一条"设置 writeTimeout 后慢写路径会抛 `SocketTimeoutException` 而不是永久阻塞"的用例。补完后 README `:80` 的承诺才成立。

### [严重][存量] `Client.buffers` 在巡检回调里无锁读取、在 `closeLock` 内写入：数据竞争可能让 Client 误判"全部连接已关闭"并自行停机

- **位置**：`f_net/src/client/client.cj:227-236`（`for(b in buffers where b.isClosed())` + `close()`）对照 `:154-163`（`synchronized(closeLock)` 内 `buffers[i] = next`）
- **来源**：存量（`git blame -L 225,232 -- f_net/src/client/client.cj` → 读取侧循环来自 `be8139810`（2026-09-27）；写入侧 `buffers[i] = next` 由 `f5fd92704c`（2026-11-19）重写为在 `closeLock` 内执行，读取侧没有同步调整）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 发布逸出 / 可见性）、§11（并发正确性）
- **证据**：静态确定 —— `buffers` 是 `private var buffers = Array<ClientConnection>()`（`:80`）。写路径有两种，都在 `synchronized(closeLock)` 内：`reconnect()` 的 `buffers[i] = next`（`:161`），以及构造期 `this.buffers = ...`（`:175`）。读路径有三种：`:150` 与 `:179` 在锁内（正确）；`:227` 的 `for(b in buffers where b.isClosed())` **完全在锁外**，而它所在的定时回调与用户线程的 `transfer → readyConnection → reconnect`（`:315-321`）真并发：`transfer` 在任意业务线程上跑，`reconnect` 会在其中写 `buffers[i]`。
- **描述**：两个并发访问者是「Timer 巡检线程」与「调用 `Client.transfer` 的业务线程」，两者之间对 `buffers` 元素既无锁也无原子操作，缺少锁/原子带来的 happens-before。后果按严重度递增：① 巡检线程可能读到旧引用（上一代 `ClientConnection`），于是 `isClosed()` 为真被计入 `closed`；② `closed == buffers.size` 时执行 `close()`（`:230-232`），把**整个 Client** 置为 closed 并关掉所有连接——此后所有 `transfer` 抛 `ClientException("Client is closed")`，而实际上连接是活的；③ 通过数组写入发布 `ClientConnection` 而没有 happens-before，严格意义上属于不安全发布（对象虽在 `startReader` 内构造完并起了 reader/writer 线程，但其他线程看到它时没有任何内存序保证）。这段代码位于每次心跳周期（默认 `checkDuration`）的必经路径上，不是理论角落。
- **建议**：把 `:226-236` 整段挪进 `synchronized(closeLock)`（与 `:179` 同一把锁、同一临界区风格），或改成"遍历时持有快照"：`let snapshot = synchronized(closeLock) { buffers }` 后遍历快照。审计时同步检查 `sockets[i]`（`:160`）是否有同类无锁读。

### [一般][存量] `newServerSocket` 的 catch 清理是恒不执行的死代码：bind 失败时监听 socket 不会被关闭

- **位置**：`f_net/src/server/server.cj:327-338`（重点 `:328` 的 `sopt` 与 `:334` 的 `sopt?.close()`）
- **来源**：存量（`git blame -L 327,338 -- f_net/src/server/server.cj` → `be8139810`（2026-09-27））
- **判据**：review-checklist §1（不可达 / 空实现）、§11（资源不对称：打开未关、异常跳过释放）
- **证据**：静态确定 —— `sopt` 初值 `None`，只在 `s.bind()` 成功之后才被赋值为 `Some(s)`（`:332`）。而 `catch` 只在 `TcpServerSocket(bindAt:)`（`:330`）或 `s.bind()`（`:331`）抛异常时进入；这两种情况下 `sopt` 必然仍是 `None`，所以 `sopt?.close()` 是**恒定的 no-op**；同时 `s` 是局部变量，bind 失败后既没有 `close()` 也没有交给任何人。
- **描述**：`bind()` 失败（端口被占用、权限不足、地址不可用）时，已创建的 `TcpServerSocket` 句柄不会显式关闭，只能等 GC/终结器；`ServerBuilder` 的构造器也会因此泄漏一个 socket。异常本身还会以原始类型抛给调用方（见后文构建失败契约那条）。这段代码看起来"做了清理"，实际什么都没做，是最容易在 code review 里被漏过的一类假防御。
- **建议**：改成 `try { let s = TcpServerSocket(bindAt: bindAt); try { s.bind() } catch (e: Exception) { s.close(); throw e }; s }`——即把 `close()` 放在"已经拿到 `s`"的作用域内；顺带去掉 `sopt` 这个 Option 包装与 `getOrThrow()`（`newServerSocket` 也不需要靠 Option 来返回，`:337` 的 `getOrThrow()` 永远不会是 `None`）。

### [一般][存量] `Server.checkerId` 只在收到 ACK 时删除：断链连接的条目永久残留（无界增长），且同一地址重连会命中陈旧计数

- **位置**：`f_net/src/server/server.cj:39`（`ConcurrentHashMap<SocketAddress, PingCounter>`）、`:62-73`（`entryView` 递增）、`:162-163`（唯一的 `remove`）；相关关闭路径 `:84-94`、`:152-159`
- **来源**：存量（`git log -S "checkerId" -- f_net/src/server/server.cj` → `6462bddb3`（2026-08-09）随心跳机制引入，最后改动 `d75e7c9fa`（2026-08-10）；当前行内容 blame 为 `be8139810`（2026-09-27））
- **判据**：review-checklist §5（无界容器：键来自对端、没有容量/淘汰）、§11（资源不对称）
- **证据**：静态确定（"只有 ACK 才删"这一事实）+ 需实测（增长速度）。全文件 `checkerId` 只有 5 处引用：声明、`entryView` 取值/递增、心跳 ACK 分支的 `get` 与 `remove`。连接被关闭的三条路径——`available == false`（`:84-94`）、解码失败（`:152-159`）、`doClose` 关闭（`:191-205`）——**都没有** `checkerId.remove`。
- **描述**：① 每个"发了 PING 但没等到 ACK 就断链"的连接（客户端崩溃、网络中断、心跳超时被踢）都会在 `checkerId` 里留一条 `SocketAddress → PingCounter`，永不回收。长跑服务端 + 频繁短连接（含恶意空连接：连上、不 ACK、断开）时条目单调增长，属于按对端行为驱动的无界容器；单条很小（地址 + 16 字节计数），但不是有界稳态。② 计数不会随连接重建清零：若新连接复用了同一 `remoteAddress`（`SocketAddress` 含端口，客户端重连通常换端口；但同机短连接、端口复用场景可能命中），第一轮 tick 就会读到 `count > unavailableChecked`，新连接被立刻判不可用并关闭。
- **建议**：所有判"不可用/关闭"的分支在 `buffer.close()` 之前补 `checkerId.remove(buffer.remoteAddress)`；更稳的做法是把计数挂在 `SocketBuffer` 上（连接级生命周期，天然随连接释放），`checkerId` 只保留"等待 ACK 的 id → 地址"这类短生命周期映射，并给它加容量上限/TTL。

### [一般][存量] `Server.close()` 不关闭 `executors` 线程池：每个 Server 实例泄漏 200 个常驻线程

- **位置**：`f_net/src/server/server.cj:38,46`（`Executors<Message>(executors: executors, maxQueueSize: 1)`，默认 200）、`:209-211`（`close()` → `doClose`）、`:191-205`（`doClose` 只处理 server/checkTimer/buffers）
- **来源**：存量（`be8139810`（2026-09-27））
- **判据**：review-checklist §11（资源释放不对称）、§12.1（有界性 / 线程池堆积）、§14.1（接线缺失：有 `shutdown` 却没人调用）
- **证据**：静态确定 —— `Server` 只在构造器里创建 `Executors`，全仓搜 `executors.shutdown` / `Executors::shutdown` 在 `f_net` 内零命中；`Executors` 的构造器（`f_concurrent/src/Executor.cj:24-27`）会为每个 `Executor` 起一个 `spawn` 线程（`:56-62`），因此 `Server` 一构造就有 `executors`（默认 200）个线程在 `q.remove()` 上阻塞。
- **描述**：`close()` 只关监听 socket、停巡检、清连接队列，工作线程池整体遗留：进程内每 new 一个 `Server` 就多 200 个永不退出的线程。生产上 `Server` 通常与进程同生共死，影响被掩盖；但测试套件里 `f_net_tcp_test.cj` 的 4 个用例 + `socket_params_test.cj` 的 1 个用例各建一个 `Server`，单次 `cjpm test` 就积累约 1000 个阻塞线程，也是"测试越跑越慢/偶发超时"的可疑来源。
- **建议**：`doClose` 里补 `executors.shutdown()`；同时需要 `f_concurrent` 配合（见「范围外提示」：现在的 `shutdown()` 无法唤醒阻塞在 `q.remove()` 的 worker），否则补了也不回收。短期至少在 `Server.close()` 里调用，让新任务不再入队。

### [一般][存量] 巡检 `spawn` 把 buffer 回填队列，与 `doClose` 的 3 轮 drain 竞争：关闭后仍可能留下未关闭的连接

- **位置**：`f_net/src/server/server.cj:56-97`（`tryRemove` 后 `spawn`，`:84-94` 回填/关闭）、`:194-204`（`for (i in 0..3) { while (buffers.size > 0) … }`）
- **来源**：存量（`be8139810`（2026-09-27）；`3 轮 drain` 的注释见 `f_net/doc/审查报告.md:154`（P4#4））
- **判据**：review-checklist §11（并发正确性 / 检查-然后-写入）、§12.1（有界性）
- **证据**：静态确定（窗口存在）+ 需实测（命中频率）。`doClose` 先 `server.close()` + `checkTimer.cancel()`（`:192-193`），再最多 drain 3 次；但 `Timer.cancel()` 按官方文档"不会阻塞当前线程"（`sync_package_classes.md:296`），已在执行的 tick 回调会继续跑完，其 `spawn` 出来的任务既可能在 drain 之间把 buffer 加回队列，也可能在 3 轮 drain 全部结束后才 `buffers.add(buffer)`（`:85`）。
- **描述**：`close()` 返回后，队列里可能有 1..N 个 `SocketBuffer` 既没被关闭、也没有任何巡检会再处理它们（timer 已取消）——socket 句柄与 writer 线程一起泄漏，直到进程退出。`3 轮 drain` 只是把窗口压小，没有消除它（注释里也承认这是对 race 的缓解）。同一窗口还存在反向问题：巡检任务在 `close()` 之后仍会对已关闭的 buffer 调 `transfer`，抛 `IllegalStateException` 后走 `:91-93` 的 WARN 分支。
- **建议**：给 `Server` 加一个 `closed` 原子标志，`spawn` 任务在 `buffers.add` 前检查它（关闭后直接 `buffer.close()`）；`doClose` 在 drain 后置标志并再 drain 一次，或改成"关闭后由 `close()` 直接持有一份快照并逐个关闭，巡检任务不再回填"。终极方案是把巡检改成不 spawn 的顺序执行（见「优化可行性方案 · CPU」），窗口自然消失。

### [一般][存量] `Client.close()` 在 `closeLock` 内做最长 `2s × 连接数` 的关 socket I/O：关闭期间所有 `transfer` 一起阻塞

- **位置**：`f_net/src/client/client.cj:240-252`（`synchronized(closeLock)` 包住整轮 `buf.close()`）、对照 `:315-321`（`readyConnection` 的 `synchronized(closeLock)`）与 `f_net/src/SocketBuffer.cj:96-103`、`:110-123`（`awaitFrameWrite` 最多等 `FRAME_CLOSE_WAIT = 2s`）
- **来源**：存量（`f5fd92704c`（2026-11-19）与 `be8139810`（2026-09-27））
- **判据**：review-checklist §12.2（锁内 I/O / 临界区过大）、§6.2（大粒度锁）、§11（资源释放时序）
- **证据**：静态确定 —— `close()` 的临界区包含：`closed.store(1)`、`checkTimer.cancel()`（不阻塞）、以及 `for (buf in buffers) { buf.close(err) }`。`ClientConnection.close`（`:71-74`）→ `pending.close()`（持 `pending.mutex` 唤醒所有 future）→ `buffer.close()`（`SocketBuffer.cj:96-103`）→ `awaitFrameWrite()` 最多自旋等待 2s + `socket.close()`。`transfer()` 的第一步 `readyConnection(index)`（`:315-319`）需要同一把 `closeLock`。
- **描述**：临界区里既有"唤醒等待者的回调"（`future.fail` 会 notify 所有在等 `get()` 的业务线程），又有真正的 socket I/O 与最长 2s 的等待。`socketCount` 默认 1、最大可配到几十：`close()` 期间所有业务线程的 `transfer`/`readyConnection` 都在 `closeLock` 上排队，尾延迟等于"最后一个连接写帧退场的时间"。这是典型的"用一把锁保护多个无关资源"，且锁内放的是阻塞操作。
- **建议**：`close()` 只做一次原子状态切换（`closed.compareAndSwap(0,1)`），把 `buffers` 快照取出后**在锁外**逐个 `buf.close()`；`readyConnection`/`reconnect` 只用 `closeLock` 保护"读 `buffers[i]` + 判定 + 替换"这一小段。这样 `closeLock` 的持有时长降到 O(1)。

### [一般][存量] `SocketBuffer.isClosed()` 带副作用且不可并发调用：每轮轮询都可能在别的线程里关 socket、重复等 2s

- **位置**：`f_net/src/SocketBuffer.cj:138-150`；调用点 `f_net/src/client/client.cj:90`、`:120`、`:130`、`:182`、`:197`、`:212`、`f_net/src/server/server.cj:61`、`:88`、`:140`
- **来源**：存量（`06f3276bf5`（2026-09-27）引入该形态，`e3e12ccceb`（2026-10-04）把 `awaitFrameWrite` 加进 `isClosed()`）
- **判据**：review-checklist §11（语义与命名不符 / 契约与实现不符）、§12.1（共享状态、检查-然后-写入）、§12.2（锁内阻塞）
- **证据**：静态确定（副作用与并发路径）+ 待确认（`TcpSocket.close()` 是否幂等，未见文档明确说明）。`Resource.isClosed()`（`core_package_interfaces.md:1343-1350`）的语义是查询状态，仓内也按此使用（`f_base/src/Peekable.cj:48` 据它判断是否需要关闭）；本实现却在 `isStopped() && !socket.isClosed()` 时执行 `awaitFrameWrite()`（最长 2s）+ `socket.close()`。`readResponses` 的 `while (!buffer.isClosed())`（`client.cj:90`）让读线程每解完一帧就调用一次带副作用的"查询"；同时巡检线程、`transfer` 路径、业务线程也都在调。
- **描述**：① 命名与契约不符：任何按 `Resource` 语义写"if (!isClosed()) close()"的调用方（包括 `f_base` 的 `resource()` 辅助）会得到"查询时顺手关掉"的意外行为；② 检查-然后-写入无原子性：两个线程可以同时通过 `!socket.isClosed()` 判定，各自执行一次 `awaitFrameWrite()`（各等最多 2s）与 `socket.close()`——若 `TcpSocket.close()` 对重复调用抛 `SocketException`，这个异常会从 `isClosed()` 里冒出，把"查询"变成崩溃点；③ 读循环每帧都被这个函数"顺带"接管关闭，关闭时序变得难以推理（谁关的、什么时候关的只能看日志）。
- **建议**：把"懒关闭"从 `isClosed()` 拆成独立的 `ensureClosed()`（或直接用 `close()`），`isClosed()` 只返回 `stop.stopped.load() == 1 || socket.isClosed()`；`socket.close()` 收进 `close()` 的 `closeLock` 保护范围，重复调用用原子标志短路。

### [一般][存量] `SocketBuffer.transfer` 返回成功后帧可能永不写出：`close()` 期间队列残留帧被静默丢弃

- **位置**：`f_net/src/SocketBuffer.cj:47-63`（writer 循环 `while (stop.stopped.load() == 0)`）、`:75-85`（`transfer` 入队成功即 `return`）、`:96-103`（`close()` 先置 stop）
- **来源**：存量（`be8139810`（2026-09-27））
- **判据**：review-checklist §11（错误处理缺失 / 数据丢失）、§12.1（异步语义：返回成功 ≠ 已发送）
- **证据**：静态确定 —— `close()` 的第一步就是 `stop.stopped.store(1)`（`:97`），writer 循环在下次判断时退出，队列里剩余闭包**不会被取出**；`transfer()` 的循环条件是 `while (!isStopped())`，检查与 `queue.add` 之间没有互斥：`stop` 在检查后置位、`add` 仍然成功时，`transfer` 返回（不抛异常），而该帧永远不会被写出。
- **描述**：`transfer` 的契约是"编码并写到 socket"（README `:42-43`），实际语义是"放进队列"。关闭窗口内的调用方拿到"成功"却丢了一帧：客户端表现为请求永远等不到响应（`MessageFuture` 被 `pending.close` 以异常唤醒，看起来像"连接断开导致失败"，但帧其实从未发出）；服务端的 `Message.ack(...)` 回包也可能这样丢掉，对端只能靠心跳失败重连。注意这不是"关闭时丢弃在途数据"的常规语义——常规语义下调用方应当能区分"已发送"与"未发送"，这里做不到。
- **建议**：给 `SocketBuffer` 一个"已停止且队列已排空"的显式状态机：`transfer` 与 `close` 用同一把锁/原子标志仲裁（`close` 置 `stopping` 后拒绝新帧并抛 `IllegalStateException`，已入队的帧在关闭前尽量写完）；至少让 `transfer` 在 `stop` 置位后对已入队的帧返回失败而不是成功。

### [一般][存量] `ListeningClient` 每收到一帧就 `spawn`：无界线程、乱序回调、无背压

- **位置**：`f_net/src/client/ListeningClient.cj:31-35`（`while (…) { spawn{executor(m)} }`）
- **来源**：存量（`git blame -L 31,35 -- f_net/src/client/ListeningClient.cj` → `45b9615016`（2026-07-12））
- **判据**：review-checklist §5（全量任务提交 / 无界增长）、§12.1（异步语义、有界性）、§11（契约：README 说"把响应持续交给 executor"）
- **证据**：静态确定（无任何上限）+ 需实测（触发所需的消息速率）。`spawn` 每帧创建一个仓颉线程（`spawn` 表达式返回 `Future<T>`，文档 `core_package_classes.md:585`："Future 实例代表一个仓颉线程任务"），循环体内没有等待、没有队列、没有在飞计数；`executor` 的实现方（如 `fleet/src/client/ListeningFleet.cj:22`）拿到的是**并发**调用。
- **描述**：① 线程数 = 解码速度 × `executor` 延迟：订阅一个高频推送流（fleet 的 watch、fmq 的 consume 都可能）时，只要 `executor` 稍微慢一点，线程就会以"每秒消息数"的速度创建，直接顶到线程/内存上限；② 语义上"响应流"通常要求**保序**，这里每帧一个线程，`executor` 的调用顺序与到达顺序无关，多帧可能同时在 `executor` 里跑——调用方若有任何非线程安全状态（累加、缓冲、写文件）就会出错；③ 没有任何背压信号：解码线程不为消费速度负责，内存里堆积的是"待执行任务"。
- **建议**：改成单消费者顺序分发（本线程直接 `executor(m)`，或一个专用消费线程 + 有界队列 + 丢弃/阻塞策略）；需要并发时提供显式的固定并发度（如 `spawn` N 个 worker 从队列取），并在接口注释/README 里写明"保序 + 有界"的语义。

### [一般][存量] 订阅连接是 `clone()` 旁路：不套用 `SocketParams`，也不被 `Client` 跟踪关闭

- **位置**：`f_net/src/client/client.cj:347-349`（`ListeningClient<T>(readyConnection(0).buffer.clone(), …)`）、`f_net/src/SocketBuffer.cj:65-69`（`clone()`）
- **来源**：存量（`SocketBuffer.clone` 由 `be8139810`（2026-09-27）引入；`client.cj:348` 由 `f5fd92704c`（2026-11-19）改为 clone 语义）
- **判据**：review-checklist §11（资源不对称 / 契约与实现不符）、§13（README 说 `SocketBuffer` 由 Client 内部创建并管理）
- **证据**：静态确定 —— `clone()` 只做三件事：`TcpSocket(socket.remoteAddress)`（`:66`）、`connect()`（`:67`）、`SocketBuffer(queueSize, socket)`（`:68`）。**没有** `params.populate(socket)`，所以 `readTimeout` / `writeTimeout`（若修好）/ `keepAlive` / `noDelay` / `receiveBufferSize` / `bindToDevice` 全部退回系统默认；也**没有**把新 buffer 登记进 `Client.buffers`，因此 `Client.close()`（`:240-252`）不会关闭它、`Client.isClosed()` 也不反映它。
- **描述**：同一个 Client 的两类连接行为不一致：主连接有 `noDelay(true)`（`f_net_tcp_test.cj:98`、`socket_params_test.cj:53` 都这么配），订阅连接却是默认 Nagle 开启；主连接有 `readTimeout` 保护，订阅连接没有（读线程可永久阻塞在 `decode`）。生命周期上，`ListeningClient.close()` 是唯一能关掉它的入口——调用方忘记 close（或 `ListeningFleet` 之外的直接使用者）时，socket + 两个线程永久存活，且 `Client` 已关闭也不会带走它们。
- **建议**：`clone()` 接受 `SocketParams` 并把 `populate` 复用上；`Client` 用一个弱/强引用集合登记派生连接，`Client.close()` 一并关闭；或在 README 里明确"订阅连接独立于 Client 生命周期，必须显式 close"。

### [一般][存量] 配置 `readTimeout` 后空闲连接被当成解码错误拆链（client 与 server 同源）

- **位置**：`f_net/src/SocketParams.cj:63`（`socket.readTimeout = readTimeout_`）；受影响路径 `f_net/src/client/client.cj:110-134`（`catch (e: Exception)` → `log.error` + `close()` + `break`）与 `f_net/src/server/server.cj:152-159`（`log.warn('error occurred on decoding', e)` + `close()`）
- **来源**：存量（`be8139810`（2026-09-27））
- **判据**：review-checklist §11（边界/超时语义、错误处理）、§13（配置项语义未定义）
- **证据**：静态确定（异常类型有文档）—— `TcpSocket` 读超时抛 `SocketTimeoutException`（`net_package_classes.md:4655`），它是 `SocketException <: Exception`，必然落进上面两个 `catch (e: Exception)`；两处都把"超时"与"字节流错位"合并处理：client 打 `log.error('Client reader error …')` 后关连接、server 打 `WARN error occurred on decoding` 后关连接。
- **描述**：`readTimeout` 是 builder 的公开设置（README `:80`：`readTimeout`），语义看上去是"单次读取超时"。但 `Message.decode` 的读是**长期阻塞**的（等下一帧），于是"连接空闲超过 readTimeout"与"读失败"不可区分：空闲连接被误判为解码错误拆掉，日志还会写成 "error occurred on decoding"，把排查引向错误方向；客户端则表现为"每隔 readTimeout 重建一次连接"。本模块已经有心跳（`checkDuration` + `checker`）负责存活判定，两套机制语义重叠且互相干扰。
- **建议**：二选一并写进 README：① 把 `readTimeout` 定位成"空闲超时"，单独 `catch (e: SocketTimeoutException)` 走"心跳判活"分支（不记 error、不立即拆链，交由 `checker` 决定），并在服务的读循环里重置计时；② 或者干脆不把 `readTimeout` 应用于长连接（`populate` 里跳过），只保留心跳。

### [一般][存量] `Server.start()` 的 `params.populate(socket)` 无异常隔离：单条连接配置异常直接终止整个 accept 循环

- **位置**：`f_net/src/server/server.cj:122-137`（重点 `:136` `params.populate(socket)`；`:124-135` 只对 `accept()` 做了 try）
- **来源**：存量（`be8139810`（2026-09-27））
- **判据**：review-checklist §11（错误处理缺失 / 失败路径）、§10（异常边界）
- **证据**：静态确定 —— `start()` 的 `while (true)` 里，只有 `server.accept()` 被 `try` 包住；`params.populate(socket)`（内部会调 `socket.setSocketOption*`，非法参数会抛 `SocketException`/`IllegalArgumentException`）与 `SocketBuffer(...)` 都在 `try` 之外。任一条连接上抛异常，异常穿出 `start()`，落进调用方的 `spawn`（README `:135` 明确要求"调用方自己 spawn"），accept 循环终止且**没有任何日志**——服务从"还在跑"变成"不再接受新连接"，`isClosed()` 仍然返回 false。
- **描述**：错误被放大到"整台服务端失去接入能力"。触发条件不必是恶意：`socketLinger`/`socketReadTimeout` 配了非法值、某个平台的 `setSocketOption` 不支持某选项、accept 到的 socket 在建连瞬间被对端 RST（`remoteAddress`/setsockopt 可能抛 `SocketException`）都会走到这里。
- **建议**：把 `populate` + `SocketBuffer` 构造包进 per-connection 的 `try`，失败时 `log.warn`（带 `remoteAddress`）+ `socket.close()` + `continue`；`accept()` 之外的异常都不应该终止 `start()`。测试里补一条"populate 抛异常后 accept 循环仍存活"的用例。

### [一般][存量] `MultiClientBuilder.add` 在未设置负载算法时静默丢弃节点：连接已建立但永不被选中、也不被关闭

- **位置**：`f_net/src/client/MultiClient.cj:176-177`（`this.clients.add(client)` 与 `balance?.add(weight){_ => client}`）；`balance` 初值见 `:92`，设置入口 `:103-116`
- **来源**：存量（`git blame -L 176,177 -- f_net/src/client/MultiClient.cj` → `f8c91ac435`（2026-08-15）与 `c81067efa4`（2026-08-14））
- **判据**：review-checklist §11（静默失效 / 契约与实现不符）、§3（`?.` 把缺失折叠成 no-op）、§1（注册了但永不触发）
- **证据**：静态确定 —— `balance` 是 `None<LoadBalance<…>>`（`:92`），`?.add` 在 `None` 时什么都不做；但 `clients.add(client)` 已经在 `:176` 无条件执行，`Client` 的构造已连上 socket 并起了 reader + writer 线程。`build()`（`:209-211`）随后 `balance.getOrThrow()`，抛的是 `NoSuchElementException`。
- **描述**：`add` 的文档注释写的是"先调用 roundRobin / random 再 add"（`:118`、`:123`、`:129`），但没有任何强制。三种误用都静默：① 先 `add` 后 `roundRobin`——先前节点的连接永不参与负载、也永不关闭（只有 `MultiClient.close()` 会关）；② 完全忘记设算法——`build()` 抛 `NoSuchElementException`，而被 `add` 建好的连接全部泄漏；③ `add` 的 `Iterable` 重载里混入一个坏地址（`IPSocketAddress.tryParse(...).getOrThrow()`，`:121`）会抛异常中断整个批量添加，此前已加入的节点保留、后续节点丢失，调用方无从知道加了几个。
- **建议**：`add` 首行校验 `balance` 非空，为空时抛 `ClientException("load balance algorithm not set, call roundRobin() or random() first")`；`build()` 把 `getOrThrow()` 换成带类型与文案的 `ClientException`；批量重载里逐条 `try` + 汇总失败项。

### [一般][存量] 三套 builder 各自复制同一组 socket 参数转发，`MultiClientBuilder` 与 `ClientBuilder` 语义漂移（`socketOption*` 只保留最后一次）

- **位置**：`f_net/src/client/MultiClient.cj:27-91`（13 组字段 + setter）、`:134-162`（逐个转发）；对照 `f_net/src/client/client.cj:373-426`（`params` 委托）与 `f_net/src/SocketParams.cj:30-32`（三个 `ArrayList` 累积）
- **来源**：存量（`c81067efa4`（2026-08-14）引入 `MultiClientBuilder`，`be8139810`（2026-09-27）重写 `ClientBuilder`）
- **判据**：review-checklist §2（字面量复制 / 换一层复制的重复逻辑，且差异导致行为漂移）
- **证据**：静态确定 —— `SocketParams` 用 `ArrayList<(Int32, Int32, CPointer<Unit>, UIntNative)>` 累积（`SocketParams.cj:30`），所以 `ClientBuilder.socketOption(a)` 再 `.socketOption(b)` 会把两个都写进 socket；`MultiClientBuilder` 对应字段是 `private var socketOptions_ = None<(Int32, Int32, CPointer<Unit>, UIntNative)>`（`MultiClient.cj:72`），第二次调用直接覆盖第一次，只有最后一个生效。`socketOptionBool_` / `socketOptionIntNative_`（`:77`、`:82`）同样。
- **描述**：同一配置面在三个 builder 里各写一遍（`ClientBuilder` 委托、`MultiClientBuilder` 自己存再转发、`ServerBuilder` 一半给监听 socket 一半给 `SocketParams`），diff 只在"存哪儿"。除上面这条漂移外还有两处不一致：`MultiClientBuilder` 没有 `socketCount`/`queueSize` 的 setter（只能走 `builder(...)` 参数）；`ServerBuilder` 完全没有 `keepAlive` / `socketKeepalive` 入口（见文档一致性那条）。使用者把同一段配置从 `Client` 迁到 `MultiClient` 时，`socketOption` 的行为会静默改变。
- **建议**：`MultiClientBuilder` 内部直接持有一个 `SocketParams`（与 `ClientBuilder` 同构），`add` 里传 `params.copy()`；若确实需要"每次 add 前可改配置"，就把差异显式写进文档与测试用例（`socketOption` 调用两次的期望语义）。`ServerBuilder` 的两层语义（监听 socket / accept 后连接）保留，但把 `SocketParams` 相关 setter 与 `ClientBuilder` 保持一一对应。

### [一般][存量] README 写了不存在的 `socketKeepalive`，且"构建失败抛 `ClientException`"与实现不符

- **位置**：`f_net/README.md:154`、`f_net/README_en.md:155-156`（`socketKeepalive`）；`f_net/README.md:90`（`ClientException`）；对照 `f_net/src/server/server.cj:263-294`（`ServerBuilder` 的全部 `socket*` setter）、`f_net/src/client/client.cj:431-436`（`newSocket`）
- **来源**：存量（README 与源码同批提交；`server.cj` 的 setter 集合自 `be8139810`（2026-09-27）未变）
- **判据**：review-checklist §13（文档写了源码里不存在的 API / 承诺与实现相反）、§14.1（接线缺失：能力根本没有入口）
- **证据**：静态确定 —— `ServerBuilder` 的 `socket*` 前缀方法只有 `socketBindToDevice` / `socketLinger` / `socketNoDelay` / `socketQuickAcknowledge` / `socketReadTimeout` / `socketReceiveBufferSize` / `socketSendBufferSize` / `socketWriteTimeout`（`server.cj:263-294`），全仓搜 `socketKeepalive` 只命中两版 README（`f_net/src` 内零命中，源码里只有类型名 `SocketKeepAliveConfig` 与方法名 `keepAlive`）；`SocketParams.keepAlive` 存在（`SocketParams.cj:86-89`、`populate` 会应用），但 `ServerBuilder` 没有任何 setter 能碰到它 → **服务端无法为 accept 后的连接开启 TCP keepalive**。另一条：README `:90` 写"构建失败会抛出 `ClientException`"，而 `ClientBuilder.build()` → `newSocket()`（`client.cj:431-436`）对 `TcpSocket(...)` / `s.connect()` 没有任何 `catch`，连接失败抛的是 `SocketException`（`MultiClientBuilder.add` 才会包成 `ClientException`，`MultiClient.cj:163-175`）。
- **描述**：两处都会让使用者写出错误的代码：① 按 README 调 `builder.socketKeepalive(true)` 编译不过（这正是"文档承诺 vs 能力缺失"的双证）；② `try { Client.builder(...).build() } catch (e: ClientException) { ... }` 抓不到连接失败，异常直接穿到上层——而 `ClientException` 恰恰是为这一场景设计的（README 同一句就在说构建失败）。
- **建议**：`ServerBuilder` 补 `socketKeepalive(config: ?SocketKeepAliveConfig)`（一行 `params.keepAlive(config)`）并加用例；`ClientBuilder.build()`/`newSocket()` 把 `Exception` 包成 `ClientException`（或改 README 为"抛 `SocketException`"）。中英两版一起改。

### [一般][存量] README 覆盖缺口：`MultiClientBuilder` 的 13 个设置方法与其余 5 个 `add` 重载未文档化，`README_en.md` 缺「在途请求与断连」整节

- **位置**：`f_net/README.md:92-108`（MultiClient 段）、`:166-171`（"其他公开 API"）、`:173-175`（在途请求段，仅中文）；对照 `f_net/src/client/MultiClient.cj:28-91`（13 个 setter）、`:120-207`（6 个 `add` 重载）；`f_net/README_en.md:167-172`（英文版末尾）
- **来源**：存量（`git log -3 -- f_net/README.md` → 中文版最后改动 `5559ec425`（2026-11-19）新增「在途请求与断连」；`git log -3 -- f_net/README_en.md` → 英文版最后改动 `8fc74320c`（2026-10-08），未跟随该段）
- **判据**：review-checklist §14.2（公开 API 未文档化 / 中英不同步的"缺失"）、§13（README_en 缺整节）
- **证据**：静态确定 —— 以 `src/` 声明为基准逐项比对：`MultiClientBuilder` 的 `bindToDevice` / `keepAlive` / `linger` / `noDelay` / `quickAcknowledge` / `readTimeout` / `receiveBufferSize` / `sendBufferSize` / `writeTimeout` / `socketOption` / `socketOptionBool` / `socketOptionIntNative` / `pingTimeout` 共 13 个 `public func` 在 README 全文检索不到（`README.md:171` 的"其他公开 API"只列了 `MultiClient.iterator` 与 `ServerBuilder` 的 8 个方法）；`add` 的 6 个重载里只有 `add(weight, address: String)`（`MultiClient.cj:120-122`）进了 README，`add(weight, host, port)`（`:126-128`）、`add(weight, IPSocketAddress)`（`:132-134`）与三个 `Iterable` 重载（`:184-207`）都没有列，只有一句"也可传 Iterable"。`README_en.md` 到 `:172` 结束，`README.md:173-175` 的「在途请求与断连」整节（说明了"超时返回 None、连接失败更早抛异常、不能据此判断对端是否执行"这一关键语义）在英文版中完全缺失。
- **描述**：`MultiClientBuilder` 是 `f_rpc` 之外的唯一多节点入口，使用者最常问的"每条连接要不要设 NoDelay / 读超时怎么配"在文档里查不到，只能读源码；中英两版对"在途请求"的语义说明不一致，会让英文读者误以为超时与失败不可区分。
- **建议**：README 里给 `MultiClientBuilder` 补一行"socket 设置项与 `ClientBuilder` 一致（列出方法名）"，或直接把 `ClientBuilder` 的设置段落复用；`add` 的 6 个重载列全；把 `:173-175` 翻译进 `README_en.md`。

### [一般][存量] `pending_requests_test.cj` 缺 Apache 2.0 版权头

- **位置**：`f_net/src/client/pending_requests_test.cj:1`（文件首行即 `package fountain::f_net.client`）
- **来源**：存量（`git log -1 -- f_net/src/client/pending_requests_test.cj` → `12a64e110`（2026-11-19），提交里就没有头）
- **判据**：`fountain-baseline.md` §3（每个 `.cj` 必须有 Apache 2.0 头且位于 `package` 之前；缺头按"一般"报）
- **证据**：静态确定 —— 同目录其余 4 个 `.cj`（`client.cj`、`ListeningClient.cj`、`MultiClient.cj`、`ClientException.cj`）都有 15 行标准头，本文件 0 行；`f_net/src/test/*.cj` 也都有。
- **描述**：模块内唯一的许可证不一致文件。对下游而言（`fountain` 以 Apache-2.0 分发）这是合规瑕疵：该文件在构建/测试时会被编译进用例产物。
- **建议**：补齐与同目录一致的头（`Copyright (c) 2026 WuJingrun（吴京润）` + 全文），位置在 `package` 之前。

### [轻微][存量] 死代码与未使用 import：两个从未被赋值的字段、一个只写不读的字段、两处无用 import

- **位置**：
  - `f_net/src/client/ListeningClient.cj:21`（`private static let log`，全文件零引用）、`:23` + `:47`（`private var timer: Timer = ZERO_TIMER` 从未被赋值，`close()` 却调 `timer.cancel()`）
  - `f_net/src/server/server.cj:222`（`private let bindAt: UInt16` 只写不读；`build()` 只读 `bufferQueueSize`/`checkDuration`/`checker`/`executors_`/`unavailableChecked_`/`defaultResp`/`rateLimiter`）
  - `f_net/src/imports.cj:19`（`internal import std.io.BufferedInputStream`，包内无任何引用）与 `f_net/src/SocketBuffer.cj:18`（同文件 `BufferedInputStream` 未使用）
  - `f_net/src/client/client.cj:18`、`f_net/src/server/server.cj:19`（`import std.env`，两文件内均无 `env.` 引用）
- **来源**：存量（`git blame`：`ListeningClient.cj:21-23` → `45b9615016`（2026-07-12）；`server.cj:222` → `be8139810`（2026-09-27））
- **判据**：review-checklist §1（无调用者 / 读了不用 / 未使用 import；`ListeningClient.log` 与 `timer` 属 `private`，全仓搜只有声明与那一处调用）
- **证据**：静态确定 —— `grep -n "timer" ListeningClient.cj` 只有 `:23` 声明与 `:47` `cancel()`；`timer` 没有任何赋值点，因此 `cancel()` 永远作用在 `ZERO_TIMER`（`f_base/src/zero_timer.cj:20` 的 `unsafeZeroValue<Timer>()`）上，既不会取消任何任务，也不清楚对零值实例调用成员函数的运行时行为（`f_ticktock/src/Chrono.cj:47` 是同样的写法，属仓库既有模式）→ 这一半记为 `待确认`。
- **描述**：`ListeningClient` 根本没有定时器（巡检定时器只在 `Client` 里），`timer` 是把 `Client` 的定时器模式照搬过来的残留；`bindAt` 是 `ServerBuilder` 构造后不再使用的字段；`std.env` 与 `BufferedInputStream` 无任何引用。这些不影响行为，但会误导读者以为"订阅连接有心跳定时器"、"builder 会用到 bindAt"。
- **建议**：删掉 `ListeningClient.log` / `timer` 与 `timer.cancel()`；`ServerBuilder.bindAt` 删掉（构造器参数已够用）；清理两处 import。删 `timer` 时顺手确认 `ZERO_TIMER.cancel()` 的行为，避免保留一个语义不明的调用。

### [轻微][存量] 测试重复且部分用例零断言：`NetTestSetup_test.cj` 两份、`pingChecker` 两份、`net_test.cj` 两个用例不校验任何东西

- **位置**：`f_net/src/NetTestSetup_test.cj:22` 与 `f_net/src/test/NetTestSetup_test.cj:22`（内容除 `package` 外逐行相同）；`f_net/src/test/f_net_tcp_test.cj:39-41` 与 `f_net/src/test/socket_params_test.cj:35-37`（`pingChecker` 相同）；`f_net/src/net_test.cj:97-116`（`SocketParamsTest` 两个用例）
- **来源**：存量（`4be871f2f`（2026-10-02）同时引入两份 setup 与 `SocketParamsTest`）
- **判据**：review-checklist §2（跨文件字面量复制）、§3（形式上的空实现：用例无断言）
- **证据**：静态确定 —— `builderPatternChaining`（`:99-105`）只做链式调用并赋给 `_`，无 `@Assert`；`copyProducesIndependentClone`（`:108-116`）注释声称"如果 copy 共享内部状态，修改 p1 会影响 p2"，但全程没有读回任何字段、也没有 `@Assert`，`p1`/`p2` 在函数结束时直接丢弃——即使 `copy()` 退化成 `return this` 也会通过。两份 setup 的唯一差异是 `package fountain::f_net` vs `package fountain::f_net.test`，逻辑完全一致。
- **描述**：这三个用例给出"已覆盖 SocketParams"的假信号（`doc/审查报告.md:225-229` 还把 2 个用例计入"10/10 PASSED"）。真正验证 `populate` 的是 `src/test/socket_params_test.cj` 的 `SocketParamsPopulateTest`（走真实连接），它存在说明前者是冗余的。
- **建议**：`copyProducesIndependentClone` 补实质断点——`populate` 到两个 socket（或暴露可读回的状态）后比对；否则删除。`SocketParamsTest` 与 `src/test/socket_params_test.cj` 二者保留其一；两份 `NetTestSetup_test.cj` 合并（把 `testProtocolHostIdSetup` 放到 `src/test/`，或抽成 `f_net` 包的测试辅助）。

### [轻微][存量] `MultiClient.closed` 是普通 `Bool`：`isClosed()` 跨线程可见性未定义

- **位置**：`f_net/src/client/MultiClient.cj:230-233`（`private var closed = false`）、`:234-235`（`close()` 首行 `closed = true`）
- **来源**：存量（`git blame -L 230,233 -- f_net/src/client/MultiClient.cj` → `f8c91ac435`（2026-08-15））
- **判据**：review-checklist §12.1（可见性：用普通字段当跨线程信号）、§11（并发正确性）
- **证据**：静态确定（无同步手段）—— 同模块的 `Client` 用的是 `AtomicInt64`（`client.cj:82,242,255`）、`ListeningClient` 用 `AtomicBool`（`ListeningClient.cj:22,44`），只有 `MultiClient` 是裸 `Bool`；`isClosed()` 只读该字段，`close()` 只写该字段，无锁无原子。
- **描述**：`MultiClient` 实现 `Resource`，`isClosed()` 会被任意线程调用（`f_base` 的 `resource()`、调用方的健康检查），写入发生在 `close()` 里。理论上读线程可能长期看到 `false`。实际影响有限（`close()` 本身幂等、`Client.close()` 也幂等），因此记为轻微；但它是模块内三处同类状态里唯一没有原子化的，属一致性缺口。
- **建议**：改成 `AtomicBool`，与 `ListeningClient` 保持一致。

### [轻微][存量] `doc/审查报告.md` 作为历史快照没有自包含标注，内部行号与结论已全部失效

- **位置**：`f_net/doc/审查报告.md:3-7`（"源文件数：7 … 总代码行：~300"）、`:45`（"10 个测试用例，全部通过"）、`:53-100`、`:236`（"26 项问题已修复，0 项 P0-P3 问题剩余 … 生产就绪"）
- **来源**：存量（文件头部自带 `审查日期：2026-05-03`）
- **判据**：review-checklist §13（文档过期 / 链接与行号失效）；误报边界中"明确标注历史的文档"不判——本文件**自身**没有标注，只有 `README.md:161` 提到它已过时
- **证据**：静态确定 —— 文件说 7 个 `.cj`，实际 15 个；说 `MessageFuture.cj:45-54`、`client.cj:99/117-124`、`server.cj:84-86` 等行号，按当前文件对照全部落在无关代码上（如 `client.cj:99` 现在是 `mid = id`）；`10 个测试用例` 与当前 4 个测试文件、13+ 个用例不符。
- **描述**：单独的读者（不从 README 进来、直接打开 `doc/`）会把"0 项 P0-P3 剩余、生产就绪"当成现状——而本报告里仍有 2 条严重、16 条一般。文档本身不参与构建，风险是误导排查方向。
- **建议**：在文件首行加一行引用块 `> 历史快照（2026-05-03），行号与结论均已失效，现状见 docs/review/2026-11-28/f_net.md`；或直接把文件移入 `doc/archive/`。

### [轻微][存量] 冗余包装与缺失标注：`Server.hasClosed`、`newServerSocket` 无返回类型且用 `Option` 包装、`Client.checkTimer` 可 `let`

- **位置**：`f_net/src/server/server.cj:187-190`（`private static func hasClosed(server: TcpServerSocket) { server.isClosed() }`，注释解释"struct 构造函数不能访问实例函数"，但本类是 `class`）、`:327`（`func newServerSocket(bindAt: UInt16)` 无返回类型标注）、`:328-337`（`sopt` Option + `getOrThrow`）；`f_net/src/client/client.cj:81`（`private var checkTimer: Timer = unsafeZeroValue<Timer>()`，只在构造器里赋值一次）
- **来源**：存量（`be8139810`（2026-09-27）；`client.cj:81` 由 `f5fd92704c`（2026-11-19）保留）
- **判据**：review-checklist §10（可读性 / 可维护性）
- **证据**：静态确定 —— `hasClosed` 只被 `isClosed()`（`:206-208`）调用一次，函数体只有一行转发，`doClose` 用的是静态参数而不是它。`checkTimer` 在 `:177` 赋值后不再变化（`close()` 只 `cancel()` 不重赋值），可以 `let`。
- **描述**：`hasClosed` 的注释描述的是"struct 构造器"的限制，但 `Server` 是 `class`，注释与代码不符，会让后来的维护者以为有语言层面的约束；`newServerSocket` 让读者必须读完函数体才知道返回 `TcpServerSocket`，且 `Option` 包装与 `getOrThrow()` 掩盖了"永远非 None"这一事实（与上面 catch 死代码那条同源）。
- **建议**：`isClosed()` 直接写 `server.isClosed()`，删掉 `hasClosed` 与那条注释；`newServerSocket` 标注 `: TcpServerSocket` 并去掉 `sopt`（见前文建议的 `try` 写法）；`checkTimer` 改 `let`。

## 优化可行性方案

> 不是缺陷，是"还能更好"。两条都**没有改前基线**，因此只作为下一轮补数据的候选，不进 `todo.md` / `tasks.md`。

### [堆内存] 帧写路径的双拷贝可改为流式写出

- **现状**：`SocketBuffer.transfer` 的每个待写帧是一个闭包（`SocketBuffer.cj:76-79`），闭包捕获 `message`，执行时 `message.encode()` 生成**整帧** `Array<Byte>`（头 + 载荷），再 `copy(to: this, closeToOnEnd: false)` 全量写到 socket。`ArrayBlockingQueue(queueSize)` 默认 1024（`ClientBuilder` / `ServerBuilder` 的 `queueSize` / `bufferQueueSize`），最坏情况队列里驻留 1024 个"待写帧"，每个帧在其编码完成后到写出前都持有一份完整字节数组；同时 `encode()` 的临时数组与 `copy` 的目标缓冲在峰值上并存。
- **方案**：队列只存 `Message` 引用（或 `(Message, id)`），编码移到 writer 线程内、写完后立刻释放；进一步可先写帧头再分块写载荷（`Message.encode` 若支持分段，见 `f_protocol`），把"整帧物化"降为"单块缓冲复用"。
- **预期**：写路径峰值内存从 `O(queueSize × frameSize)` 降到 `O(frameSize)`；每帧少一次全量字节拷贝（分配量与 memcpy 各一次）。具体降幅需按平均帧长与队列水位实测。
- **代价**：编码发生在持 `frameLock` 期间，单帧持帧时间变长 → `close()` 的 2s 上限更易触发（与 `awaitFrameWrite` 的策略耦合）；要求 `Message` 在入队后不被调用方修改（当前 `transfer` 语义已隐含这点，需在注释里写明）。
- **验证**：固定帧长（1KB / 64KB）× 并发 100，跑 10 分钟，对比 `getAllocatedHeapSize()` 差分、RSS 峰值与 `cjprof heap` 的分配热点；同时记录 `FRAME_CLOSE_WAIT` 触发次数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 心跳巡检的"每连接一个 `spawn`"可改为顺序/批量执行

- **现状**：`Server` 的 tick 回调（`server.cj:56-97`）对队列里每个连接 `spawn` 一个任务，任务里做 `checkerId.entryView`（`:62-70`）与 `buffer.transfer(m)`（`:74`，只是入队）；连接数 N、周期 T 时，线程创建速率约 `N/T` 次/秒，每次还伴随闭包与 `PingCounter` 访问。`Client` 侧相反，是同一线程顺序遍历（`client.cj:178-225`），两侧实现不一致。
- **方案**：tick 内顺序执行（`transfer` 不阻塞网络，只入队，顺序执行不会拉长单次 tick 太多），或用一个固定大小（如 4）的本地池 + 有界队列；`checker()` 的结果每 tick 只构造一次并复用。
- **预期**：消除每 tick N 次线程创建与 N 次 `spawn` 分配；tick 分配量与线程调度开销下降。幅度取决于 N，需实测。
- **代价**：顺序执行时 tick 时长 ≈ N × 单次入队耗时，N 很大（万级）时需要按批分片；顺序执行下必须逐连接 `try`，否则一个异常会中断整轮巡检（当前 `spawn` 天然隔离）。
- **验证**：`cjprof record` 覆盖 1k / 10k 连接、`checkDuration = 1s`、跑 10 分钟，比较巡检线程的自耗时占比与进程线程数曲线；`cjpm bench -O2` 对比 tick 耗时中位数与 P99。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 没有性能测试数据支撑，**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单连接吞吐上限 = 1 个在飞请求：读线程 `executors.call(...).get{}` 同步等待，同一连接的第二个请求必须等第一个回包 | `f_net/src/server/server.cj:169` | 单连接 QPS、排队时延分布 | 单连接 × 固定 1KB 载荷压测，记录端到端 P50/P99 与 `ExecutorFuture` 等待时长；对比 `socketCount > 1` 的线性度 |
| 2 | `checkerId.entryView` + 每连接 `spawn` 在万级连接下占 tick 自耗时的主要部分 | `f_net/src/server/server.cj:57-96` | 自耗时占比、线程创建速率 | `cjprof record` 跑 1k/10k 连接、`checkDuration=1s` 的稳态；同时采样 `/proc/<pid>/status` 的 Threads |
| 3 | 写路径 `encode()` + `copy()` 的双份字节数组是 GC 压力的主因 | `f_net/src/SocketBuffer.cj:76-79`、`f_net/src/client/client.cj:338` | 每帧分配量、GC 停顿 | `cjprof heap` + `getAllocatedHeapSize()` 差分，1KB/64KB 帧各跑 10 分钟 |
| 4 | 线程数随连接线性增长（每连接 2 个 + 默认 200 个执行器线程），是 RSS 的主要构成 | `f_net/src/server/server.cj:139`、`f_net/src/SocketBuffer.cj:47`、`f_net/src/server/server.cj:46` | 连接数—线程数—RSS 曲线 | 从 100 递增到 10k 连接，逐档记录 RSS 与 Threads，观察拐点 |
| 5 | `PendingRequests` 的单把 `Mutex` + 每请求一个 `MessageFuture` 条件变量，在高 QPS 下成为客户端瓶颈 | `f_net/src/client/client.cj:33-64`、`f_net/src/MessageFuture.cj:50-73` | 锁等待占比、唤醒次数 | 16/64 并发线程跑固定 RTT 场景，采样等待线程状态 + `cjprof` 的锁竞争视图（CPU profile 看不到这部分） |

## 范围外提示

- `f_concurrent/src/Executor.cj:24-27`：`Executors` 的 `maxQueueSize` 参数被忽略（队列容量取 `executors`），`Server` 传的 `maxQueueSize: 1` 无效；队列满时 `tryAdd` 失败 → future 以 `None` 完成 → `Server` 走 `defaultResp` 静默不回包（`server.cj:169-172`）。
- `f_concurrent/src/Executor.cj:101-103`：`Executor.shutdown()` 只置 `running = false`，阻塞在 `q.remove()`（`:59`）的 worker 不会被唤醒——即使 `Server.close()` 补上 `shutdown()` 也回收不了线程（见「一般」第 5 条）。
- `f_protocol` 的 `Message.decode` / `Message.encode` 不在本轮范围：帧长上限、按头部长度预分配等问题需在 `f_protocol` 报告中评估。

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_net.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_net/README.md` | .md | ✅ | 175 行全读；与实现逐项比对：`socketKeepalive` 不存在、"构建失败抛 ClientException"不符（§13 第 16 条）、`MultiClientBuilder` 13 个 setter 未覆盖（§14 第 17 条）、`:173-175` 英文版缺失 |
| 2 | `f_net/README_en.md` | .md | ✅ | 172 行全读；与中文版对照：`socketKeepalive` 同样错误、末尾缺「在途请求与断连」整节，其余章节一一对应 |
| 3 | `f_net/doc/审查报告.md` | .md | ✅ | 241 行全读；2026-05-03 历史快照，7 个文件 / 10 个用例 / 行号均与现状不符，自身无历史标注（§13 第 22 条） |
| 4 | `f_net/src/MessageFuture.cj` | .cj | ✅ | 74 行全读；`get`/`tryGet`/`tryGet(timeout)` 的 `while` + deadline 写法正确，`set`/`fail` 互斥正确，无死代码；无独立取消入口（失败经 `fail()` 注入），等待方靠 `PendingRequests.close` 唤醒 |
| 5 | `f_net/src/NetTestSetup_test.cj` | .cj | ✅ | 22 行全读；与 `src/test/` 同名文件逐行相同（仅 package 不同），§2 第 20 条 |
| 6 | `f_net/src/SocketBuffer.cj` | .cj | ✅ | 156 行全读；`isClosed()` 副作用（第 8 条）、`transfer` 丢帧（第 9 条）、`clone()` 不套 params（第 11 条）、未用 import（第 19 条） |
| 7 | `f_net/src/SocketParams.cj` | .cj | ✅ | 130 行全读；`writeTimeout_` 只写不读（第 1 条，严重）、`readTimeout` 直接落到 socket（第 12 条）、其余字段在 `populate` 均有对应赋值 |
| 8 | `f_net/src/client/ClientException.cj` | .cj | ✅ | 32 行全读；4 个构造器转发 `BaseException`，公开可继承类型，无问题 |
| 9 | `f_net/src/client/ListeningClient.cj` | .cj | ✅ | 51 行全读；每帧 `spawn`（第 10 条）、`log`/`timer` 死代码（第 19 条）、`close()` 幂等实现正确 |
| 10 | `f_net/src/client/MultiClient.cj` | .cj | ✅ | 252 行全读；`add` 静默丢弃（第 14 条）、13 个 setter 复制与漂移（第 15 条）、`closed` 非原子（第 21 条） |
| 11 | `f_net/src/client/client.cj` | .cj | ✅ | 437 行全读；`buffers` 竞态（第 2 条，严重）、`close()` 锁内 I/O（第 7 条）、`readTimeout` 拆链（第 12 条）、`clone` 旁路（第 11 条）、未用 import（第 19 条） |
| 12 | `f_net/src/client/pending_requests_test.cj` | .cj | ✅ | 30 行全读；用例本身有效（断连只影响本连接的在途请求），但缺版权头（第 18 条） |
| 13 | `f_net/src/imports.cj` | .cj | ✅ | 19 行全读；`ArrayBlockingQueue` / `TcpSocket` / `SocketKeepAliveConfig` / `SocketAddress` 均被使用，`BufferedInputStream` 未使用（第 19 条） |
| 14 | `f_net/src/net_test.cj` | .cj | ✅ | 117 行全读；`MessageFutureTest` 8 个用例有效；`SocketParamsTest` 2 个用例零断言（第 20 条） |
| 15 | `f_net/src/server/server.cj` | .cj | ✅ | 337 行全读；`checkerId` 泄漏（第 4 条）、`executors` 不关（第 5 条）、巡检回填竞态（第 6 条）、`populate` 无隔离（第 13 条）、`hasClosed`/`newServerSocket`（第 23 条）、`socketKeepalive` 缺失（第 16 条） |
| 16 | `f_net/src/test/NetTestSetup_test.cj` | .cj | ✅ | 22 行全读；内容正确（设置 `protocol_hostId = 1`），与 `src/` 同名文件重复（第 20 条） |
| 17 | `f_net/src/test/f_net_tcp_test.cj` | .cj | ✅ | 183 行全读；4 个用例覆盖 bind/connect、PING-ACK、executor 往返、close 后 start 返回，断言有效；`pingChecker` 与 `socket_params_test.cj` 重复（第 20 条）；用例创建 `Server` 后未回收执行器线程（第 5 条的放大面） |
| 18 | `f_net/src/test/socket_params_test.cj` | .cj | ✅ | 67 行全读；通过真实 PING 往返验证 `populate` 不抛异常（覆盖有效），但不断言参数真的生效；`pingChecker` 重复（第 20 条） |

合计：`.cj` 15 个 / `.md` 3 个 / 共 18 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 14 | 严重 2（写超时无效、`buffers` 竞态）+ 一般 9（丢帧、`isClosed` 契约、`clone` 旁路、`readTimeout` 语义、`populate` 无隔离、`add` 静默丢弃、巡检回填、锁内 I/O、构建失败契约）+ 轻微 3（死代码、测试空洞、冗余包装）。安全性：无凭据、无敏感报文进日志（日志只带 `id`/`command`/`remoteAddress`），无外部输入拼串；`unavailableChecked`/`queueSize` 等配置值直接进循环条件，未做上限/负数校验（未单独列为条目，风险低） |
| §1 死代码 | 1 | 机械过了一遍：15 个文件的 `private` 符号全仓搜、`internal` 在本包及子包搜、`public` 先判对外可达性。**结论**：`ListeningClient.log`（零引用）、`ListeningClient.timer`（只声明 + `cancel()`）、`ServerBuilder.bindAt`（只写不读）为死；`BufferedInputStream`（`imports.cj:19` 的 `internal import` + `SocketBuffer.cj:18`）、`std.env`（`client.cj:18`、`server.cj:19`）为死 import；`newServerSocket` 的 `catch` 分支恒不执行（第 3 条）。`internal import` 的作用域是整包（`cj_syntax.md:71`），所以 `client.cj:24` 导入的 `AtomicReference`/`CatchupStyle` 由 `ListeningClient.cj:26` 与 `style: Burst` 使用，不计为死。其余：`SocketBuffer.clone`/`MessageFuture.set|fail`/`SocketParams.*` 均被子包或同包使用；`SocketBuffer.localAddress|remoteAddress|read|write|flush|close|isClosed`、`MultiClient.iterator|isClosed|close`、`ServerBuilder.socket*` 等是 `public class` 的对外可达成员，不判（`fdbm`/`fleet`/`fmq`/`f_rpc` 也在消费 `SocketBuffer`）；`ClientConnection`、`PendingRequests`、`StopSignal`、`PingCounter` 均为内部类型且有用 |
| §2 重复逻辑 | 2 | 已把 15 个文件的函数体压成「输入→输出→副作用」两两比对：命中（a）三套 builder 的 socket 参数转发（第 15 条，`MultiClientBuilder` 与 `ClientBuilder` 的 `socketOption*` 语义漂移）；（b）测试辅助重复（第 20 条，两份 `NetTestSetup_test.cj` + 两份 `pingChecker`）。未判：`Client.readResponses` 两个 `catch` 分支的关闭/break 序列形似，但触发条件（EOF vs 解码失败）与日志级别不同；`client.cj` 的 4 个 `builder` 重载只是参数归一化；`SocketParams.populate` 与 `ServerBuilder` 的 server socket 设置是 README 明确的两层语义，不是重复 |
| §3 空实现 | 3 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}` 静默（`try{ buffer.close() }catch(_){}` 属关闭路径的兜底，可接受）。命中：`newServerSocket` 的 `catch` 是"看起来在清理、实际恒不执行"（第 3 条）；`ListeningClient.timer.cancel()` 是对从未创建的定时器的空操作（第 19 条）；`net_test.cj` 两个零断言用例属形式实现（第 20 条） |
| §4 栈溢出 | 0 | 全模块无递归：无自调用、无相互调用、无树/图遍历；`Message.decode` 的递归在 `f_protocol`（范围外）。`while(true)` 的 accept 循环与 `while(!isClosed())` 的连接循环都有退出条件（`close()` → 读异常/`isClosed()` 为真） |
| §5 OOM | 2 | 命中（a）`Server.checkerId` 只增不减，键来自对端地址（第 4 条，增长速率需实测）；（b）`ListeningClient` 每帧 `spawn`，无在飞上限（第 10 条，触发所需速率需实测）。未判：`SocketBuffer` 的队列有界（`queueSize`）、`Server.buffers` 是连接数上界、`PendingRequests` 的 `HashMap` 由"未超时的在飞请求数"约束（超时后 `forget`，`:330-334`） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，热点未成立；5 条猜测全部列入「待验证假设」，不计入统计。`Client` 巡检顺序遍历与 `Server` 巡检 `spawn` 的实现差异作为线索记录在「优化可行性方案 · CPU」 |
| §6.2 大粒度锁 | 1 | 命中：`Client.close()` 在 `closeLock` 内做整轮 socket 关闭与最长 2s 的写帧等待（第 7 条，单次持有时长可界定为 `socketCount × ≤2s`，在关闭路径而非请求主路径）。其余锁：`PendingRequests.mutex` 只包 `HashMap` 操作与 `future.fail`（后者为 O(等待者) 的 notify，属必要）；`SocketBuffer.frameLock` 只保护 `writingFrame` 与条件等待，`beginFrame`/`endFrame` 临界区为常数 |
| §6.3 并发串行 | 0 | 结构性线索有两条（单连接 `get{}` 串行等待 executor、`ListeningClient` 的 `spawn` 反而过度并发），但"串行段占比"需要测量，均未成立；单连接串行已列入「待验证假设」1 |
| §6.4 低效算法 | 0 | 逐函数看过：无嵌套循环、无热点 `contains`/`indexOf`、无 `remove(at: 0)`、无循环字符串拼接；`checkerId` 用 `ConcurrentHashMap` O(1)，`buffers` 遍历 O(N) 且 N=连接数。`SocketBuffer.transfer` 的 50ms 轮询在满队列下是"每秒 20 次重试/等待者"，属有意的有界等待，不是算法问题 |
| §7 降堆内存方案 | 1 | 一条方案（写路径双拷贝流式化），`证据状态：无基线（待验证）`。`Server.checkerId` 的有界化按缺陷记（第 4 条），不在本节重复计数 |
| §8 降 CPU 方案 | 1 | 一条方案（巡检 `spawn` 批量化），`证据状态：无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本模块没有"函数内创建、函数内用完"的大对象：`SocketBuffer.transfer` 的编码数组来自 `f_protocol` 且立刻写入 socket（逃逸到 I/O），`MessageFuture` 持有的 `Message` 逃逸到调用方；`writeFrame` 闭包捕获 `this` 与 `message`，必然逃逸出 `transfer`。收益只能靠峰值内存对照证明，当前无基线 → 不成立 |
| §11 现有代码的 BUG（存量） | 9 | 已核对全部 15 个文件的可执行路径：写超时（第 1 条）、`buffers` 竞态（第 2 条）、`newServerSocket` 清理（第 3 条）、`checkerId` 泄漏（第 4 条）、巡检回填（第 6 条）、`transfer` 丢帧（第 9 条）、`readTimeout` 拆链（第 12 条）、`populate` 无隔离（第 13 条）、`add` 静默丢弃（第 14 条）。另核对无缺陷：`MessageFuture` 三个等待入口的虚假唤醒处理、`PendingRequests.forget` 的 `refEq` 保护、`Client.transfer(timeout)` 的 `finally forget`、`reconnect` 的双重检查与 `socketCreator` 在锁外、`Server.doClose` 的非阻塞 `remove`、`SocketBuffer.awaitFrameWrite` 的上限 |
| §12 并发安全与锁粒度 | 4 | 共享点逐个过：`Client.buffers`/`sockets`（写入在 `closeLock`，读取一处漏锁 → 第 2 条）；`Client.closed`（`AtomicInt64`，正确）；`Client.checkFailures`（只在巡检线程读写，线程封闭，正确）；`PendingRequests`（`Mutex` 保护 `HashMap`，`close` 中先置 `failure` 再逐个 `fail`，无"检查-然后-写入"漏洞）；`MessageFuture`（`ref`/`failure` 全部在 `mutex` 内读写，`condition` 用 `while` 循环 + deadline，正确）；`SocketBuffer`（`stop` 原子、`frameLock` 保护 `writingFrame`，但 `isClosed()` 的检查-然后-关闭无原子性 → 第 8 条）；`Server.checkerId`（并发容器，单键 `entryView` 原子，但计数语义跨连接复用 → 第 4 条）；`MultiClient.closed`（裸 `Bool` → 第 21 条）；`ListeningClient.closed`（`AtomicBool` + CAS，正确）。锁粒度命中 `Client.close()`（第 7 条）。未发现死锁：`closeLock → pending.mutex → future.mutex` 是唯一顺序，反向路径不存在；`Timer.cancel()` 按文档不阻塞（`sync_package_classes.md:296`），`close()` 持 `closeLock` 取消定时器不会与巡检回调互等 |
| §14 功能完备性与 README 覆盖 | 1 | 以 `src/` 公开声明为基准逐项对照：`MessageFuture`、`SocketBuffer`、`Client`/`ClientBuilder`（4 个 builder 重载 + 13 个设置 + 3 个 transfer）、`MultiClient`/`MultiClientBuilder`、`ListeningClient`、`Server`/`ServerBuilder`、`ClientException` 均有对应段落或包表条目。命中：`MultiClientBuilder` 13 个 setter 与其余 5 个 `add` 重载未文档化（第 17 条）；能力缺失命中 `ServerBuilder` 无 keepalive 入口（第 16 条）。承诺但未实现：无（`transfer` 三分支、心跳容忍、限流范围、`defaultResp` 兜底、`close()` 幂等均已接线并有实现） |
| 文件覆盖（§13 等） | 18/18 | 无缺失文件；§13 命中 2 条（README 写了不存在的 API、`README_en.md` 缺整节），均给出文档行号与代码行号 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 16 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

存量缺陷合计 23 条（严重 2 / 一般 16 / 轻微 5），全部为存量；是否纳入修复待用户决定。

## 总评

代码的组织方式是对的：`MessageFuture` 用 `Mutex + Condition` 做单次唤醒，`PendingRequests` 把"在途请求"收敛到连接级（重连不接管旧连接的请求，`client.cj:31` 的注释与实现一致），读写各一条线程、`SocketBuffer` 用队列解耦调用方与 socket 写，巡检用容忍 3 次失败避免重连风暴，服务端把 PING/ACK 从业务路径里摘出来、限流只作用于 executor 路径。这些设计决策都有迹可循，`README.md` 也基本如实描述了它们——比大多数传输层实现更克制。

问题集中在三处，都是"边界与生命周期"而不是"主流程算错了"：

1. **配置层的静默失效**。`writeTimeout` 存了、拷了、转发了，就是没写给 socket（严重 1）；`readTimeout` 写了，却把"空闲"当"解码错误"拆链。两者叠加的实际效果是：用户以为设了写超时就有保护，实际上慢对端会让调用方无界阻塞，而唯一生效的读超时会把空闲连接当故障清掉。修法都很小（`populate` 里加两行 + 分别处理 `SocketTimeoutException`），建议优先做——这是本模块唯一会让"配置正确但行为错误"的坑。

2. **生命周期不对称**。`Client.close()` 不带走订阅连接（`clone()` 旁路），`Server.close()` 不带走执行器线程池，`checkerId` 不随连接消失，巡检 `spawn` 会越过 `doClose` 往队列里回填。四处根因不同但症状一样：关掉之后还有东西活着，而且没有日志提示。这也是最容易被压测/长跑暴露的一类问题。

3. **并发细节**。`Client.buffers` 的一处漏锁（严重 2）在巡检周期上，后果可能是 Client 莫名其妙自关；`SocketBuffer.isClosed()` 把"查询"写成"顺手关闭"，让关闭时序不可推理；`ListeningClient` 每帧 `spawn` 在推送场景下没有上限。前两条改动量都很小（挪进 `closeLock` / 拆出 `ensureClosed`）。

文档侧有两条硬伤：README 承诺了一个不存在的 `ServerBuilder.socketKeepalive`（服务端因此完全没有 keepalive 入口），以及 `MultiClientBuilder` 的 13 个公开设置项与其余 5 个 `add` 重载在 README 里查不到；`README_en.md` 还缺了「在途请求与断连」整节。`doc/审查报告.md` 的"生产就绪、0 项 P0-P3 剩余"已经与现状无关，建议加历史标注，避免误导排查。

性能方面本轮没有给出任何结论：没有 `cjprof` / `cjpm bench` 数据，5 条猜测都留在「待验证假设」（单连接在飞数、巡检开销、写路径双拷贝、线程数随连接增长、`PendingRequests` 锁竞争）。两条优化方案都标了"无基线（待验证）"，不进修复清单。按规模看，模块最可能的真实瓶颈在"每连接两条线程 + 默认 200 个执行器线程"这一结构上，但必须先有线程数与 RSS 的曲线才好下判断。
