# f_pool 模块审查报告

> **模块第 1/2 部分**（本报告只覆盖 `files/f_pool.part1.txt` 列出的 14 个文件；`base/`、`diagnostics/`、`exception/`、`pool.cj`、`UnitKeyPool.cj` 及各 `*_test.cj` 的剩余部分由第 2 部分产出，合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_pool`（本部分 12 个 `.cj` + 2 个 `.md`）
- **基线**：工作区快照（sts/1.3.x，无 diff 可比）
- **审查重点**：对象池/线程池生命周期、泄漏与 OOM、大粒度锁与并发串行、栈溢出、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 1/2 部分）

## 发现

### [严重][存量] `KeyPool.giveBack` 抛 `UnknownKeyException` 时，池项的 `Ref` 终结器仍会销毁它 —— 「所有权仍在调用方」的契约不成立

- **位置**：`f_pool/src/KeyPool.cj:807`（`pool.giveBack(key, ref(key, object), checkOnReturnFn, keyedDestroy)`）+ `f_pool/src/Ref.cj:24-34`（`~init` 终结器）+ `f_pool/src/BaseKeyPool.cj:56-59`（未知键直接抛）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「资源不对称」；§3「错误路径静默产生副作用」
- **证据**：静态确定 —— `ref(key, object)` 在调用前就已把对象装进一个带终结器的 `Ref`；`BaseKeyPool.giveBack` 在未知键分支**不碰** `value` 直接 `throw`，此时该 `Ref` 在调用方栈帧里立刻不可达，GC 终结器 `~init` 必然走到 `destroy(v)`。销毁时机由 GC 决定（延迟、不确定），但**一定会发生**。
- **描述**：文档（`BaseKeyPool.cj:56-59` 注释、`README.md:203-207`、`README_en.md:204-211`）明确承诺：还错键时「不归还、不销毁、所有权仍在调用方」。实际执行路径是：`KeyPool.giveBack` 先建 `Ref`（持有对象强引用 + 销毁回调）→ 底层抛异常 → `Ref` 变垃圾 → 终结器在借用方仍在用这个对象时调用 `destroier`（典型后果：连接/socket/文件句柄被关闭，之后再用就是 use-after-destroy；应用若按文档「自己销毁」还会二次销毁）。同一根因的次要面：`clearOnReturning = true` 时 `clear(key, object)` 在**键校验之前**执行（`KeyPool.cj:793-806`），未知键场景下对象已被 clear 但没有归还。
- **建议**：`giveBack` 里不要提前建 `Ref`——改为先在底层完成键校验（或把 `ref` 的构建推迟到 `BaseKeyPool.giveBack` 确认池存在之后）；退路是捕获 `UnknownKeyException` 后显式 `ref.take()` 并把原对象交回调用方（`Rethrow` 前清空 `Ref`）。同时补一条用例：抛异常后强制 `gc()` 两次再断言 `destroyed == 0`。现有用例 `KeyPool_test.cj:781` 只在抛出的**同一时刻**断言 `destroyed.load() == 0`，终结器还没跑，所以这个缺陷被漏掉了。

### [一般][存量] `ArrayPool` / `ArrayListPool` 没有 shutdown 入口：底层 `KeyPool` 的维护线程与池项永不释放

- **位置**：`f_pool/src/ArrayPool.cj:22-81`、`f_pool/src/ArrayListPool.cj:20-53`（只有 `get` / `giveBack`，无 `close` / `release`）、`f_pool/src/BytesListOutputStream.cj:233-248`（`builder()` 每次调用都新建一个池）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称（打开未关）」、§12.1「有界性」、§5「长期持有 / 注册表不注销」
- **证据**：静态确定 —— 两个 `public struct` 把 `private let pool: Pool<T>` 完全封住，`Pool` 明明实现了 `Resource`（`close()` / `awaitTermination()`），但没有任何转发；结构体也没有 `~init`。因此每一份 `ArrayPool` / `ArrayListPool` 实例都会留下：1 个创建线程（`KeyPool.cj:501`）+ 1 条 `ExitCallbacks.atExit` 注册（`KeyPool.cj:306`，`f_base/src/signal.cj:48-60` 无注销 API）+ 池内全部池项（`destroier` 只在 `close`/`remove` 时调用）。
- **描述**：`BytesListOutputStream.builder(...)` 是**工厂函数**，每次调用都会 `new` 一个 `ArrayPool<Byte>`（`BytesListOutputStream.cj:267`），也就是说「按需建 builder」这种自然写法每来一次就泄漏 2 个线程量级的资源（builder 默认 `checkInterval = Duration.Max` 只起创建线程，`Duration.Zero` 档则是两个线程）。仓库里 `f_codec/src/default/DefaultCodec.cj:65-78` 的 `setBytesPool` / `setBufferPool` 就是「直接覆盖静态字段、不关旧池」，旧池从此不可达却仍被自己的线程强引用（`KeyPool.cj:382-402` / `501-521` 的 `spawn` 闭包捕获 `this`）。一次配置重建 = 泄漏一整套池。
- **建议**：给 `ArrayPool` / `ArrayListPool` 加 `public func close()`（转发 `pool.close()`）并让 `BytesListOutputStreamBuilder` 也暴露 `close()`；`README.md` 增加「池必须在不用时关闭」段落。若坚持不暴露生命周期，至少要在 `KeyPool` 侧用 `WeakRef` 让创建线程可被回收（但创建线程需要强引用队列，代价更大）。

### [一般][存量] `KeyPool` 构造中段抛异常 ⇒ 两个后台线程永久 park 在构造栅栏上，持有半构造对象

- **位置**：`f_pool/src/KeyPool.cj:295-296`（先起线程）→ `297-299`（`while(let Some(k) <- initKeys())`，用户回调）→ `312-315`（最后一步才放行栅栏）；`318-327`（`waitConstructed` 无超时、无退出条件）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称」、§12.1「跨线程资源 / 生命周期」、§5「长期持有」
- **证据**：静态确定 —— 两个 `spawn` 体的第一句都是 `waitConstructed()`，它只等 `constructed == true` 或 `barrier` 通知；放行只发生在构造函数最后一行。构造函数若在 `initKeys()`（应用回调，可抛）或 `ExitCallbacks.atExit`（`306`）处抛出，`constructed` 永远为 `false`，也没有任何人能拿到对象去 `close()`/`cancel()`。
- **描述**：构造失败时泄漏 2 个线程 + 1 个 `KeyPool` 对象（`spawn` 闭包强引用 `this`）+ 已建好的 `ArrayBlockingQueue` + `initKeys` 期间已经创建并入库的池项（它们的 `destroier` 再也没有调用者）。应用若在「配置错误 → 重建池 → 再失败」的循环里，线程与内存按次累加，属于无界泄漏。
- **建议**：把 `startCreationSchedule()` / `startCheckingSchedule()` 挪到构造体最后（`constructed.store(true)` 之后），或用 `try/finally`：`catch` 里 `running.store(false)` + `constructed.store(true)` + `barrier.notifyAll()` 再 rethrow，让线程看到 `running == false` 自行退出。`initKeys` 迭代也应放在放行之前、线程启动之前。

### [一般][存量] `LocalBufferCache` 的本地缓冲不随线程退出归还 ⇒ 池额度永久泄漏，线程更替足够多次后池枯竭

- **位置**：`f_pool/src/BytesListOutputStream.cj:29-76`（本地栈 `buffers`，只有 `giveBack` 会回池）、`254`（`ThreadLocal<LocalBufferCache>`）、`262-266`（`maxSize ≥ 64` 时 `localCacheSize` 保持默认 2）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「长期持有 / ThreadLocal 不清」、§7「池化必须有上限 / 生命周期对称」、§11「资源不对称」
- **证据**：静态确定（无任何线程退出回调、无 `WeakRef`、`ThreadLocal` 条目随线程一起消失，而池的记账只在 `giveBack` / `remove` / `close` 时递减）。量化：默认 `maxSize = 1024`、`localCacheSize = 2` ⇒ 每 512 个「借过缓冲又结束」的线程就会把 1024 份额度全部钉死（`s` 里仍算「借出中」），此后 `KeyPool.get` 的 `pool.size < totalSize` 恒假，不再建新项，`get()` 只能等满 `maxWaiting`（30s）后返回 `None`。
- **描述**：每个线程的 `LocalBufferCache` 最多攒 2 个 8KB 缓冲（默认 `capacity = 8192`），线程结束（线程池缩容、`spawn` 短任务、连接级线程）时这两个缓冲直接变垃圾，池却仍记为「已借出」。表现是「运行越久越难借到编码缓冲」，且没有任何日志（额度没满时不告警，满到取不到才 WARN）。同一份代码在 `maxSize < 64` 时会强制关掉本地缓存（`262-266` 注释自己写了「否则每线程扣住 2 个缓冲会把池锁死」），说明作者知道这个风险，只是没覆盖大池场景。
- **建议**：给本地缓存加「可归还」通道：`LocalBufferCache` 记录借用线程、线程内缓冲数上限用一个**全局额度**（`AtomicInt64`）约束；或改用 `WeakRef<缓存的缓冲>` 让池侧能回收；最低成本是 `BytesListOutputStreamBuilder` 提供一个 `flushLocal()`，并在 `build()` 里按阈值（例如 `pool.size` 接近 `maxSize`）主动回池。

### [一般][存量] `ChainedBytesCopyTo.asBytes` 先按 `byteSize()` 预分配，再校验子项是否支持

- **位置**：`f_pool/src/BytesCopier.cj:142-162`（`let out = Array<Byte>(n, repeat: 0u8)` 在 `for` 循环里才发现某个子项 `asBytes()` 为 `None`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「按不可信长度预分配」、§11「错误处理顺序」
- **证据**：待确认 —— 缺 `declaredSize` 的上游来源。`PooledBufferBytesCopyTo.byteSize()`（`BytesCopier.cj:54-61`）直接把构造时传入的 `declaredSize` 当长度返回，而 `declaredSize` 在 `f_codec`/`f_protocol` 里通常来自待编码帧的 `len` 字段；是否经过上限校验需看调用方。
- **描述**：`asBytes()` 先做 `Array<Byte>(n)`（n = 各子项 `byteSize()` 之和），然后逐个 `b.asBytes()`；只要有一个子项返回 `None`（流式内容、`PooledBufferBytesCopyTo` 就是这种），这次分配完全白费并整体返回 `None`。如果 `n` 来自报文长度且没有上限，就是一次 `Array` 分配直接触发 `OutOfMemoryError`（崩进程，不是返回错误）。即使 `n` 可信，这段也在失败路径上白付一次全量分配 + GC 压力。
- **建议**：先收集 `let parts = bytes.map(b => b.asBytes())` 并确认全部 `Some`，再 `byteSize()` 求和分配；或把分配改成 `Array<Byte>(0)` + 逐段追加（`ArrayList<Byte>` 有扩容放大，不推荐），并给 `n` 加一个显式上限（`maxAsBytes`，超限返回 `None`）。

### [一般][存量] `PooledBufferedBytesCopyFrom` 的 `closeOnEnd` 参数完全不生效

- **位置**：`f_pool/src/BytesCopier.cj:89-118`（`private let closeOnEnd!: Bool = true` 定义于 `92`，全模块无读取；`copy` 只看参数 `closeToOnEnd`，见 `93`、`100-105`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「读了不用（死配置字段）」、§11「语义与命名不符 / 参数被静默忽略」
- **证据**：静态确定 —— `grep -rn "closeOnEnd" f_pool/src` 只命中定义行 `BytesCopier.cj:92`。
- **描述**：调用方按语义写 `PooledBufferedBytesCopyFrom(output, pool, closeOnEnd: false)`（期望「拷完别关我的 output」），实际 `copy` 依旧按 `closeToOnEnd`（默认 `true`）把 `output` 关掉。这是**无声的行为偏差**：参数在签名里、编译通过、没有警告。同文件的 `PooledBufferBytesCopyTo` 没有这个字段，说明是从那边复制过来时漏改。
- **建议**：`copy` 的关闭判定改成 `if (closeToOnEnd && closeOnEnd && ...)`（两个开关取与），或在构造时把它折叠进 `closeToOnEnd` 的默认值；若该参数本就无用，直接删掉（构造器是 `public`，删除是破坏性变更，需与 `README.md:335` 的说明一起改）。

### [一般][存量] README（中英）把巡检判据写成 `p.size < max && checker(...)`，与实现（`POOL-3` 修复后）正好相反

- **位置**：`f_pool/README.md:316`、`f_pool/README_en.md:333` ↔ `f_pool/src/BaseKeyPool.cj:91-98`（`p.check(running, {v => checker(k, v)}){if (p.size < max) { taskPusher(k) }}`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§14「文档承诺与实现相反」
- **证据**：静态确定 —— 代码注释（`BaseKeyPool.cj:93-96`）明说「`p.size < max` 不能写成 checker 的与条件」，并给出后果（每轮巡检丢一个空闲项、整轮跳过用户 checker）；README 两版仍写着旧判据。
- **描述**：这是本模块唯一记录「巡检语义」的内部文档段落，写反了会把排查者直接引向错误结论（例如照文档认为「满载时 checker 不执行」）。同一段的其余描述（`s` 的记账口径、`remove` 先摘键再关闭）与实现一致，只有这一句过期。
- **建议**：两版同步改为「`checker` 每轮对每个 key 的空闲项照常执行；`p.size < max` 只作为 `taskPusher`（补建）的闸门」。

### [轻微][存量] 死符号：`Ref.pooledTime` / `Ref.reset` / `BytesListOutputStream.pool`

- **位置**：`f_pool/src/Ref.cj:48-52`（`prop pooledTime`，唯一读取点 `57` 用的是私有字段 `pooledTime_`）、`f_pool/src/Ref.cj:53-55`（`reset()`）、`f_pool/src/BytesListOutputStream.cj:90`（`private let pool`，只在 `98` 赋值，之后从不读取）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「无调用者（private / 非 public 类型成员）」
- **证据**：静态确定 —— `Ref` 是 `class`（包内可见，非 public），其 `public`/包内成员按「全仓搜引用」判：`grep -rn "pooledTime" f_pool` 只有 `Ref.cj` 自身与 `pooledTime_`；`grep -rn "\.reset()" f_pool` 命中的是 `BytesListOutputStream.reset`（`releasable_test.cj:144`），不是 `Ref.reset`；`BytesListOutputStream.pool` 在同类里无第二处读取。
- **描述**：`Ref.reset()` 与 `pooledTime` 是「空闲计时可外部重置」的遗留扩展点，重构后计时只在构造时打点；`BytesListOutputStream.pool` 是死字段，副作用是把整池强引用延长到每个流对象（增长路径上缓冲已还给 cache，字段却仍指向池）。
- **建议**：删掉三者；若要保留 `Ref.reset` 作为将来扩展点，加注释说明「当前无调用方」并考虑收窄可见性。

### [轻微][存量] 「销毁回调抛异常」在三条路径上处理不一致：`giveBack` 关停路径丢现场

- **位置**：`f_pool/src/BaseKeyPool.cj:62-69`（`catch (e: Exception) { PoolDiagnostics.onCallbackError() }`，无日志）↔ `f_pool/src/KeyPool.cj:680-686`（`doDestroy` 打 `logger.warn('error on destroying', e)`）↔ `f_pool/src/base/BasePool.cj:50-57`（`closeDestroyed` 只计数）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「同一语义的实现漂移」、§3「静默吞异常」、§12.1「异常不可观测」
- **证据**：静态确定 —— 三处都是「调 `destroier` → 吞异常 → 记数」，只有 `doDestroy` 带日志与异常对象；`unreturnable` 连异常文本都丢掉，只留一个 `callbackError` 计数。
- **描述**：`giveBack` 在关停窗口（`running == false`）走 `unreturnable`，这是**进程退出/池关闭**时最容易出问题的路径（关闭 socket、flush 缓冲），恰恰只有计数没有现场，故障排查拿不到「哪个 key、什么异常」。
- **建议**：把三者归一到一个 `destroySafely(key, v, destroier)`（放在 `KeyPool`，由 `BasePool`/`BaseKeyPool` 通过回调注入），统一「计数 + WARN（含 key 与异常）」；`unreturnable` 至少补一条 `logger.warn`。

### [轻微][存量] `waitConstructed` 不在循环里重查谓词（虚假唤醒即越过构造栅栏）

- **位置**：`f_pool/src/KeyPool.cj:318-327`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「条件等待：虚假唤醒未在循环里重查条件」
- **证据**：待确认 —— 缺「该运行时 `Condition.wait` 是否可能虚假唤醒」的实测；但同文件其余 3 处等待（`411-427`、`525-537`、`713-734`）全部用 `while` + 重查，唯独这一处是 `if (!constructed.load()) { barrier.wait() }` 单次判断。
- **描述**：若发生虚假唤醒，后台线程会在构造函数尚未执行完（`initKeys`、`ExitCallbacks` 还没跑，`this` 处于半初始化）时进入 `checkingLoop` / `creationLoop` 并访问 `this` 的成员——这正是 `constructed` 注释（`229-234`）里想兜住的 SIGSEGV 场景。
- **建议**：改用标准库现成的 `barrier.waitUntil({=> constructed.load()})`（`std.sync` 的 `Condition.waitUntil(predicate)`），或 `while (!constructed.load()) { barrier.wait() }`。

### [轻微][存量] README（中英）把 `private class InitKeyIterator` 的 `next()` 列成「模块级 public API」

- **位置**：`f_pool/README.md:361`、`f_pool/README_en.md:379` ↔ `f_pool/src/pool.cj:235-245`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.2「公开 API 文档化」的反面：文档列了**不存在**的公开符号；§13「示例/清单与源码不符」
- **证据**：静态确定 —— `InitKeyIterator` 是 `private class`，其 `public func next()` 只是接口实现；模块里没有顶层 `next()`。
- **描述**：读者会以为模块导出了一个模块级 `next(): ?Unit`；实际它不可见。这条是自动生成清单时按「public 修饰符」抓的，没有判可见性链。
- **建议**：删掉该行（「其他公开 API」小节只列真正对外可达的符号）。

### [轻微][存量] `writeUInt64BE` 不校验 `count` 上界（> 8 触发移位越界运行时异常）

- **位置**：`f_pool/src/BytesListOutputStream.cj:153-165`（注释声明 `count ∈ [1, 8]`，实现只判 `count <= 0`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 缺少边界校验」
- **证据**：静态确定 —— 语言规范（`cangjie-doc/.../basic_operators.md:271`：「如果右移或左移的位数等于或者大于操作数的宽度，则为移位越界……运行时抛出异常」）⇒ `count = 9` 时 `value >> (8 * 8)` 抛异常。
- **描述**：`ensureCapacity(count)` 已经把缓冲扩容，随后在写第 1 个字节时抛异常，`len` 未变——缓冲状态与「什么都没写」一致（可接受），但异常类型是底层的移位越界，不是明确的参数校验错误，排查成本高。这是 `public` 热路径 API，一个手滑的 `count` 就算错值就会炸。
- **建议**：入口加 `if (count < 0 || count > 8) { throw IllegalArgumentException('count must be in [1, 8]') }`（与注释口径一致）。

### [轻微][存量] `PoolLifecycle_test.cj` 用 SPDX 单行头替代 Apache 2.0 版权头

- **位置**：`f_pool/src/PoolLifecycle_test.cj:1`（`// SPDX-License-Identifier: Apache-2.0`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：fountain 基线 §3「每个 `.cj` 文件必须有 Apache 2.0 版权注释，位于 `package` 之前」
- **证据**：静态确定 —— 同目录其余 `.cj` 都是 15 行完整头（含 `Copyright (c) 2025/2026 WuJingrun`），仅此文件是一行 SPDX。
- **建议**：补齐标准头。

