# f_pool 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_pool`（31 个文件：29 个 .cj + 2 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 2 个分部分报告合并：`parts/f_pool.part1..2.md`）

## 发现

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

### [一般][存量] `KeyPool<Unit, V>.remove(())` 之后 `get` 变成「建了立刻销毁」的空转，直到 `maxWaiting`（默认 30s）超时

- **位置**：`f_pool/src/UnitKeyPool.cj:53-55`（`remove` 直接 `pool.close{...}`）→ `f_pool/src/KeyPool.cj:544-565`（创建循环）→ `f_pool/src/KeyPool.cj:766-780`（`get` 的等待循环）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「错误处理缺失」；§12.1「有界性」；§6.3「并发串行（单消费者空转）」
- **证据**：静态确定 —— `UnitKeyPool.remove` 与 `close` 同体，只把底层 `BasePool` 置为 `closed`；`KeyPool.running` 仍为 `true`、`pool.size == 0`。于是 `get` 的 `if (pool.size < totalSize && pool.keyedSize(key) < maxSize)` 恒成立 → `tryAddTask` → `creationLoop` 调 `creator(k)` 建对象 → `pool.add` 返回 `false`（池已 closed）→ `keyedDestroy` 立刻销毁 → `break` → `wakeWaiters()` → `get` 醒来再走一遍，直到 `remain <= 0`
- **描述**：`KeyPool` 是 `public` 类型，`remove(key)` 也是 `public`；`K = Unit` 时用户写 `remove(())` 是自然用法（`UnitKeyPool` 的注释也只说「`get` 一直返回 `None`」）。实际后果比「返回 None」重得多：每次 `get` 都会**以 creator 的速度持续创建并销毁资源**（典型 creator 是建连/开文件/分配缓冲），默认持续 30 秒，然后打一条 `key pool exhausted` 的 WARN 并返回 `None`；下一次 `get` 再来 30 秒。对数据库/网络连接池就是一次连接风暴 + 满核 CPU，且没有任何「池已废」的快速失败路径
- **建议**：让 `UnitKeyPool` 也维护一个 `closed` 标志（或在 `IKeyPool` 增加 `isDead()`），`KeyPool.get` 在 `tryAddTask` 之前先判「底层池已关」立即返回 `None`；`KeyPool.remove` 对 `Unit` 键应同时把 `running` 置 `false`（语义上单键池的 remove 就是关闭），并在文档/README 里写清这一点

### [一般][存量] checker / taskPusher 抛异常时只结清 deque 自己的 `s`，上层 `BaseKeyPool` 的全局 `s` 不减 ⇒ `pool.size` 虚高、后续 `get` 可能连续 30s 取不到

- **位置**：`f_pool/src/base/collection/SyncDeque.cj:171-183`（`checkedBeforeReturn` 的 catch）、`216-220`（`remove` 的 catch）、`330-336`（`check` 里 `n.check` 抛异常时 `rm` 不返回）↔ `f_pool/src/BaseKeyPool.cj:70-79`（`keyedChecker` 只在 `false` 分支 `s.fetchSub`）、`97-98`（`p.check(...) |> s.fetchSub` 只在正常返回时执行）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失 / 失败路径当成功」、§12.1「可见性 / 计数一致性」；违反 README「内部实现」段自己写的不变量 `s ≡ Σ 各队列 size`
- **证据**：静态确定 —— 三条异常路径都只调 `discardItem`（结清 deque 的 `s`/`out`），而上层的 `s` 依赖 `keyedChecker` 返回 `false` 或 `p.check` 正常返回。异常越过这两点时，全局 `s` 比实际多 1（每次一个池项），随后 `pool.size < totalSize` 可能恒假 → 不再派发创建任务 → `get` 等满 `maxWaiting` 返回 `None`
- **描述**：受影响的是 `K ≠ Unit` 的多键池（`UnitKeyPool` 的 `size` 直接读 deque，不会漂移）。触发条件是应用提供的 `checker` 抛异常（连接已断时校验里做 I/O 很常见）；`BaseKeyPool.audit()` 下一轮巡检会把 `s.store(total)` 校正回来，所以在巡检开启时是「最长一个巡检周期的性能/可用性塌陷 + 一次 `checkSize` 不一致」；`checkInterval <= 0`/`Duration.Max`（明确支持的「不巡检」配置）时会一直漂到进程重启
- **建议**：把「结清」放进 `discardItem` 的上层钩子（例如让 `SyncDeque` 的 checker 包装器用 `try/finally` 记一次「本项已判失效」，由 `BaseKeyPool` 在异常路径统一 `s.fetchSub(1)`），或让 `BaseKeyPool.check/get/giveBack` 统一 `catch` → `s.fetchSub(1)` → `rethrow`；补一条用例：checker 抛异常后断言 `pool.size == 实际可取数`

### [一般][存量] `SyncDeque.check` 的 `checkers.fetchAdd(1)` 在 `try` 之外：`prevForChecking()` 一旦抛异常，`checkers` 永久 +1，自愈从此完全失效