### [轻微][存量] `KeyPool_test.test0` 残留调试输出与未使用的局部变量

- **位置**：`f_pool/src/KeyPool_test.cj:49`（`println('~~~~~~~~~~~~~~~~~~')`）、`87-90`（`c1` / `c2` 取出后再未使用）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「读了不用」、§10「可读性 / 可维护性」
- **证据**：静态确定 —— `c1`/`c2` 之后没有读取；`println` 无断言作用。
- **建议**：删掉 `println` 与两个未使用变量（或给 `c1`/`c2` 补 `isSome` 断言，让它变成有意义的覆盖）。

### [轻微][存量] 重复逻辑：两个「池化缓冲流式拷贝」只有方向与默认值不同

- **位置**：`f_pool/src/BytesCopier.cj:62-87`（`PooledBufferBytesCopyTo.copy`）与 `93-117`（`PooledBufferedBytesCopyFrom.copy`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改字段名 / 换方向」「字面量复制」
- **证据**：静态确定 —— 两段结构逐行对应：`pool.get()` → `try { while(read/write) } finally { 关 to、关 from }` → `else { copyTo(Array<Byte>(4096, repeat: 0)) }`；`4096` 这个回退尺寸写了两遍。
- **差异点（合并前必须参数化）**：① 方向（`input → to` vs `from → output`）；② 默认值相反（`closeFromOnEnd` 默认 `true`/`false`，`closeToOnEnd` 默认 `false`/`true`）；③ 关闭顺序两处都是「先输出端后输入端」，一致。
- **建议**：抽一个 `func copyStream(from: InputStream, to: OutputStream, buf: Array<Byte>, closeFrom: Bool, closeTo: Bool)`，两个 `copy` 只保留参数适配与默认值；回退尺寸提成常量 `FALLBACK_COPY_BUFFER = 4096`。

## 优化可行性方案

> 均无改前/改后对照数据，一律按「待验证假设」处理，不进 `todo.md` / `tasks.md`。

### [CPU] `get` / `giveBack` 每次调用现取 `keyedDestroy` 方法值，`giveBack` 每次新建 `Ref` + 闭包

- **现状**：`KeyPool.cj:768` / `753` / `807` 把 `keyedDestroy` 作为方法值传入；`KeyPool.cj:580-582` 的 `ref(key, object)` 每次归还都 `new Ref` + 捕获 `key`/`destroier` 的闭包。文件自己的注释（`KeyPool.cj:237-246`）给出过微基准：现场取方法值 39 ns + 45 B vs 复用 15 ns + 0 B，并按此把 `checkOnBorrow`/`checkOnReturn` 缓存成字段——但同样的代价在 `keyedDestroy` 与 `Ref` 上仍然每调用一次付一次。
- **方案**：构造期缓存 `keyedDestroy` 的方法值；`Ref` 改为「值 + 弱化销毁入口」的可复用形态（例如把 `destroier` 与 `key` 移到 `BaseKeyPool` 侧的 per-key 上下文，`Ref` 只持有值 + 时间戳），或直接复用队列节点里的容器而不是新造 `Ref`。
- **预期**：每次 `get`/`giveBack` 少 1 次闭包分配（45 B）；按 10 万 QPS 的编码路径估算约 4.5 MB/s 的分配量下降（**推算，未测**）。
- **代价**：`Ref` 结构变更牵动 `BaseKeyPool`/`SyncDeque` 的销毁回调链，改动面大；`keyedDestroy` 缓存需要 `this` 初始化完成（同 `POOL-L5` 的约束）。
- **验证**：`cjpm bench -O2` 跑 `KeyPoolBench.bench`（`KeyPool_test.cj:1050`，单线程 get/giveBack）改前/改后各 5 轮取中位数与 P95；再用 `cjprof record` 看 `keyedDestroy` / `Ref.<init>` 的分配采样占比。
- **证据状态**：`无基线（待验证，仅有代码注释中的 closureshape 微基准）`