- **位置**：`f_pool/src/base/collection/SyncDeque.cj:319-321`（`checkers.fetchAdd(1)` + `head.tail.prevForChecking()`）↔ `339-348`（`finally` 里 `checkers.fetchSub(1)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称（异常跳过释放）」、§12.1「失败后状态不可恢复」；`reconcileIfWedge` 的前置条件见 `SyncDeque.cj:256-258`
- **证据**：静态确定（结构）—— `checkers.fetchAdd(1)`（320）与 `fetchSub(1)`（347）不在同一个 `try` 里，`prevForChecking()`（321）在 `try` 之前；`LinkedNode.cj:32-34/109/142/200` 的 `UnreachableException` 是该调用链上唯一的抛出点
- **描述**：`reconcileIfWedge()` 的判据是「`checkers != 0` ⇒ 认定非 idle 节点是合法中间态，不动手」（`256-258`）。`checkers` 被永久抬高 1 之后，这条自愈路径**再也不会执行**：巡检 `audit()` 也走同一函数（`300-302`），于是「记着有项却一个也取不出来」一旦发生就永久保持——正是 7.2 里花了很大力气兜住的那个症状。触发需要链表结构异常（`prev`/`next` 类型不匹配），概率低，但代价是彻底失去兜底
- **建议**：把 `checkers.fetchAdd(1)` 之后的第一句移进 `try`（`checkers.fetchAdd(1); try { var pending = ...; ... } finally { ... }`），或改成一个 `CheckScope` 式的 `try/finally` 包裹；顺带在 `finally` 里对 `checkers` 做一次 `max(0)` 保护（`if (checkers.load() > 0)` 再减）以便计数被外部写坏时能自愈

### [一般][存量] `PoolDiagnostics` 默认在首次建池时接管进程级 SIGSEGV/SIGABRT，并在处理器里做分配/IO/`exit(134)`；`CRASH_DUMP_ON_FATAL` 是 `const`，注释说的「置 false」用户做不到

- **位置**：`f_pool/src/diagnostics/PoolDiagnostics.cj:60-65`（`public static const CRASH_DUMP_ON_FATAL = true`）、`236-250`（处理器：`snapshot()` 字符串拼接 + `writeDiagnostic` 的 `writeln`/`flush` + `exit(134)`）、`KeyPool.cj:291-294`（每次建池都尝试安装）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「全局副作用」；§12.1「跨线程/进程级共享状态」；POSIX 的 async-signal-safety 约束（信号处理器里不得分配、不得用带锁的 stdio）
- **证据**：静态确定（调用与副作用）+ 待确认（运行时是否真的不触发，见下）—— 处理器体里调用了 `snapshot()`（12 次原子读 + `String` 插值分配）、`writeln`/`flush`（stdio 锁）、`exit()`；`60-62` 的注释让用户「把 `CRASH_DUMP_ON_FATAL` 置 false」，但它是 `const`，只能改库源码重编
- **描述**：任何 `Pool` 的构造都会走到 `installCrashHandler()`，把**宿主进程**已注册的 SIGSEGV/SIGABRT 处理器换成本模块的（`registerSignalHandler` 覆盖语义，`f_base/src/signal.cj:78-89`），随后 `exit(134)` 直接终结进程——崩溃上报、core dump、运行时的 fatal 处理都会被截断。而同一文件 `226-235` 又自述「Cangjie 运行时先接管，本处理器**不会被调用**（2026-10-04 实测）」，即：真出问题时它不会跑，代价（覆盖宿主处理器、信号上下文里跑非异步信号安全代码）却一直存在
- **建议**：默认值改 `false`（或改成 `var` + 配置读取），把这个安装动作降级为显式 API；处理器体只保留 `write(2)` 一段**预分配好的静态字节**（不拼接、不走 `String`/stdio），或在只有运行时接管的前提下删掉该分支，改由 `reportIfChanged` / `installShutdownReport` 承担取证（`233` 已经这么写了）

### [轻微][存量] `BasePool.close` 的「关闭即清空」在 check 在飞 / get 交错时不闭合（当前只靠上层 checker 把项判失效兜底）

- **位置**：`f_pool/src/base/BasePool.cj:96-102`（`close` 只走 `q.check({=> true}, ...)`）、`84-89`（`get` 的 `closed` 检查与 `q.remove` 不同步）↔ `f_pool/src/base/collection/LinkedNode.cj:129-144`（`prevForChecking` 只挑 idle 节点）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」「资源不对称」；§12.1「检查-然后-写入」
- **证据**：静态确定（机制）+ 待确认（仓内是否可达）—— `SyncDeque.check` 跳过 `CHECKING` 节点，`close` 也不会回头再扫一次；`FifoPool.get` 在 `closed.load()` 为 false 之后才 `q.remove`，close 的 `closed.store(true)` 与清空之间没有互斥
- **描述**：两种情况：(a) 巡检线程正持着某个节点做 `checker`（状态 CHECKING），此时 `close` 清空会**跳过**它；巡检线程稍后 `setIdle()` 把项放回一个已关闭的队列，`destroier` 永远不会被调用；(b) `get` 与 `close` 交错时可以从已关闭的池里借出一项（该项在归还时才被销毁）。仓内路径不漏，是因为 `KeyPool` 传给 `check` 的 checker 自己带 `running.load()` 判断、失效时主动 `take()` + `doDestroy`（`KeyPool.cj:434-448`），属于「上层替底座兜底」。任何直接使用 `BasePool` 或 checker 不感知 `running` 的调用方都会漏掉那一项的销毁
- **建议**：`close` 末尾再排空一次（`while (size > 0) { q.check(...) }`，或增加 `drainAll()`：先 `reviveNonIdle()` 再扫），并把「关闭后 `get` 必须返回 None」做成 `SyncDeque` 级别的关闭标志，而不是只靠上层

### [轻微][存量] 告警钩子是静态 `var`，`redirectWarningsTo` 与 `warn/error` 之间无同步；`installDefaultHooks` 与它竞争时可能覆盖应用钩子

- **位置**：`f_pool/src/diagnostics/PoolDiagnostics.cj:139-141`（`protected static var warnHook/errorHook`）、`154-158`（先赋值后 `hooksInstalled.store(true)`）、`161-167`（CAS 成功后再赋值）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护」「可见性：用普通字段当跨线程信号」
- **证据**：静态确定 —— 函数值字段是普通 `var`，写入方（`redirectWarningsTo`，`public`，运行期任意线程可调；`installDefaultHooks`，每次建池调用）与读取方（`warn`/`error`，任意线程）之间没有锁或原子；`hooksInstalled` 的 CAS 只保护「谁先装」，保护不了「赋值顺序」
- **描述**：最坏序列：应用调 `redirectWarningsTo`（赋值完成、尚未 `store(true)`）→ 另一线程建池，`installDefaultHooks` 的 CAS 成功 → 用 f_log 钩子覆盖应用的采集钩子。反过来也可能读到旧的闭包。注释把用法限定在「启动早期」（`145-147`），但 `SyncDeque_test.cj:256-288/297-336` 就在运行期改它，说明运行期改是预期用法之一
- **建议**：`warnHook`/`errorHook` 收进一个不可变 `struct Hooks`，用 `AtomicReference`/原子替换整块发布；`redirectWarningsTo` 先 `store` 再登记「已被接管」，`installDefaultHooks` 用同一个原子做 CAS 后再校验

### [轻微][存量] `reportIfChanged` 首轮必打一条「健康」统计（与「健康时静默」相反），且 check-then-store 会让多个池重复打

- **位置**：`f_pool/src/diagnostics/PoolDiagnostics.cj:182`（`lastReportedSignature = AtomicInt64(-1)`）、`190-198`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与注释不符」（`187/200` 两处注释都写「健康时静默」）、§12.1「检查-然后-写入」
- **证据**：静态确定 —— `anomalySignature()` 初始为 `0`，与 `-1` 不等 ⇒ 第一次 `reportIfChanged`（`KeyPool.cj:464`，第一轮巡检后）必然 `warn("[FOUNTAIN_POOL.diag] pool audit: …")`；`load` 与 `store` 不是原子的，两个池的巡检线程可能同时通过判断
- **描述**：进程启动约一个 `checkInterval`（默认 1 分钟）后必有一条 WARN 级诊断行，容易被值班当成告警；多池部署时同一份统计会被打印多次。同类可观测性小问题：`SyncDeque.cj:85`/`285` 的告警前缀写成 `DEQUE-SELFCHECK]` / `WEDGE-HEAL]`，缺起始 `[`，按 `[...]` 检索会漏
- **建议**：初值改 `0`（或第一次只记录不输出）；用 `compareAndSwap` 代替 `load`+`store`，失败即返回 `false`；补上缺失的 `[`

### [轻微][存量] 退出统计走告警钩子，与本文件「崩溃/退出路径不能碰日志框架」的自述冲突

- **位置**：`f_pool/src/diagnostics/PoolDiagnostics.cj:201-209`（`atExit { reportIfChanged('shutdown') }`）↔ `132-136`/`217-224`（`dump()` 为此固定直写 stderr）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「设计与注释冲突」、§3「静默失效」
- **证据**：静态确定（调用链）—— `reportIfChanged` → `warn` → `warnHook`；`KeyPool` 首次建池就把钩子接到 `LoggerFactory`（`KeyPool.cj:286-288`），而 `f_base/src/signal.cj:45-69` 的 `onExit()` 是在 SIGTERM/SIGINT 处理器里执行 `atExit` 回调
- **描述**：应用没接管钩子时，退出统计会被写进 f_log（队列 + 独立写线程）——正是在信号处理器上下文里；模块自己在 `31-38` 明说此时「日志框架可能死锁或丢行，不能碰」，并因此让 `dump()` 绕过钩子。结果是「最后一次已知状态」在最需要它的退出路径上最可能丢（或卡住退出）
- **建议**：`installShutdownReport` 使用 `dump()`（固定 stderr + flush）而不是 `reportIfChanged`；若还想进 f_log，改成 `try { warn(...) } catch { dump(...) }` 的双通道，并注明退出期只保证 stderr

### [轻微][存量] `UnitKeyPool.keyCount()` 恒为 1（含 `close()` 之后），与 `IKeyPool.keyCount` 的「close 之后必须为 0」契约相反

- **位置**：`f_pool/src/UnitKeyPool.cj:74-77` ↔ `f_pool/src/IKeyPool.cj:38-39`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」；§14.2「文档承诺与实现不一致」
- **证据**：静态确定 —— 接口注释「键表里当前的键数（诊断 / 测试用：`POOL-11` 的观测点，**`close()` 之后必须为 0**）」；实现直接 `return 1`，且自带注释「单键池：键数恒为 1（哪怕是已关闭的池）」
- **描述**：同一份不变量，两种口径。`BaseKeyPool_test` 里大量 `@Assert(pool.keyCount(), 0)` 正是按接口口径写的；若对 `Unit` 池套用同一断言就会失败。`KeyPool.keyCount()` 是 `POOL-11`（键表不许从 close 之后长回来）的观测点，口径分叉会让该观测对 `Pool<V>` 完全失真
- **建议**：`UnitKeyPool` 记录自身是否已 `close`/`remove`，关闭后返回 0；或把接口注释改成「多键池返回键数、单键池恒为 1」，并同步 README

### [轻微][存量] `FifoPool.add` 缺「入队后再查一次 closed」的第二道检查（`giveBack` 有），关停交错时新项会留在死队列里永不销毁

- **位置**：`f_pool/src/base/BasePool.cj:64-70`（`add`：检查 → 入队 → 返回 true）↔ `71-83`（`giveBack`：入队后再查一次并排空）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「检查-然后-写入」「资源不对称」；§12.1
- **证据**：静态确定（窗口存在）+ 待确认（仓内可达性）—— 仓内唯一的 `add` 调用点在 `KeyPool.cj:557-559` 的 `synchronized(admission)` 内，而 `close()` 的 `running` CAS 也在这把锁里（`601`），因此窗口被外部锁堵住；`BaseKeyPool.add` 自身没有这道锁（`BaseKeyPool_test` 直接调用它）
- **描述**：`add` 在 `closed.load()` 为 false 之后、`q.insertTail` 之前被 close 抢到，项就被插进一个已经清空过的队列：`get` 不会再取（`closed` 为 true），`close` 也不会再扫，`destroier` 永不执行。四个 `*Pool` 实现都是这个形状，`giveBack` 的「第二道检查 + 排空」正是对同一窗口的补丁，`add` 漏了
- **建议**：`add` 照抄 `giveBack` 的第二段（入队后 `if (closed.load()) { while (let Some(_) <- q.remove({_=>false}, destroier)) {} }`，并把「没进去」如实返回 `false`）；或把 closed 判定与入队都放进 deque 的同一临界区（`SyncDeque.addIfOpen(value): Bool`）

### [轻微][存量] 死代码与「用 `open` + `throw` 代替 `abstract`」的静默失效风险（`LinkedNode`）

- **位置**：`f_pool/src/base/collection/LinkedNode.cj:24`（`VALUE_NODE_INVALIDATED`）、`273-277`（`prop busy`）、`278-282`（`prop invalidated`）、`289-291`（`setInvalidated`）、`26-53`（`Node` 的 6 个 `protected open` 成员，全部 `throw UnreachableException()`）、`225`（不可达的 `sleep(Duration.Zero)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「无调用者」「不可达语句」「恒真恒假分支」；§3「接口默认空实现，实现类忘记覆盖」
- **证据**：静态确定 —— `grep -rn "invalidated\|setInvalidated\|VALUE_NODE_INVALIDATED" f_pool/src` 只命中定义处；`grep -rn "\.busy" f_pool/src` 为 0（`setBusy` 有调用，getter 没有）；`Node<T>` 的 6 个成员没有任何**多态**调用点（`head.insertNext`、`tail.insertPrev`、`x.nextForGet`、`x.prevForChecking`、`ValueNode.prev/next` 全部是具体类型上的静态分派），因此基类实现永不执行；`208-228` 的 `synchronized` 块两条分支分别是 `continue` 与 `return`，块后的 `sleep(Duration.Zero)`（225）不可达
- **描述**：`Node` 本应是抽象层，却用「`open` + 抛 `UnreachableException`」当默认实现：将来新增一个 `Node` 子类若忘了覆盖 `insertPrev`/`insertNext`，编译期不报错，运行时才在链表操作里抛 `UnreachableException`（而 `check` 路径上的 `UnreachableException` 还会顺带触发发现 #3 的 `checkers` 泄漏）。`invalidated`/`busy` 三件套是重构残留，读代码的人会以为存在「作废状态」这一状态机分支
- **建议**：`Node` 的成员改成 `abstract`（或直接删掉 `Node` 这层，`?Node<T>` 换成 `?ValueNode<T>`）；删掉 `invalidated`/`busy` 与 `VALUE_NODE_INVALIDATED`；删掉 225 行的 `sleep`

### [轻微][存量] 重复逻辑：四个 `BasePool` 实现逐行对应（180 行），`SyncDeque` 内两两重复，`UnitKeyPool.remove` 与 `close` 同体

- **位置**：`f_pool/src/base/BasePool.cj:60-251`（`FifoPool` / `LifoPool` / `WeakFifoPool` / `WeakLifoPool`）、`f_pool/src/base/collection/SyncDeque.cj:123-166`（`insertHead`/`insertTail`、`prepend`/`append`）、`f_pool/src/UnitKeyPool.cj:53-59`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名」「换控制流」「字面量复制」
- **证据**：静态确定 —— 四个结构体的 `add`/`giveBack`/`get`/`check`/`audit`/`close`/`size` 逐行一致，差异只有两处：deque 类型（`SyncDeque` / `WeakSyncDeque`）与入队/出队方法（`insertTail`+`append` / `insertHead`+`prepend`）；`SyncDeque.insertHead` 与 `insertTail` 只差 `head.insertNext` / `head.tail.insertPrev`，`prepend` 与 `append` 同理；`UnitKeyPool.remove` 与 `close` 函数体完全相同
- **描述**：这不是「为可读性展开」——四份实现里每一份都包含 `closed` 标志、二次检查排空、异常吞掉的销毁记账这些容易改漏的逻辑。发现 #10（`add` 缺二次检查）就是必须同步改四处的典型：现状是四处一致地漏
- **建议**：`BasePool` 抽成一个 `struct PoolCore<T, D>`（语义参数只有「deque 类型」与「头插/尾插」两个），四个别名只保留构造差异；`UnitKeyPool.remove` 直接委托 `close`（`remove(_, fn) { close(fn) }`）以消掉同体复制

### [轻微][存量] 弱引用池的值类型路径：`Box<T>` 只被 `WeakRef` 持有 ⇒ 池项可被任意一次 GC 回收，且销毁绕过 `destroier`

- **位置**：`f_pool/src/base/collection/SyncDeque.cj:375-380`（`ref(value)`：`WeakRef<Object>(Box<T>(x), DEFERRED)`）→ `f_pool/src/base/BasePool.cj:158-204`（`WeakFifoPool`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称」；§12.1「弱引用/生命周期」；mem §4.3「`WeakRef` 不是淘汰策略」
- **证据**：静态确定 —— `Box<T>(x)` 是 `ref()` 里的临时对象，除了 `WeakRef` 之外没有任何强引用；`refDestroier` 只在「弱引用仍能解析」时调 `destroier`，被 GC 回收后 `check` 只会 `discardItem`（no-op 销毁）
- **描述**：值类型池项（`WeakFifoPool<Int64>` 之类）入池后随时可能消失，且消失时**不会**调用 `destroier`——对持有句柄的池项等于漏 close。仓库里 `Mode.WeakFifo/WeakLifo` 目前无调用方（README `9-10` 已注明），`.autocode/bugs/bug-pool-archived-20261006.md` 的 `POOL-L9` 也登记过；属潜伏问题，一旦有人按「弱引用池可以自动回收」去用就会踩到
- **建议**：值类型路径改为「`Box<T>` 由池侧强持有、只对引用类型用 `WeakRef`」，或在 `Mode` 文档/README 里明确「Weak 模式只支持引用类型池项，且不保证 `destroier` 被调用」

### [轻微][存量] 测试自身的问题：钩子用例把全局告警通道换成不 flush 的写法且无恢复 API，`pool_test` 的销毁回调直接 `println`

- **位置**：`f_pool/src/base/collection/SyncDeque_test.cj:256-288`、`297-336`（两次 `redirectWarningsTo` 收尾都用 `getStdErr().writeln` 但**不 flush**，与默认钩子 `PoolDiagnostics.cj:132-136` 的行为不同）、`244-254`（依赖全局计数变化的快照断言）、`f_pool/src/pool_test.cj:21-26`（`Test.destroy()` 里 `println('destroy …')`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §10「可测试性 / 可维护性」；§3「标准输出占用」（模块自述「库不占应用的数据通道」）
- **证据**：静态确定 —— `SyncDeque_test` 的「收尾」只是换回一个**相似**的闭包，`hooksInstalled` 仍为 true，默认 flush 行为再也回不去；`297-336` 的用例在钩子里 `spawn` 另一线程并用 400ms 墙钟等锁，慢机上会把「钩子没占锁」误判成失败；`pool_test.Test.destroy` 无条件打印
- **描述**：这些不影响产品代码，但会让 `cjpm test` 的输出混入 `destroy …` 行、让后续用例的告警可能滞留在 stderr 缓冲里，以及让一个并发用例带墙钟依赖。`pool_test` 的类名 `Test` 与 `@Test` 宏同名，读起来也容易误判
- **建议**：给 `PoolDiagnostics` 增加 `resetDefaultHooks()`（或用 `installDefaultHooks` 暴露为 internal 测试入口），用例收尾改调它；`297-336` 改成用 `Condition`/`Future` 同步而不是 400ms 轮询；`pool_test` 的 `Test` 改名（如 `PoolTestItem`）并去掉 `println`

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

> 均无改前/改后对照数据，一律按「待验证假设」处理，不进 `todo.md` / `tasks.md`。

### [CPU] `Pool<V>` 每次 `get`/`giveBack` 都新建两个转接闭包（`UnitKeyPool.keyedChecker/keyedDestroier`）

- **现状**：`Pool<V>` 走 `KeyPool<Unit, V>` → `UnitKeyPool`，每次 `get`/`giveBack` 都在 `UnitKeyPool.cj:32-37` 现造 `{v => checker(eternity, v)}` / `{v => destroier(eternity, v)}` 两个闭包（捕获 `eternity` + 入参），`giveBack` 另外还有 `KeyPool.ref()` 的 `Ref` + 捕获 `key` 的闭包（`KeyPool.cj:580-582`）。模块自己已经为同类问题留过微基准：`KeyPool.cj:237-246` 注释「现场取方法值 39 ns + 45 B vs 复用 15 ns + 0 B」
- **方案**：让 `IKeyPool` 的 `get/giveBack` 接受「已适配的 `(V) -> Bool` / `(V) -> Unit`」（`KeyPool` 在构造期就知道键恒为 `()`，可以把 `eternity` 折进它缓存的那两个方法值，`checkOnBorrowFn` / `checkOnReturnFn`）；`UnitKeyPool` 侧按「入参函数值引用相等则复用上次的适配闭包」缓存一份即可，无需改接口
- **预期**：每次借还少 2 次闭包分配（约 90 B）。按 10 万 QPS 的编码路径推算约 9 MB/s 的分配量下降（**推算，未测**）
- **代价**：`UnitKeyPool` 增加两个缓存字段；若调用方每次传不同的 checker，缓存命中率为 0（此时退化为现状，无副作用）
- **验证**：`cjpm bench -O2` 跑 `KeyPool_test.cj:1050` 的 `KeyPoolBench`（单线程 get/giveBack）与 `Pool` 版本各 5 轮取中位数/P95；`cjprof record` 看 `UnitKeyPool.<init>`/闭包分配的采样占比
- **证据状态**：`无基线（待验证，仅有 KeyPool.cj:237-246 的 closureshape 微基准）`

### [CPU] `SyncDeque` 每次操作在锁外写两次原子（`lastOp.store` + `opCount.fetchAdd`），只为诊断

- **现状**：`insertHead/insertTail/prepend/append/remove/check` 六个入口各做一次 `lastOp.store(n)`（`SyncDeque.cj:124/134/144/156/199/318`）与一次 `opCount.fetchAdd(1)`（`72-75`，用于每 1e4 次触发 `selfCheck`）。这两次 RMW 都在临界区之外、且与随后必然要拿的 `head.globalLock` 保护的同一批状态无关；多核下它们落在同一个 cache line 上，是与 `s`/`out`/`nodes` 同类的争用点
- **方案**：把 `lastOp` 改成锁内普通字段（只在 `selfCheck`/`reconcileIfWedge` 的告警文案里用，允许粗粒度）；`opCount` 改成锁内普通 `Int64`（或仅在 `selfCheck` 采样开关打开时才原子自增）
- **预期**：每次借还少 2 次全局原子 RMW；高并发下减少一点 cache line 乒乓（**推算，未测**）
- **代价**：`selfCheck` 的采样计数在并发下可能少计（诊断精度换 CPU）；`selfCheck` 本身仍在锁内读 3 个原子，保持不变
- **验证**：32 线程 × 1024 池项的 get/giveBack 压测，`cjpm bench -O2` 改前/改后对照吞吐与 P99（各 5 轮）；`cjprof` 看 `Atomic*` 的自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单创建线程使池填充吞吐上限 = 1/creator 延迟；`maxSize = 1024` 的启动填充是串行 1024 次 creator | `KeyPool.cj:500-579` | 填充总耗时、creator 单次延迟分布 | `creator` 注入固定 `sleep`，测 `initSize` 从 0→1024 的耗时；`cjprof record` 看创建线程 CPU 占比 |
| 2 | `wakeWaiters()` 的 `notifyAll` 在高并发下形成惊群，唤醒次数 O(W²) | `KeyPool.cj:473-481`、`576` | 每秒唤醒次数、等待者重试次数 | 在 `wakeWaiters` / `waitItem` 加计数埋点，32/128 线程压测 `get`/`giveBack` 10 分钟 |
| 3 | 巡检每轮对每个 key 执行一次 `sleep(Duration.Zero)` 让出，key 多时单轮耗时被拖长、`minSize` 补足滞后 | `BaseKeyPool.cj:92-105`、`KeyPool.cj:450-453` | key 数 vs 单轮耗时曲线 | 用 `KeyPool<String,_>` 建 1k/1w/10w 个 key，测两次 audit 之间的间隔分布 |
| 4 | `LocalBufferCache` 的额度泄漏阈值（默认 512 个线程生命周期）在真实线程池缩容场景下会触发 | `BytesListOutputStream.cj:29-76` | 线程创建/销毁速率、`pool.size` 长期趋势 | 持续 `spawn` 短任务各借还一次缓冲，每 100 个线程打印 `pool.size`，看是否单调上升到 `maxSize` |
| 5 | `ChainedBytesCopyTo.asBytes` 的 `Array<Byte>(n)` 会随帧长线性抬高峰值 RSS（且失败路径白付） | `BytesCopier.cj:142-162` | `declaredSize` 实际上限、失败命中率 | 用 1KB/64KB/1MB 帧各跑 10k 次，对比 `getUsedHeapSize()` 峰值；统计 `asBytes` 返回 `None` 的比例 |
| 6 | `ArrayPool` 默认无上限导致「峰值并发数」变成常驻池项数 | `ArrayPool.cj:25-32` | 峰值并发借出数、空闲 10 分钟后的 `pool.size` | 10k 并发借还后退回空闲，观察 `PoolDiagnostics.snapshot()` 的 size 是否回落 |
| 7 | 每次 `giveBack` 的 `Ref` + 闭包分配在编码热路径上占 GC 分配量的一成以上 | `KeyPool.cj:580-582`、`807` | 分配采样、GC 次数 | `cjprof record` 跑 `f_codec` 编码 100 万条小消息，看 `Ref.<init>` / 闭包分配的占比 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `SyncDeque.head.globalLock` 是 `Pool<V>` 借还的唯一串行点（单 deque），高并发下是吞吐上限 | `SyncDeque.cj:37`、`123-166`、`198-235` | 锁等待时长、BLOCKED 线程数、吞吐随线程数的曲线 | 8/32/128 线程压同一个 `Pool<Object>`（maxSize=1024），跑 10 分钟；`cjprof` 取线程状态，另加 `Mutex` 等待计时埋点 |
| 2 | 巡检每轮遍历全部池项、每节点一次 `sleep(Duration.Zero)`，大池单轮耗时被拉长 | `SyncDeque.cj:317-350` | 单轮 `pool.check` 耗时 vs 池项数 | 建 1k/1w/1e5 项的池，量两次 `audit` 之间的实际间隔与单轮耗时（`MonoTime` 埋点） |
| 3 | `ValueNode.prevForChecking` 在 `synchronized(globalLock)` 内 `sleep(Duration.Zero)`，会在锁内让出，形成锁持有尖刺 | `LinkedNode.cj:216-224` | 该分支命中率与锁持有时间分布 | 构造「队尾节点非 idle」的场景（`strandHeadForTest`）压测，量 `get` 的 P99 与锁等待 |
| 4 | `UnitKeyPool` 每次借还的两个闭包分配在 f_codec 编码热路径上占 GC 分配量一成以上 | `UnitKeyPool.cj:32-37`、`KeyPool.cj:580-582` | 分配采样占比、GC 次数 | `cjprof record` 跑编码 100 万条小消息，看闭包/`Ref` 分配占比（同第 1 部分假设 7，这里是 `Pool<V>` 路径的对应项） |
| 5 | `FifoPool.close` 在 1e5 项量级上的关闭耗时被「每节点一次 yield」主导 | `BasePool.cj:96-102`、`SyncDeque.cj:337` | 关闭耗时 vs 池项数 | 先灌满 1e5 个 8KB 缓冲再 `close()`，分段计时；对照去掉 `sleep` 的临时构建 |
| 6 | `selfCheck` 每 1e4 次操作在锁内读 3 个原子 + 一次 `%` 运算，在多核下可观测 | `SyncDeque.cj:72-91` | 自检触发的单次耗时与占比 | `cjprof` 看 `selfCheck` 自耗时；把采样间隔从 1e4 调到 1e6 做对照 |

## 文件覆盖

> 与 `files/f_pool.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_pool/README.md` | .md | ✅ | — |
| 2 | `f_pool/README_en.md` | .md | ✅ | — |
| 3 | `f_pool/src/ArrayListPool.cj` | .cj | ✅ | — |
| 4 | `f_pool/src/ArrayPool.cj` | .cj | ✅ | — |
| 5 | `f_pool/src/BaseKeyPool.cj` | .cj | ✅ | — |
| 6 | `f_pool/src/BaseKeyPool_test.cj` | .cj | ✅ | — |
| 7 | `f_pool/src/BytesCopier.cj` | .cj | ✅ | — |
| 8 | `f_pool/src/BytesListOutputStream.cj` | .cj | ✅ | — |
| 9 | `f_pool/src/IKeyPool.cj` | .cj | ✅ | — |
| 10 | `f_pool/src/KeyPool.cj` | .cj | ✅ | — |
| 11 | `f_pool/src/KeyPool_test.cj` | .cj | ✅ | — |
| 12 | `f_pool/src/Mode.cj` | .cj | ✅ | — |
| 13 | `f_pool/src/PoolLifecycle_test.cj` | .cj | ✅ | — |
| 14 | `f_pool/src/Ref.cj` | .cj | ✅ | — |
| 15 | `f_pool/src/UnitKeyPool.cj` | .cj | ✅ | — |
| 16 | `f_pool/src/base/BasePool.cj` | .cj | ✅ | — |
| 17 | `f_pool/src/base/collection/LinkedNode.cj` | .cj | ✅ | — |
| 18 | `f_pool/src/base/collection/SyncDeque.cj` | .cj | ✅ | — |
| 19 | `f_pool/src/base/collection/SyncDeque_test.cj` | .cj | ✅ | — |
| 20 | `f_pool/src/base/logger.cj` | .cj | ✅ | — |
| 21 | `f_pool/src/byteslist_clear_test.cj` | .cj | ✅ | — |
| 22 | `f_pool/src/diagnostics/PoolDiagnostics.cj` | .cj | ✅ | — |
| 23 | `f_pool/src/exception/ClearFailedException.cj` | .cj | ✅ | — |
| 24 | `f_pool/src/exception/PoolException.cj` | .cj | ✅ | — |
| 25 | `f_pool/src/exception/UnknownKeyException.cj` | .cj | ✅ | — |
| 26 | `f_pool/src/imports.cj` | .cj | ✅ | — |
| 27 | `f_pool/src/local_buffer_cache_test.cj` | .cj | ✅ | — |
| 28 | `f_pool/src/pool.cj` | .cj | ✅ | — |
| 29 | `f_pool/src/pool_concurrency_test.cj` | .cj | ✅ | — |
| 30 | `f_pool/src/pool_test.cj` | .cj | ✅ | — |
| 31 | `f_pool/src/releasable_test.cj` | .cj | ✅ | — |

合计：`.cj` 29 个 / `.md` 2 个 / 共 31 个，全部读完。

## 覆盖自检

### 第 1 部分

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

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 #1/#2/#3/#10，设计 #4（进程级副作用）/#5（契约不闭合）；语言特性上核对了 `struct` 持有引用字段的复制语义（`FifoPool`/`SyncDeque` 全字段为引用或原子，复制不产生状态分叉）、`??` 的短路求值（`PoolBuilder.build` 不会误抛）、`AtomicBool.compareAndSwap` 参数顺序；无外部输入拼接、无凭据、无注入面 |
| §1 死代码 | 2 | `VALUE_NODE_INVALIDATED` / `prop invalidated` / `setInvalidated` / `prop busy` 全仓零引用；`LinkedNode.cj:225` 的 `sleep` 不可达（#11）。逐个核过：`DEQUE_OP_NAMES`、`opCount`、`lastOp`、`refChecker`/`refDestroier`、`strandHeadForTest`、`PoolDiagnostics` 的 12 个计数钩子均有调用方；`Node` 的 6 个基类成员无多态调用点（合并进 #11）；`UnitKeyPool`/`SyncDeque`/`WeakSyncDeque` 的 `public` 成员均为接口实现或包内被调用，不判死代码 |
| §2 重复逻辑 | 1 | 同文件内把 30 余个函数体压成「输入 → 输出 → 副作用」两两比对：`BasePool` 四份实现逐行对应、`SyncDeque` 两对入队/归还方法、`UnitKeyPool.remove`/`close` 同体（#12）；`PoolDiagnostics.onItemAdded` 等在 `insertHead`/`insertTail` 各出现一次属必要（两个入口） |
| §3 空实现 | 1 | `Node` 用 `open` + `throw UnreachableException` 充当抽象默认实现（#11）；`ObjectManager.clear` 默认空体有 README 说明（Null Object，不算问题）；Windows 版 `installCrashHandler`/`uninstallCrashHandler` 空体有 `@When` + 注释说明；`close`/`check` 传空 `taskPusher` 是关停语义，非空实现 |
| §4 栈溢出 | 0 | 逐个追过：`HeadNode.nextForGet` → `ValueNode.nextForGet`（循环）、`TailNode.prevForChecking` → `ValueNode.prevForChecking`（循环），递归深度恒为 1；`Node` 无自引用遍历；`doRemove`/`reviveNonIdle`/`countNodes` 均为迭代；`InitKeyIterator` 是计数器 |
| §5 OOM | 0 | 无「按不可信长度预分配」：`ArrayBlockingQueue` 容量已夹在 `[1, 1024]`（`KeyPool.cj:32-43`）；`SyncDeque` 节点数受 `maxSize`/`totalSize` 限；`BaseKeyPool.close` 的键快照与 `map` 同阶（不是新增无界容器）；键表的无界性由文档明确交给应用 `remove(key)` 管理，本轮不计为缺陷 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；锁竞争、巡检遍历、闭包分配、原子写全部降级为「待验证假设」1-6 |
| §6.2 大粒度锁 | 0 | 逐处核对临界区：`head.globalLock` 内只有链表指针改写 + `s/out/nodes` 原子、`countNodes` 遍历与 `doRemove`；`checker` / `destroier` / 告警钩子全部在锁外（`SyncDeque_test.cj:297-336` 有用例证明），不存在「锁内 I/O / 回调」；`prevForChecking` 里有一次锁内 `sleep` 已单列为假设 3 |
| §6.3 并发串行 | 0 | 线索两条：`Pool<V>` 只有一个 deque（借还串行化）、每个 `KeyPool` 只有 1 个创建线程。无并行度/串行段占比数据，按铁律只进「待验证假设」1 |
| §6.4 低效算法 | 0 | 无 `remove(at: 0)` 当队列（`LocalBufferCache` 是尾部删除 O(1)）、无嵌套循环匹配、无循环内字符串拼接；`reconcileIfWedge` 的 O(n) 实走只在「取不到项」/每分钟一次，`selfCheck` 已降为 O(1)；巡检每节点一次 yield 已单列为假设 2 |
| §7 降堆内存方案 | 0 | 本部分没有可量化的常驻/峰值削减项：节点数受 `maxSize` 限、`ValueNode` 的 3 个原子容器相对 8KB 池项可忽略、`BaseKeyPool.close` 的键快照是瞬时的；唯一候选（`entries()` 每次分配 1 元素数组）量级太小，不列方案 |
| §8 降 CPU 方案 | 2 | 方案 1（`UnitKeyPool` 每次借还两个闭包）、方案 2（`SyncDeque` 锁外两次原子写）；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 候选都不满足「函数内创建、函数内释放」：`countNodes` 的元组是返回值、`reconcileIfWedge` 的 `healed` 字符串进告警、`UnitKeyPool.entries()` 的数组逃逸为返回值、`snapshot()` 的字符串作为返回值；且这些都不在热点分配路径，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 8 | #1（remove 后空转）、#2（异常路径计数漂移）、#3（`checkers` 泄漏）、#4（close 契约）、#5（close/check 交错）、#9（keyCount 契约）、#10（add 竞态窗口）、#13（弱引用值类型）；另核对了 `SyncDeque` 的 `s ≡ nodes + out` 六条路径、`markReturned` 的钳位（全部调用点都在同一把锁内，无竞态）、`ValueNode.check` 的异常还原、`Pool` 侧 `FifoPool.size` 含借出项的语义，均无缺陷 |
| §12 并发安全与锁粒度 | 4 | 已证明安全：`closed`/`s`/`out`/`nodes`/`opCount`/`lastOp`/`checkers` 全为原子且复合更新都在 `head.globalLock` 内；`reconcileIfWedge` 的「无 check 在飞」判据与 `check` 的 `checkers` 协议自洽（除 #3）。命中：#2（计数一致性）、#3（自愈被永久关闭）、#6（钩子可见性）、#7（报告去重竞态）；锁粒度见 §6.2 结论 |
| §14 功能完备性与 README 覆盖 | 1 | `PoolDiagnostics` 的公开面（`snapshot`/`dump`/`redirectWarningsTo`/`installCrashHandler`/`uninstallCrashHandler`/`CRASH_DUMP_ON_FATAL`）README `345-350` 已列；但 README 未提示「首次建池即**默认安装**进程级致命信号处理器、会覆盖宿主处理器」这一副作用，也没有「`CRASH_DUMP_ON_FATAL` 是 const、无法配置」的说明（#4）。README 本体属第 1 部分文件，其余文档一致性问题以第 1 部分为准 |
| 文件覆盖（§13 等） | 17/17 | 本部分无 `.md`（README 两版在第 1 部分）；17 个 `.cj` 全部读完 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 10 |
| 轻微 | 18 |
| 其中存量 | 29 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：代码的并发底座（纪元号 + 条件变量、记账自愈、`take()` 所有权转移）想得比一般池库细，注释里带着失败案例编号，可读性不差；**主要风险集中在「异常/关停路径」和「没有生命周期的池」两处**：

- 阻塞项（建议先修）：#1 —— `giveBack` 的未知键路径会通过 `Ref` 终结器销毁调用方仍持有的对象，这直接违背它对外的书面契约，而且现有用例因为只查「抛出瞬间的计数」而漏掉了它。这一条应是 1.3.x 的必修项。
- 排期项：#2 / #3 / #4 都是同一主题——池的生命周期不闭环（`ArrayPool`/`ArrayListPool` 不能关、构造失败无线程回收、线程本地缓冲不回池）。单看每处都只是「一点泄漏」，合起来就是「运行越久越借不到编码缓冲、进程退出前线程数只增不减」，对长跑服务是实打实的可用性风险。
- 文档：#7 是唯一会把人带偏的段落（巡检判据写反），跟 #11 一起改，成本极低。
- 性能与内存：本部分所有收益判断都没有改前/改后数据（无 `cjprof` / `cjpm bench` 基线），按铁律全部落在「待验证假设」，不进修复清单；其中「单创建线程 + 全广播唤醒」和「`ArrayPool` 默认无上限」最值得下一轮补数据。
- 已确认**没有**的问题：栈溢出（§4）、大粒度锁与锁内回调（§6.2）、死锁（§12）、local mode（§9 对象均逃逸）。

存量缺陷共 15 条（严重 1 / 一般 6 / 轻微 8），是否纳入修复待用户决定；本报告只读代码，未做任何修改。

**第 2 部分**：本部分是全模块的「底座」：`SyncDeque` 的记账不变量（`s ≡ 节点数 + 借出数`）、异常安全（checker/destroier/taskPusher 三条抛出路径都要么还原状态要么结清）、以及「告警钩子绝不在锁内调用」这三件事做得比一般池库细，注释里带着失败案例编号，`SyncDeque_test` 有 22 个用例专门盯这些历史症状。主要问题集中在**底座与上层之间的计数/关闭协议**，不在链表本身：

- 值得排期的三条 一般：#1（`KeyPool<Unit,V>.remove(())` 之后 `get` 以 creator 速度空转 30s，公开 API 可达）、#2（checker 抛异常时上层 `s` 只靠巡检自愈）、#3（`checkers` 一次异常泄漏就永久关掉自愈）。#1 是唯一会让业务侧直接看到「连接风暴 + 30s 超时」的路径，#2/#3 属于「异常之后的可用性塌陷」，都不是崩溃级，但会让池在最需要兜底的时候失去兜底。
- #4（默认接管 SIGSEGV/SIGABRT 且在信号上下文里分配/IO/`exit`）更像一个「收益自述为零、副作用一直在」的开关：既然文件自己写了实测不会触发，默认值应改为 false。
- 轻微项里 #10（`add` 缺二次检查）与 #4（`close` 跳过 CHECKING 节点）是同一个主题：`BasePool` 的关闭语义只在「上层 checker 恰好把项判失效」时才完整。它们现在不可达，但只要有人直接使用 `BasePool`（它是 `protected package` 里的公共实现层，`BaseKeyPool_test` 就在直接调 `add`）就会漏 `destroier`。
- 死代码与重复逻辑都有明确结论：#11 是 `LinkedNode` 的状态机残留 + 一层没有多态调用点的抽象；#12 是四份 `BasePool` 实现（180 行）与两对 `SyncDeque` 方法，改一处必须同步改四处。这两项不改也不出错，但会放大后续任何修复的成本。
- 性能与内存：本部分没有任何 profile / bench 数据，两条 CPU 方案与六条假设全部标 `无基线（待验证）`，不进修复清单。最值得下一轮补数据的是「单 deque 的锁竞争」（假设 1）与「大池巡检/关闭的逐节点 yield」（假设 2、5）。
- 已确认**没有**的问题：栈溢出（§4）、锁内回调与死锁（§6.2）、OOM（§5）、local mode（§9，候选对象全部逃逸）、`s ≡ nodes + out` 的记账路径。

存量缺陷共 14 条（严重 0 / 一般 4 / 轻微 10），是否纳入修复待用户决定；本报告只读代码，未做任何修改。