### [CPU] 单创建线程 + `wakeWaiters()` 全广播：创建吞吐上限为 1/creator 延迟，且一次创建唤醒所有等待者

- **现状**：每个 `KeyPool` 只有一个创建线程（`KeyPool.cj:500-522`），所有 key 的创建任务串行消费；每处理完一条任务就 `wakeWaiters()`（`576`），而 `wakeWaiters` 是 `notifyAll`（`473-481`）。W 个等待者等 W 个池项时，总唤醒次数是 O(W²)，每个被唤醒者还要重跑 `pool.get` + `keyedSize` + 可能的 `tryAddTask`。
- **方案**：① 创建任务按 key 分片到 N 个创建线程（N = min(活跃 key 数, 4)），每个线程只消费自己分片；② 等待者从「一个条件变量全广播」改成「per-key 条件 + 纪元号」（现在的 `available` 纪元已经具备实现基础，`waitItem` 的签名已带 `seen`）。
- **预期**：creator 是 ms 级 I/O（建连、打开文件）时，启动/扩容阶段的池填充从「串行 Σ 延迟」降到「并行 ⌈n/N⌉ × 延迟」；高并发下唤醒次数从 O(W²) 降到 O(W)（**推算，未测**）。
- **代价**：线程数随池数量增长（现在是 1 + 巡检）；分片线程与 `close()` 的取消传播、`awaitTermination` 的等待列表都要跟着改；per-key 条件变量增加对象数。
- **验证**：`creator` 注入 `sleep(5ms)`，`maxSize = 64`，32 个线程同时 `get`：测总耗时与 `getThreadCount()`；再对 `wakeWaiters` 的调用次数埋点（`PoolDiagnostics.auditRounds` 旁边加一个 `wakeups`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `ArrayPool` / `ArrayListPool` 默认 `maxSize = Int64.Max` + `elementLife = Duration.Max` + `checkInterval = Duration.Zero` ⇒ 峰值并发变常驻

- **现状**：`ArrayPool.cj:25-32`、`ArrayListPool.cj:23-30` 三个默认值叠加的效果是「按需无限增长、永不回收、没有巡检线程」。池化项在 `giveBack` 后一直留在队列里，直到 `close()`（而这两个类型没有 `close`，见发现 #2）。
- **方案**：把 `maxSize` 默认值改成一个明确上限（例如 1024，与 `BytesListOutputStream.builder` 的默认一致），并要求 `elementLife` 给有限值 + `checkInterval` 给有限值（否则空闲回收不生效）。
- **预期**：单进程常驻池项上界 = `maxSize × arraySize × sizeof(T)`；默认 1024 × 128 × 8 B = 1 MB（`ArrayPool<Int64>`），相对当前「等于峰值并发数 × 单元素」有界化。
- **代价**：语义变更（默认值变化是破坏性变更）；上限压得低会让突发并发退化成 `get` 等 30s 后 `None`。
- **验证**：跑「10k 并发借还 → 空闲 10 分钟」的负载，对比改前/改后 `getAllocatedHeapSize()` + RSS 稳态值（`mem §1.2`）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `ExitCallbacks` 注册表按「池的创建次数」线性增长且无注销路径

- **现状**：`KeyPool.cj:305-310` 每个池注册一条 254 优先级的退出回调；`f_base/src/signal.cj:48-60` 只提供 `atExit`，没有 `remove`。弱引用只保证「不把池钉住」，回调对象本身与 `WeakRef` 永远留在 `TreeMap` 里。
- **方案**：`ExitCallbacks` 增加 `remove(priority, id)` 或返回 `handle`；`KeyPool.close()` 在末尾注销自己那条。
- **预期**：回调条目数 = 存活池数，而非历史创建数；进程退出时 `onExit` 的遍历成本同步下降。
- **代价**：`f_base` 的公开 API 增加一个方法；`close()` 需要记住自己的注册 handle（多一个字段）。
- **验证**：建/关 10 万个池，观察 `callbacks` 列表长度与 RSS；退出耗时对比。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单创建线程使池填充吞吐上限 = 1/creator 延迟；`maxSize = 1024` 的启动填充是串行 1024 次 creator | `KeyPool.cj:500-579` | 填充总耗时、creator 单次延迟分布 | `creator` 注入固定 `sleep`，测 `initSize` 从 0→1024 的耗时；`cjprof record` 看创建线程 CPU 占比 |
| 2 | `wakeWaiters()` 的 `notifyAll` 在高并发下形成惊群，唤醒次数 O(W²) | `KeyPool.cj:473-481`、`576` | 每秒唤醒次数、等待者重试次数 | 在 `wakeWaiters` / `waitItem` 加计数埋点，32/128 线程压测 `get`/`giveBack` 10 分钟 |
| 3 | 巡检每轮对每个 key 执行一次 `sleep(Duration.Zero)` 让出，key 多时单轮耗时被拖长、`minSize` 补足滞后 | `BaseKeyPool.cj:92-105`、`KeyPool.cj:450-453` | key 数 vs 单轮耗时曲线 | 用 `KeyPool<String,_>` 建 1k/1w/10w 个 key，测两次 audit 之间的间隔分布 |
| 4 | `LocalBufferCache` 的额度泄漏阈值（默认 512 个线程生命周期）在真实线程池缩容场景下会触发 | `BytesListOutputStream.cj:29-76` | 线程创建/销毁速率、`pool.size` 长期趋势 | 持续 `spawn` 短任务各借还一次缓冲，每 100 个线程打印 `pool.size`，看是否单调上升到 `maxSize` |
| 5 | `ChainedBytesCopyTo.asBytes` 的 `Array<Byte>(n)` 会随帧长线性抬高峰值 RSS（且失败路径白付） | `BytesCopier.cj:142-162` | `declaredSize` 实际上限、失败命中率 | 用 1KB/64KB/1MB 帧各跑 10k 次，对比 `getUsedHeapSize()` 峰值；统计 `asBytes` 返回 `None` 的比例 |
| 6 | `ArrayPool` 默认无上限导致「峰值并发数」变成常驻池项数 | `ArrayPool.cj:25-32` | 峰值并发借出数、空闲 10 分钟后的 `pool.size` | 10k 并发借还后退回空闲，观察 `PoolDiagnostics.snapshot()` 的 size 是否回落 |
| 7 | 每次 `giveBack` 的 `Ref` + 闭包分配在编码热路径上占 GC 分配量的一成以上 | `KeyPool.cj:580-582`、`807` | 分配采样、GC 次数 | `cjprof record` 跑 `f_codec` 编码 100 万条小消息，看 `Ref.<init>` / 闭包分配的占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_pool/README.md` | .md | ✅ | 与实现大体重合；见发现 #7（巡检判据过期）、#11（`next()` 误列） |
| 2 | `f_pool/README_en.md` | .md | ✅ | 与中文版逐节对齐（同样含 #7 / #11 两处过期） |
| 3 | `f_pool/src/ArrayListPool.cj` | .cj | ✅ | 见发现 #2（无 shutdown 入口） |
| 4 | `f_pool/src/ArrayPool.cj` | .cj | ✅ | 见发现 #2、优化方案（默认无上限） |
| 5 | `f_pool/src/BaseKeyPool.cj` | .cj | ✅ | 见发现 #1（未知键抛错）、#9（销毁异常吞现场） |
| 6 | `f_pool/src/BaseKeyPool_test.cj` | .cj | ✅ | 6 个用例与实现契约一致；`giveBackToUnknownKeyMustThrow` 同样只测即时计数（未覆盖 #1） |
| 7 | `f_pool/src/BytesCopier.cj` | .cj | ✅ | 见发现 #5、#6、#15 |
| 8 | `f_pool/src/BytesListOutputStream.cj` | .cj | ✅ | 见发现 #4、#8、#12 |
| 9 | `f_pool/src/IKeyPool.cj` | .cj | ✅ | 接口与两个实现（`BaseKeyPool` / `UnitKeyPool`）签名一致 |
| 10 | `f_pool/src/KeyPool.cj` | .cj | ✅ | 见发现 #1、#3、#8、#10，优化方案 1/2 |
| 11 | `f_pool/src/KeyPool_test.cj` | .cj | ✅ | 32 个用例；见发现 #14（调试残留）、#1（用例覆盖不足） |
| 12 | `f_pool/src/Mode.cj` | .cj | ✅ | `poolCreator` / `createPool` 均有调用方（`BaseKeyPool.cj:35` / `UnitKeyPool.cj:24`） |
| 13 | `f_pool/src/PoolLifecycle_test.cj` | .cj | ✅ | 4 个用例；见发现 #13（文件头） |
| 14 | `f_pool/src/Ref.cj` | .cj | ✅ | 见发现 #1（终结器）、#8（死符号） |

合计：`.cj` 12 个 / `.md` 2 个 / 共 14 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 #1/#5/#6/#10，可读性 #14，设计（生命周期缺失）#2；无外部输入拼接、无凭据、无注入面（本部分不处理 SQL/HTML/路径） |
| §1 死代码 | 2 | 逐个 `private` / 包内符号全仓搜引用：`Ref.pooledTime`、`Ref.reset`、`BytesListOutputStream.pool` 无引用（#8）；`PooledBufferedBytesCopyFrom.closeOnEnd` 无读取（#6）。`createTaskQueueCapacity`、`doCheck`、`keyedCheck`、`ref`、`Mode.poolCreator`、`Mode.createPool` 均有调用方；`public` 且对外可达的符号（`BytesCopyTo.*`、`Releasable`、`BytesListOutputStream.*`、`ArrayPool`、`ArrayListPool`、`Mode`）不判；`IKeyPool` 的 `public` 成员由两个实现经接口调用，不算死代码 |
| §2 重复逻辑 | 1 | 同文件两两比对 12 个函数体：`PooledBufferBytesCopyTo.copy` 与 `PooledBufferedBytesCopyFrom.copy` 同语义（#15）；三处「销毁 + 吞异常 + 计数」归入 #9；`PoolBuilder`/`KeyPoolBuilder` 的 14 个 setter 属刻意样板（§2 误报边界），不报 |
| §3 空实现 | 1 | `ObjectManager.clear` / `KeyedObjectManager.clear` / `BytesCopyTo.byteSize|frameBytes` 的默认空实现均有 README 说明（Null Object，不算问题）；`BaseKeyPool.unreturnable` 的 `catch` 只计数不记现场 = 静默吞（#9） |
| §4 栈溢出 | 0 | 本部分无递归：`ChainedBytesCopyTo` 用 `for` 遍历、`copy` 层层调用但深度固定为 1（子项不互相嵌套）；无自引用结构遍历、无可变深度递归 |
| §5 OOM | 2 | #5（按 `byteSize()` 预分配）、#2（无上限池 + 无 shutdown，长生命周期累积）；`CREATE_TASK_QUEUE_CAP = 1024` 已把任务队列与池容量解耦，未命中 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据；`get`/`giveBack`/创建线程/巡检的耗时全部降级为「待验证假设」1-7 |
| §6.2 大粒度锁 | 0 | 逐处核对临界区：`admission` 内只有 `running.load() && pool.add`（一次哈希表 + 队列插入，无 I/O/回调）；`creationMutex` 内是 `tasks.tryAdd` + `notifyAll`；`waitMutex`/`checkMutex` 内只有谓词复查与 `wait`。`SyncDeque`/`LinkedNode` 的 checker 与 destroier 都在锁外调用（`LinkedNode.cj:305-330`、`SyncDeque.cj:182-196`），不存在「锁内回调」；故无「大粒度锁」成立（性能面见待验证假设 2） |
| §6.3 并发串行 | 0 | 线索两条：单创建线程（`KeyPool.cj:500`）、`notifyAll` 全广播（`473-481`）。无并发度/串行段占比数据，按铁律只进「待验证假设」1-2 与优化方案 2 |
| §6.4 低效算法 | 0 | 本部分无 `remove(at: 0)` 队列、无嵌套循环匹配、无循环内字符串拼接、无重复解析；`LocalBufferCache` 的 `remove(at: size-1)` 是尾部删除（O(1)），不命中 |
| §7 降堆内存方案 | 2 | 优化方案 3（默认无上限池）、4（`ExitCallbacks` 注册表）；均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 优化方案 1（方法值/`Ref` 分配）、2（单创建线程 + 惊群）；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分的大临时对象都会逃逸：`ChainedBytesCopyTo.asBytes` 的 `out` 作为返回值逃逸，`ensureCapacity` 的 `grown` 存进 `buf` 字段逃逸，`Ref` 进队列 —— 均不满足「函数内创建、函数内释放」，改造不可行，不列方案 |
| §11 现有代码的 BUG（存量） | 4 | #1（契约不符 + 资源提前销毁）、#5（预分配顺序）、#6（参数被忽略）、#12（边界校验）；另核对了 `ArrayPool.giveBack` 尺寸校验、`awaitTermination` 的 `TimeoutException` 分支、`get` 的 `remain` 计算（无溢出写法）、`Ref.take()` 的所有权转移，均无缺陷 |
| §12 并发安全与锁粒度 | 1 | 逐点核对：`running`/`available`/`waiters`/`s` 全为原子；`close()` 用 CAS 保证幂等；`waitItem` 用「纪元 + 锁内复查」消除丢唤醒（`KeyPool.cj:713-734`）；只有 `waitConstructed` 单次判断谓词（#10）；`creationThread`/`checkingThread` 仅在构造期写、`close` 读，发布链没问题。无死锁、无锁顺序反转、无「每次新建锁对象」 |
| §14 功能完备性与 README 覆盖 | 1 | 逐项对照 `public` 声明与两版 README：`Mode`、`Pool`/`PoolBuilder`、`KeyPool`/`KeyPoolBuilder`、`ArrayListPool`、`ArrayPool`、`BytesCopyTo`/`BytesCopyFrom`/`BytesCopier`、`Releasable`、`ChainedBytesCopyTo`、`PooledBuffer*`、`BytesListOutputStream`(+builder)、`maxWaiting` 语义均在文档中；唯一错项是 #11（把不可见符号列为公开 API）。`setinitKeys` 命名（小写 i）两版 README 与代码一致，无「文档说 A 代码是 B」 |
| 文件覆盖（§13 等） | 14/14 | 无缺文件；`.md` 按 §13 逐段核对（见 #7 / #11） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 6 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

代码的并发底座（纪元号 + 条件变量、记账自愈、`take()` 所有权转移）想得比一般池库细，注释里带着失败案例编号，可读性不差；**主要风险集中在「异常/关停路径」和「没有生命周期的池」两处**：

- 阻塞项（建议先修）：#1 —— `giveBack` 的未知键路径会通过 `Ref` 终结器销毁调用方仍持有的对象，这直接违背它对外的书面契约，而且现有用例因为只查「抛出瞬间的计数」而漏掉了它。这一条应是 1.3.x 的必修项。
- 排期项：#2 / #3 / #4 都是同一主题——池的生命周期不闭环（`ArrayPool`/`ArrayListPool` 不能关、构造失败无线程回收、线程本地缓冲不回池）。单看每处都只是「一点泄漏」，合起来就是「运行越久越借不到编码缓冲、进程退出前线程数只增不减」，对长跑服务是实打实的可用性风险。
- 文档：#7 是唯一会把人带偏的段落（巡检判据写反），跟 #11 一起改，成本极低。
- 性能与内存：本部分所有收益判断都没有改前/改后数据（无 `cjprof` / `cjpm bench` 基线），按铁律全部落在「待验证假设」，不进修复清单；其中「单创建线程 + 全广播唤醒」和「`ArrayPool` 默认无上限」最值得下一轮补数据。
- 已确认**没有**的问题：栈溢出（§4）、大粒度锁与锁内回调（§6.2）、死锁（§12）、local mode（§9 对象均逃逸）。

存量缺陷共 15 条（严重 1 / 一般 6 / 轻微 8），是否纳入修复待用户决定；本报告只读代码，未做任何修改。
