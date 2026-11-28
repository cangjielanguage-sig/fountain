# f_cache 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_cache`（10 个 `.cj` + 2 个 `.md`）
- **基线**：工作区快照（当前检出 `sts/1.3.x`，`git status f_cache` 干净，无 diff 可比 ⇒ 全部记为存量）
- **审查重点**：缓存淘汰 / 过期 / 弱引用语义、并发安全与锁粒度、内存边界、死代码、重复逻辑、空实现、存量 BUG
- **报告版本**：v1

## 发现

### [严重][存量] 绝对死亡时间（`dieAt` / `deathTime`）按 `now` 折算成寿命，而一次性条目从 `birth` 起算 ⇒ 已有条目的到期时间被提前「条目年龄」

- **位置**：`f_cache/src/HeapCache.cj:324-327`（`set(key,value,dieAt:)`）、`f_cache/src/HeapCache.cj:284-301`（`prolong(key,deathTime:)` → `prolongDeathAtLocked`）、`f_cache/src/Priority.cj:190-205`（`deathNanos` setter）、`f_cache/src/Priority.cj:206-212`（`deathNanosLocked`）
- **来源**：存量（`git blame`：`HeapCache.cj` 末次改动 `ce64e9534`（2026-10-15），本段逻辑早于该提交；快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符 / 逻辑错误）、§10 正确性
- **证据**：静态确定
- **描述**：
  1. `set(key, value, dieAt:)` 实现为 `set(key, value, life: dieAt - now, once: true)`（`HeapCache.cj:326`）。对**已存在**的条目，`set` 只把 `life` 写进 `maxLife`（`HeapCache.cj:308`），随后 `deathNanosLocked()` 在 `once_ == true` 时以 `birth` 为基准（`Priority.cj:207-211`）⇒ 实际死亡时间 = `birth + (dieAt - now) = dieAt - (now - birth)`，比调用方要求的时间早了「该条目已存活时长」。条目越老，提前越多；存活超过 `dieAt - now` 的条目会**立即过期**，而 `set` 仍返回旧值（成功语义）。
  2. `prolong(key, deathTime:)` 的路径更绕：`prolongDeathAtLocked` 先 `p.load()`（把 `lastUsed` 刷成 `now`），再在 `once_` 仍为 `false` 时写 `p.deathNanos = deathNanos`（setter 用 `lastUsed` 作基准算 `maxLife_`），**之后**才 `p.once = true`（`HeapCache.cj:294-297`）⇒ 生效基准从 `lastUsed` 切到 `birth`，死亡时间同样被扣掉 `now - birth`。
  3. 已有用例只覆盖「新键 + dieAt」（`HeapCache_test.cj:59`）与「过期条目拒绝续期」（`HeapCache_test.cj:310`），没有覆盖「已有条目 + 绝对死亡时间」，所以缺陷未被发现。
- **建议**：为绝对时间语义单独提供入口，别复用相对 `life`：在 `Priority` 增加 `setDeathAt(nanos)`（一次锁内先置 `once_ = true`，再按 `birth` 折 `maxLife_`），`set(dieAt:)` / `prolong(deathTime:)` 一律走它；或改为保存「绝对 `deathNanos`」字段而不是 `maxLife_ + 基准`。补用例：`set('k') → sleep(2×life/3) → set('k', v, dieAt: now+life/2)`，断言 `deathNanos ≈ dieAt`。

### [一般][存量] 段下界的「版本校验 + 写回」是检查-然后-写入，并发 `noteDeathNanos` 的下界会被覆盖，段可能长期不再被扫

- **位置**：`f_cache/src/SyncLinkedHashMap.cj:174-196`（`sweepLocked`，关键在 `191-193`）；写入方 `f_cache/src/SyncLinkedHashMap.cj:150-161`（`noteDeathNanos`）
- **来源**：存量（快照模式无基线；`fd1a2dfe0` 引入增量清扫）
- **判据**：review-checklist §12.1（检查-然后-写入）、§6.2（跨字段不变量需锁）
- **证据**：静态确定
- **描述**：`noteDeathNanos` 只做原子 CAS（**不取段锁**），而 `sweepLocked` 用 `if (deathVer.load() == ver0) { minDeath.store(st.minDeath) }` 保护「重算写回」。`load()` 与 `store()` 之间没有原子性：
  - 线程 T（清扫）读到 `deathVer == ver0`，尚未 `store`；
  - 线程 W（业务 `set`）把 `minDeath` 从 `Int64.Max` 降到 `now+100ms` 并 `deathVer.fetchAdd(1)`；
  - T 继续执行 `minDeath.store(st.minDeath)`，把 `Int64.Max` 写回去。
  
  结果：该段下界被抬回 `Int64.Max`，但段里已有 `100ms` 后到期的条目。此后只有「再出现一次更小的登记」或 `checkOverSize` 才会清到它；若 `maxSize` 为默认 `Int64.Max`，过期条目会一直留在段里（`get` 仍判过期，但 `size` 虚高、内存不回收）。注释「避免重算覆盖新值」保护的正是这条路径，但保护本身不成立。
- **建议**：把「只降不升」做成 CAS 循环（`cur = minDeath.load(); if (new >= cur) break; CAS(cur, new)`），`sweepLocked` 的重算也走同一 CAS（写回只允许下降），彻底去掉 `deathVer` 这套 check-then-store；或让 `noteDeathNanos` 也在 `mtx` 内执行（代价是 `set` 增加一次段锁）。

### [一般][存量] `ConcHashMap.clear()` 用绝对赋值 `size_.store(0)`，与并发清扫/两阶段删除的相对扣减交错 ⇒ `size` 变负

- **位置**：`f_cache/src/ConcHashMap.cj:370-375`（`clear`）；`f_cache/src/ConcHashMap.cj:340-349`（`sweepExpired` 的 `size_.fetchSub(removed)`）；`f_cache/src/ConcHashMap.cj:319-326`（`removeIf` 同形扣减）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（共享可变状态、组合操作非原子）、§11（记账错误）
- **证据**：静态确定
- **描述**：`sweepExpired` / `removeIf` 先在段锁内删条目、**释放锁后**才 `fetchSub(removed)`；`clear` 在全部段清空后执行 `size_.store(0)`。交错：清扫已删 3 条（尚未扣减）→ `clear()` 清段并把 `size` 置 0 → 清扫 `fetchSub(3)` ⇒ `size = -3`，而表为空。后果：`store.size > maxSize` 恒假 ⇒ **`maxSize` 淘汰长期失效**（要等后续 `set` 逐条加回来才恢复），`HeapCache.size` 对外报负数。`HeapCache.close()` 也走 `store.clear()`（`HeapCache.cj:403`），此处与定时清扫竞争同样可致负值（实例已关闭，影响仅限内部状态）。
- **建议**：`clear` 改成「逐段清空并在同一临界区内按该段实际删除数扣减」，或用「代际（epoch）计数」：`clear` 递增 epoch，清扫记下进入时的 epoch，扣减前校验 epoch 未变；简单做法是让 `clear` 也在每段锁内完成 `size_.fetchSub(实际删除数)`，不要用绝对赋值。

### [一般][存量] 淘汰回调队列无界，消费线程执行用户回调时不设背压 ⇒ 回调变慢/阻塞时队列随淘汰量无界增长

- **位置**：`f_cache/src/HeapCache.cj:38`（`LinkedBlockingQueue` 无容量）、`f_cache/src/HeapCache.cj:173`（`checkTimeout` 入队）、`f_cache/src/HeapCache.cj:206`（`checkOverSize` 入队）、`f_cache/src/HeapCache.cj:97-120`（单消费者）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（无界容器）、§12.1（有界性）、§3（回调异常）
- **证据**：静态确定（结构）+ 待确认（增长速率取决于用户回调耗时）
- **描述**：生产者是定时器线程（每 `checkDuration` 一轮，`maxSize` 超限时一轮可推入大量条目），消费者是单线程且直接调用 `evictionCallback`（用户代码，可能做 I/O）。队列元素是 `Option<(String, V)>`，**强引用 V**：回调阻塞期间，被淘汰的值无法被回收，队列长度 = 待投递条数。单元素约「元组 + String 引用 + V 引用」≈ 48–64 B，10 万条待投递即数 MB 的额外常驻，并让「已淘汰」的值继续活着。
- **建议**：给队列设容量上限并在满时降级（丢弃回调 + 计数告警），或改为「回调在线程池里有界并发投递」；同时在 `HeapCache` 暴露 `evictionQueue.size` 之类的观测项。

### [一般][存量] `once(key)` 有副作用：把条目改成一次性，且可能让它当场过期，与 README「查询」语义不符

- **位置**：`f_cache/src/HeapCache.cj:247-264`（`once` → `onceLocked` 内 `p.once = true`）；文档 `f_cache/README.md:27-31`、`f_cache/README_en.md:27-31`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与命名/文档不符）、§13
- **证据**：静态确定
- **描述**：README 把 `once` 描述为「缓存 KEY 存在且缓存对象是一次性的**返回 true**」，读起来是纯查询；实现无条件 `p.once = true`，把 `deathNanos` 的基准从 `lastUsed` 切到 `birth`（`Priority.cj:206-211`）。对一个靠读续命、存活已超过 `maxLife` 的条目，`once` 会返回 `true` 并让它**立刻过期**（下一次 `get` 返回 `None`）。与 `get`/`contains` 的「同口径」承诺（README:160）叠加后行为很难预期。
- **建议**：二选一——① 改为纯查询（`return p.once`，不改状态）；② 保留副作用但改名/补文档，并在切换前按 `birth` 重新判定：若 `birth + maxLife <= now` 直接返回 `false` 并删除，不要返回 `true`。

### [一般][存量] 淘汰比较器不满足传递性，`PriorityQueue` 的最优序不确定，可能淘汰刚被用过的条目

- **位置**：`f_cache/src/Priority.cj:86-118`（`orderOf`，第一层 `ageSub` 的 ±1 容差带）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10 正确性（比较器契约：堆排序要求严格弱序）、§11
- **证据**：静态确定
- **描述**：`|ageSub| <= 1` 时改用「本周期使用次数」等 tie-break，`|ageSub| > 1` 时直接按年龄定序。构造反例：`a(age=0, refDelta=1)`、`b(age=0.5, refDelta=2)`、`c(age=1.2, refDelta=3)`（均 `checkDuration` 归一后）：
  - `a` vs `b`：`ageSub=-0.5` 在带内 → 按 `refDelta` ⇒ `a < b`；
  - `b` vs `c`：`ageSub=-0.7` 在带内 → 按 `refDelta` ⇒ `b < c`；
  - `a` vs `c`：`ageSub=-1.2` 超带 ⇒ `a > c`。
  
  即 `a < b < c` 而 `a > c`。在 `PriorityQueue`（最小堆）里，比较不满足传递性会使 sift 结果依赖插入顺序，`checkOverSize` 取出的「最小值」不保证是最该淘汰的条目，可能出现「刚被大量访问的条目先被淘汰」。不会崩溃，但「保护新生 / 用量优先」的承诺只在两两比较层面成立。
- **建议**：把年龄容差带做成可传递的键（例如先量化成桶 `floor(age)` 再比桶序，桶内用 tie-break），或直接去掉 ±1 带、只用 `age → refDelta → lastUsed → ref → birth` 的字典序；补一条「三条目全序」用例（现只有两两比较用例）。

### [一般][存量] `WeakHeapCache.getOrCompute` 的用户 `fn()` 在 `entryView` 回调内执行（桶锁内），与 `HeapCache` 明确「callable 在锁外」的做法不一致

- **位置**：`f_cache/src/WeakHeapCache.cj:110-122`；同类问题 `f_cache/src/WeakHeapCache.cj:144-154`（`removeIf` 的谓词在 `cache.removeIf` 回调内）
- **来源**：存量（快照模式无基线；本项目 `bug-cache` 归档记录也指出 `entryView` 回调内不得再调用 `entryView`/`remove`/`replace`）
- **判据**：review-checklist §6.2（锁内调用外部回调）、§12.1（锁内回调 → 死锁）、§3（一致性）
- **证据**：待确认 —— 需以本地 std 文档核对 `std.collection.concurrent.ConcurrentHashMap.entryView` / `removeIf` 是否在桶锁内回调
- **描述**：`HeapCache` 为把 `callable` 移出段锁专门做了 `computeIfAbsentCounted`（`SyncLinkedHashMap.cj:67-81`，注释明写「callable 在段写锁之外执行」），并在 README:148 承诺；`WeakHeapCache` 仍把 `fn()` 放在 `entryView { entry => ... fn() ... }` 里。若 std 语义确为「回调持桶锁」（std 文档明确禁止回调内并发调用 `entryView`/`remove`/`replace`，说明锁是持有的），则：慢 `fn`（正则编译、远程调用）会阻塞该桶的全部读写；`fn` 内回访同一个缓存（哪怕另一个 key 落到同一桶）会自锁。README 对 `WeakHeapCache` 没有任何相关约束说明。
- **建议**：与 `HeapCache` 对齐成「锁内查、锁外算、锁内二次判定写入」（可接受重复计算后丢弃）；若保留 `entryView`，至少在 README 补「`fn`/谓词在该键所在桶的锁内执行，不得回访本缓存、不得阻塞」。

### [一般][存量] 在淘汰回调里调用 `close()` 会 `f.get()` 等自己 ⇒ 挂死

- **位置**：`f_cache/src/HeapCache.cj:394-416`（`close`，`f.get()` 在 `404-414`）；回调执行点 `f_cache/src/HeapCache.cj:126-132`（`notifyEviction`）与 `97-120`（消费线程）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（`synchronized` 内 `spawn(...).get()` 的同源自等待）、§6.2（锁内/线程内调用外部回调）
- **证据**：待确认 —— 需确认 `Future.get()` 在「等待自己的 Future」时是死锁还是抛异常
- **描述**：`evictionCallback` 是公开构造参数，在内部消费线程上执行。若回调里调用 `cache.close()`：`close` 先 `f.cancel()`，再向队列投哨兵，然后 `f.get()` —— 而 `f` 就是**当前正在执行回调的这个线程**，永远无法结束。README 只写了「close 可重复调用」，没有「不得在回调内 close」的约束。
- **建议**：`close` 内记录消费线程标识（或 `Future` 所属线程），检测到自调用时跳过 `f.get()`；README 增加「回调运行在内部线程上，不得在回调内 `close()`，也不得阻塞过久」。

### [一般][存量] 定时器回调无异常兜底：任一次 tick 抛异常，清扫与 `maxSize` 淘汰永久停止且无日志

- **位置**：`f_cache/src/HeapCache.cj:141-156`（`startTimer`，回调体 `146-155`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（静默失效）、§11（错误处理缺失）
- **证据**：待确认 —— 需核对 `Timer.after` 对「任务抛异常」的处理（是否还会按返回值重排）；无论是否重排，异常都无日志
- **描述**：重排依赖回调返回 `Some(checkDuration)`；`checkTimeout` / `checkOverSize` 中任何未捕获异常（例如 `PriorityQueue` 内部异常、`DateTime` 相关异常、OOM 之外的运行期错误）都会让本轮 tick 直接失败。失败后：过期条目不再清扫、超 `maxSize` 不再淘汰，`size` 持续增长，而外部完全无感知（没有日志、没有状态位）。对比：消费线程对用户回调做了显式 `try/catch`（`HeapCache.cj:127-131`），定时路径没有对应保护。
- **建议**：把回调体包进 `try { ... } catch (e) { logger.error(...); Some(checkDuration) }`，异常时仍返回 `Some(checkDuration)` 保活；同时暴露「最近一次清扫失败次数」观测项。

### [一般][存量] `WeakHeapCache` 无容量上限、键为强引用、且无 `atExit` 自动关闭：唯一 key 数决定内存，遗忘 `close()` 时实例与线程永久驻留

- **位置**：`f_cache/src/WeakHeapCache.cj:42-58`（`cache` + `init` 内 `spawn`），`f_cache/src/WeakHeapCache.cj:24-41`（`WeakKey` 强引用 `String`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（无界容器 / 缓存键无界 / 长期持有）、§12.1（有界性）
- **证据**：静态确定（结构）+ 待确认（量级取决于调用方 key 基数）
- **描述**：清扫线程只摘「值已被 GC」的条目（`WeakHeapCache.cj:54`），只要值还被外部强引用，条目就一直在；`WeakHeapCache` 没有 `maxSize`、没有 TTL、没有 LRU 采样（与 `HeapCache` 不同）。单条约 `WeakKey(String 引用 + 对象头)` + `WeakRef` + `ConcurrentHashMap` 节点 ≈ 80 B 量级，**唯一 key 数 N 无上界** ⇒ 1M 个长寿命值即约 80 MB 的纯索引开销，且 `size` 只增不减。另外：`HeapCache` 在构造时注册了 `ExitCallbacks.atExit`（弱引用，`HeapCache.cj:62-65`），`WeakHeapCache` 没有；而它的清扫线程强引用 `this`，所以忘记 `close()` 的实例连同全部条目不会被回收（线程直到进程退出）。
- **建议**：补一个可选的 `maxSize`（超限时按插入序/访问序淘汰，或直接复用 `HeapCache` 的采样淘汰）；与 `HeapCache` 一致注册弱引用 `atExit`；README 明确「无容量上限，key 基数由调用方控制」。

### [一般][存量] 淘汰回调异常被完全吞掉且不留痕，回调缺陷无法定位

- **位置**：`f_cache/src/HeapCache.cj:121-132`（`notifyEviction`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（`catch (e: Exception) {}` 静默吞异常 → 至少一般）
- **证据**：静态确定
- **描述**：`catch (e: Exception) { () }` 有注释解释「否则消费线程会结束 / `close` 会把异常重抛」，理由成立，但代价是回调里的任何 bug（空指针、序列化失败、下游 5xx）完全不可见——调用方拿不到计数、日志里也没有。故障表现为「回调数量莫名变少」。
- **建议**：保留吞异常（正确），但补一条 `f_log` 错误日志（含 key、异常消息）+ 失败计数；或在 README 写明「异常被吞，需要上报请在回调内自行处理」（现在只在源码注释里）。

### [一般][存量] README 说「键和值都被弱引用包装」，实现是「键强、值弱」，同文件后文又自相矛盾

- **位置**：`f_cache/README.md:105`、`f_cache/README_en.md:105`；实现 `f_cache/src/WeakHeapCache.cj:24-41`；同文件后文 `f_cache/README.md:151`、`f_cache/README_en.md:151`
- **来源**：存量（快照模式无基线；`WeakKey` 改强引用是 2026-10-05 的修复，README 首段未同步）
- **判据**：review-checklist §13（文档与实现相反 → 一般）
- **证据**：静态确定
- **描述**：第 105 行「内部维持的键和值被弱引用包装」与 `WeakKey` 的 `private let key: String`（强引用）相反；第 151 行又写「键强、值弱」。读者按首段理解会以为「key 不占内存、条目会因 key 消失而消失」，实际是「key 常驻、条目数由唯一 key 数决定」（见上一条 OOM 条目）。英文版同样问题。
- **建议**：把 105 行改成「键为强引用、值被弱引用包装」，与 151 行统一。

### [轻微][存量] 死代码：`ConcHashMapValues` / `ConcHashMapValuesIterator` 全仓零引用，且 `clear()` 的语义有陷阱

- **位置**：`f_cache/src/ConcHashMap.cj:87-100`（`ConcHashMapValuesIterator`）、`f_cache/src/ConcHashMap.cj:102-137`（`ConcHashMapValues`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（`internal` 顶层声明在本包及子包内无引用 → 死代码）
- **证据**：静态确定 —— 全仓搜 `ConcHashMapValues` 只命中定义处；`ConcHashMap` 没有 `values` 成员，测试也没用到
- **描述**：两个类都没有任何调用者（`ConcHashMapKeys` 至少被 `ConcHashMap_test.cj:29` 用到，这一对连测试都不用）。且 `ConcHashMapValues.clear()`（`ConcHashMap.cj:134-136`）实现为 `map.clear()` —— 名字是「清空 Values 视图」，实际会清空整个 map，一旦被人拿去用就是数据丢失。
- **建议**：直接删除这两个类（或与 `ConcHashMapKeys` 一起删除，见下一条）；若保留，`clear()` 应删除或改名。

### [轻微][存量] 死代码：`ConcHashMap` / `SyncLinkedHashMap` 里四个内部 API 与两个属性无任何调用者

- **位置**：`f_cache/src/ConcHashMap.cj:191-204`（`create(map:concurrencyLevel:)`）、`f_cache/src/ConcHashMap.cj:310-314`（`removeAll`）、`f_cache/src/ConcHashMap.cj:355-365`（`removeIfLocked`）、`f_cache/src/SyncLinkedHashMap.cj:129-135`（`size`）、`f_cache/src/SyncLinkedHashMap.cj:136-140`（`isEmpty`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（`internal` 类里的 `public` 成员按「全项目无使用」判）
- **证据**：静态确定 —— 逐个全仓搜索：`create(map` 只在定义处；`removeAll` 只在定义处；`removeIfLocked` 在 `ConcHashMap` 侧只剩注释 `HeapCache.cj:160` 提到，`SyncLinkedHashMap.removeIfLocked` 仅被 `HeapCache_test.cj:672` 使用；`segment.size` / `segment.isEmpty` 无命中
- **描述**：`ConcHashMap.removeIfLocked` 是增量清扫改造前的残留（`removeIfLocked` → `sweepLocked`），保留它还要求「谓词不得回调本缓存」这条隐性契约，容易误用；`SyncLinkedHashMap.size`/`isEmpty` 需要取段锁却没人用。`create(map:)` 是带初始内容的构造入口，同样无人使用。
- **建议**：删除 `removeAll`、`ConcHashMap.removeIfLocked`、`create(map:)`、`SyncLinkedHashMap.size`/`isEmpty`；`SyncLinkedHashMap.removeIfLocked` 若只服务测试，改 `private` 并把用例移到同文件（或经 `ConcHashMap` 间接覆盖）。

### [轻微][存量] 重复逻辑：`onceLocked` / `prolongLocked` / `prolongDeathAtLocked` 是同一形状的三份实现

- **位置**：`f_cache/src/HeapCache.cj:255-264`、`f_cache/src/HeapCache.cj:273-283`、`f_cache/src/HeapCache.cj:291-301`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（输入-输出-副作用相同、语法不同）
- **证据**：静态确定 —— 三者摘要都是「锁内 `load()` → 改 `maxLife/once/deathNanos` → 回读 `deathNanos` → 锁外 `noteDeath` → 返回 true」
- **描述**：三份实现的差异只有「改哪几个字段」，但都重复了「必须先 `load()` 刷新 `lastUsed`」「必须回读 `deathNanos` 登记下界」这两条不变量；严重 #1 正是这三份实现里「字段写入顺序 / 基准切换」理解不一致造成的。合并后只需在一处保证顺序。
- **建议**：抽 `private func updateEntry(key, p, mutate: (Priority<V>) -> Int64): Bool`（`mutate` 在 `p.lock` 内执行并返回新的 `deathNanos`），三处调用点只传字段变更闭包；`mutate` 的契约写成「先改 `once`、再算死亡时间」。

### [轻微][存量] 重复逻辑：同一套过期判定散落三处

- **位置**：`f_cache/src/HeapCache.cj:225-227`（`expired`）、`f_cache/src/Priority.cj:239-249`（`loadIfAlive`）、`f_cache/src/Priority.cj:254-259`（`aliveAndDeathNanos`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（同一业务规则多处实现 → 行为漂移风险）
- **证据**：静态确定 —— 三处都是 `now >= base + maxLife`，`base` 按 `once` 取 `birth`/`lastUsed`，但各自重新算一遍 `DateTime.now()` 与基准
- **描述**：目前三者口径一致（都用 `>=`），但「`once` 决定基准」这条规则被复制了三遍：`expired` 在 HeapCache 侧、另两处在 Priority 侧。改一处漏两处的风险实际已经发生过一次（见严重 #1 的基准切换问题）。
- **建议**：只保留 `Priority` 内的一个判定入口（`isAlive(now)`），`HeapCache.expired` 改成调用它；`loadIfAlive` 与 `aliveAndDeathNanos` 共享同一私有函数，差异只在是否 `incr`。

### [轻微][存量] 重复逻辑：`ConcHashMapKeys` 与 `ConcHashMapValues` 的迭代器、以及两套「全部包含」实现

- **位置**：`f_cache/src/ConcHashMap.cj:22-35` vs `f_cache/src/ConcHashMap.cj:87-100`（只差取 `k` 还是取 `v`）；`f_cache/src/ConcHashMap.cj:75-84`（`ConcHashMapKeys.contains(all:)`）vs `f_cache/src/ConcHashMap.cj:246-255`（`ConcHashMap.containsAll`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名 / 换控制流）
- **证据**：静态确定 —— 两个迭代器的 `next()` 逐行对齐，只有 `Some(k)`/`Some(v)` 不同；两处 `containsAll` 都是「逐个 `contains`，全部命中才 true」（一处 `for + early return`，一处 `cont &&=`）
- **描述**：`ConcHashMapKeys.contains(all:)` 与 `ConcHashMap.containsAll` 是同一语义的两个入口，语义漂移曾经发生过（`bug-cache` 记录 `CACHE-L1` 把「任一命中」写成了 `true`，就是因为同一规则有两份实现、只改了一份的近邻代码）。
- **建议**：`ConcHashMapKeys.contains(all:)` 直接委托 `map.containsAll(all)`；两个视图迭代器用一个泛型 `MapViewIterator<K, V, R>`（或删除 `Values` 那一对，见死代码条目）。

### [轻微][存量] 依赖与导入冗余：`cjpm.toml` 声明了未使用的 `f_exception`，`WeakHeapCache.cj` 有未使用导入

- **位置**：`f_cache/cjpm.toml:2-5`（`fountain::f_exception`）、`f_cache/src/WeakHeapCache.cj:22`（`import fountain::f_collection.*`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（未使用 `import`）、§14.1（依赖漂移 / 冗余依赖）
- **证据**：静态确定 —— `grep -rn "f_exception" f_cache/src` 零命中；`WeakHeapCache.cj` 只用到 `ArrayList`、`ConcurrentHashMap`、`AtomicBool`、`std.ref.*`、`spawn/sleep/Thread/Duration`，`f_collection` 无任何符号使用
- **描述**：冗余依赖会被 `cjpm` 拉进链接图，增加构建时间与制品依赖面；未使用导入是编译警告来源（历史上 `CACHE-L4` 就是这类警告）。
- **建议**：删掉 `f_exception` 依赖与 `fountain::f_collection.*` 导入；若担心将来使用，等真用到再加。

### [轻微][存量] 用例质量：多处断言与 `sleep` 紧耦合，且有一条恒真断言

- **位置**：`f_cache/src/HeapCache_test.cj:36`（`@Assert(cache.get('test1')?.value, cache.get('test1')?.value)`）；`HeapCache_test.cj:54-63`（100 ms 寿命 + 300 ms sleep）、`HeapCache_test.cj:320-331`（100 ms tick / 100 ms 寿命 + 800 ms sleep）、`HeapCache_test.cj:569-585`（`maxSize=1` 下断言回调恰好 1 次）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10 可维护性 / 测试有效性
- **证据**：静态确定
- **描述**：`HeapCache_test.cj:36` 左右两侧是同一个表达式，断言恒真（无覆盖价值）。其余用例把「寿命 / 清扫周期 / 等待时间」压到同一数量级（100 ms vs 100/300/800 ms），在 CI 负载高或 `-O0` 下会出现「还没到点就断言」或「多删了一条」的假失败；这类失败会被误判为产品缺陷。
- **建议**：删掉恒真断言；把时间参数放大到 ≥ 5× 余量（或注入可控时钟）；`evictionCallback` 用例改为断言「包含 a、且不包含 b」而不是「恰好 1 次」。

### [轻微][存量] README 的公开 API 清单有误，`WeakHeapCache` 声明块漏 `Resource` 成员

- **位置**：`f_cache/README.md:169-170`（「其他公开 API」）、`f_cache/README.md:107-141`（`WeakHeapCache` 声明块）；英文版同位置 `README_en.md:168-170`、`README_en.md:107-141`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（API 与源码不符）、§14.2（公开 API 未文档化）
- **证据**：静态确定 —— `public func hashCode(): Int64` 实际是 `private struct WeakKey` 的成员（`WeakHeapCache.cj:32-34`），不是模块级公开函数；`WeakHeapCache` 实现 `Resource`，有公开的 `close()`/`isClosed()`（`WeakHeapCache.cj:69-88`），声明块里没有，只在正文 151/159 行提到
- **描述**：按 169 行去找「模块级 `hashCode`」的读者会找不到；只看 107-141 行声明块的人会以为 `WeakHeapCache` 没有 `close()`，从而漏掉必须释放的线程。
- **建议**：删掉 `public func hashCode(): Int64` 这一项；`WeakHeapCache` 声明块补 `<: Resource`、`close()`、`isClosed()`（`threadHandles` 是 internal，不必写）。

### [轻微][存量] README 的 `HeapCache` 声明块漏了 `Resource` 继承

- **位置**：`f_cache/README.md:6`、`f_cache/README_en.md:6`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13
- **证据**：静态确定 —— 源码是 `public class HeapCache<V> <: Resource`（`HeapCache.cj:26`），README 写成 `public class HeapCache<V> where V <: Object`
- **描述**：声明块本身列了 `close()`/`isClosed()` 并注明「Resource 接口」，但类型声明没写继承关系，容易让人以为 `Resource` 只是注释里的说法。
- **建议**：改成 `public class HeapCache<V> <: Resource where V <: Object`。

### [轻微][存量] 可见性建议：`Priority` 仅模块内部使用却声明为 `public open`；测试专用成员是 internal

- **位置**：`f_cache/src/Priority.cj:49`（`public open class Priority`）、`HeapCache.cj:94`/`134`（`segmentCount`/`threadHandles`）、`ConcHashMap.cj:37`/`102`（两个视图类）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1 硬原则一（对外可达的 `public` 不判死代码，但可提可见性建议）
- **证据**：静态确定 —— `Priority` 未出现在任何 `public` 签名里（`HeapCache` 的 `store` 是 `private`），仓内只在 `f_cache` 内使用；`segmentCount`/`threadHandles` 只被 `HeapCache_test.cj` 调用
- **描述**：`Priority` 是 `public open`，导致 `birthNanos`、`lastUsedNanos`、`age`、`maxLife` getter、`compare`、`incr` 这 6 个零引用成员按规则不能判死代码，成为永久维护面；同时它也没有公开构造入口（`protected init`），外部只能继承，实际没有对外价值。`segmentCount`/`threadHandles`/`ConcHashMapKeys` 是「测试专用 internal」，不算死代码，但也不该长期占公开面。
- **建议**：`Priority` 收为 `internal`（若确定没有下游子类），零引用成员随之一并可删；测试专用成员用 `@TestOnly` 注解或移到测试可见的辅助类型。**删除对外可达 API 属契约变更，需用户拍板**，本条只作建议，不计入缺陷。

### [轻微][存量] 两处并发实现细节：快照字段无锁写、`close()` 的「检查-然后-置位」

- **位置**：`f_cache/src/Priority.cj:62-64` / `131-145`（`snap`、`snapReady` 在 `lock` 外赋值，`compareSnapshot` 无锁读）；`f_cache/src/HeapCache.cj:394-398`（`if (closedFlag.load()) return; closedFlag.store(true)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（可见性 / 检查-然后-写入）
- **证据**：静态确定（结构）—— 当前唯一写入者是定时器线程（`checkOverSize` 单线程），因此不构成现实竞争
- **描述**：`snapshot()` 里 `snap = lockSnap(current); snapReady = true` 在 `synchronized(lock)` 之外执行，`compareSnapshot` 也无锁读这两个字段；只要将来有人从业务线程调 `snapshot`/`compareSnapshot`（它们是 `protected`，`Priority` 又是 `public open`，外部子类可以调），就是数据竞争。`close()` 的两个线程并发调用时都会通过 `load()` 检查并执行完整清理（`store.clear()` 两遍、哨兵投两枚），行为恰好幂等所以无害，但依赖的是巧合。
- **建议**：`snapshot` 的赋值放进 `synchronized(lock)`（代价是一次锁内写，只在淘汰轮发生）；`close` 改成 `if (closedFlag.compareAndSwap(false, true))` 早退。

## 优化可行性方案

### [堆内存] 把淘汰比较快照 `PrioritySnap` 从条目上挪到「堆内候选」

- **现状**：`Priority` 每条目内联 `snap`（6 × 8 B = 48 B）+ `snapReady`（1 B + 对齐），随条目常驻（`Priority.cj:62-64`），但只在 `checkOverSize` 的那一轮里被读写（`HeapCache.cj:196`、`Priority.cj:132-145`）。10 万条目 ≈ 4.8–5 MB 常驻，随 `maxSize` 线性增长；README:155 也把「字段瘦身」当作已做过的一轮优化。
- **方案**：删除 `Priority.snap` / `snapReady`，在 `checkOverSize` 里为「进堆候选」建一个旁路对象（`class Cand { p: Priority, snap: PrioritySnap }`）或直接把 `PrioritySnap` 作为 `PriorityQueue` 元素，堆内比较只读旁路对象；每轮候选数 ≤ 段数 + 弹出数，峰值对象数远小于条目数。
- **预期**：常驻内存降 48–56 B × 条目数（100k 条目约 5 MB，占 `Priority` 条目本身约 15–20%）。
- **代价**：`compareSnapshot` 从 `Priority` 移到旁路对象，`Priority` 的 `protected` 扩展点减少（对下游子类有影响）；每轮多一次小对象分配。
- **验证**：100k 条目稳态下 `getUsedHeapSize()` / RSS 对照，`-O2`，同输入；同时跑淘汰用例确认淘汰顺序不变。
- **证据状态**：无基线（待验证，不进 tasks）

### [堆内存] `ExitCallbacks` 注册项只增不注销，按实例数线性累积

- **现状**：每个 `HeapCache` 构造都在 `f_base` 的全局 `TreeMap<UInt16, ArrayList<() -> Unit>>` 里追加一个闭包（`HeapCache.cj:64-65`，`f_base/src/signal.cj:48-59`），`f_base` 没有注销 API，`close()` 也不移除。闭包 + `WeakRef` + 列表槽位 ≈ 64–96 B / 实例，永不释放；`WeakRef` 只保证「实例可被回收」，不保证「槽位可被回收」。
- **方案**：`f_base` 增加 `removeAtExit(handle)`（返回句柄），`HeapCache.close()` 里注销；或在 `onExit` 遍历时顺带压缩「`WeakRef` 已失效」的项。
- **预期**：实例数 N 时回收 N × ~80 B，并把 `onExit` 的遍历成本从「历史实例总数」降到「存活实例数」。
- **代价**：`f_base` 公共 API 变更（需跨模块评审）；`ArrayList` 删除是 O(n)，只在 `close()` 路径付出。
- **验证**：循环创建/关闭 10k 个 `HeapCache`，观察 `getUsedHeapSize()` 与 `onExit` 耗时是否随 N 线性增长。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `getOrCompute` 命中路径每次都分配 `DeathNote`

- **现状**：三个 `getOrCompute` 重载每次调用都 `let note = DeathNote()`（`HeapCache.cj:344`、`357`），命中也照分配，随后 `noteDeath(key, Int64.Max)` 直接短路（`SyncLinkedHashMap.cj:150-154`）。这是缓存命中主路径上的一次多余分配 + 一次 `hashCode` + 一次段定位。
- **方案**：先 `store.get(key)` 命中就直接 `load()` 返回（与 `get` 同路径），未命中才走 `computeIfAbsent` + 登记；命中路径零分配。
- **预期**：命中路径少 1 次分配、少 1 次段查找、少 1 次 `noteDeath` 调用。具体降幅需实测。
- **代价**：未命中路径多一次 `get`（本来 `computeIfAbsent` 内部也做一次 `get`，可把它改成「内部 `get` 后直接计算」以抵消）；需保证「命中即返回」与「并发第一次写入」的语义不变（允许并发重复计算，与现状一致）。
- **验证**：`HeapCache_bench.cj` 的 `benchGetHit` 改造前后对照（`cjpm bench -O2`，中位数 + 离散度）；`f_orm`/`f_regex` 的真实命中负载复核。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] 淘汰消费线程 100 ms 空轮询，每实例 10 次/秒唤醒

- **现状**：`q.remove(EVICTION_POLL_INTERVAL)`（`HeapCache.cj:103`，常量 `36` 行）每 100 ms 超时返回一次，用来检查取消；没有淘汰事件时也照醒。每实例 10 wakeups/s；仓库里 `f_data`、`f_orm`、`f_regex` 各持一个静态 `HeapCache` ⇒ 30 wakeups/s 的纯空转，外加每次唤醒的锁/条件变量开销。
- **方案**：① 改为阻塞 `take()`，取消时用 `f.cancel()` 的中断/哨兵退出（`close()` 已投哨兵，`catch` 掉中断即可），去掉轮询；② 或让「无 `evictionCallback`（默认空回调）的实例」根本不启动消费线程——目前 `HeapCache` 无论是否传回调都固定起 1 个线程（`HeapCache.cj:145` → `97-120`）。
- **预期**：空闲态 wakeups 从 10/s/实例 降到 0；省 1 个常驻线程/实例（默认回调场景）。
- **代价**：① 依赖 `LinkedBlockingQueue.take()` 被取消打断的行为（需核对 std 文档）；② 需把「是否传了回调」区分出来（默认值无法与显式空回调区分，需额外开关或 `Option`）。
- **验证**：空闲 8 小时采 `cgroup` CPU 时间与线程数；负载下 `benchSetUnderEvictionPressure` 对照，确认回调不丢。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `removeIf` 的「锁内快照」是 O(段大小) 的分配与遍历

- **现状**：`removeIfOutside` 在段锁内 `for (entry in map) copy.add(entry)`（`SyncLinkedHashMap.cj:102-109`），段内 1024 条时是一次 1024 元素的 `ArrayList` 增长 + 整段遍历，全程持锁；README:149 的「谓词不会阻塞同段读写」只对谓词成立，快照本身仍然阻塞。
- **方案**：快照改为「分批」：锁内只取前 K 条（如 128）→ 锁外判定 → 锁内删除 → 继续下一批；或直接改成「锁内遍历、只记录 key，谓词在锁外按 key 复查」（复查时再取一次锁），把锁内工作量从 O(n) 降到 O(批)。
- **预期**：同段读写的最长阻塞从 O(段大小) 降到 O(批大小)；`removeIf` 的内存峰值从整段副本降到批大小。
- **代价**：语义仍为弱一致（两阶段之间写入可能被误删），但「可能被误删的窗口」变大；需要补并发用例。
- **验证**：单段 10 万条 + 另一线程 `get` 的 P99 延迟对照（改前/改后，`-O2`，同输入）。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `get` 每次算两次 `hashCode`（`segment(key)` 一次 + `LinkedHashMap.get` 一次）是命中路径的可观开销 | `ConcHashMap.cj:213-215`、`SyncLinkedHashMap.cj:45-49` | 自耗时占比 | `cjprof record` 跑 1M 次 `get`（单段 / 16 段各一组） |
| 2 | 热点 key 集中到同一段时，单段 `Mutex` 成为并发上限 | `SyncLinkedHashMap.cj:33` | 锁等待时长、BLOCKED 线程数 | 4/8 线程压同一段 key，采线程状态与 P99 |
| 3 | `removeIf` 锁内快照在「大段 + 高频 removeIf」下阻塞同段读 | `SyncLinkedHashMap.cj:102-128` | 同段 `get` P99、段大小 | 单段 10 万条 + 每秒 1 次 `removeIf`，另一线程测 `get` |
| 4 | 空闲态 100 ms 轮询的 CPU 成本 | `HeapCache.cj:36,103` | 空闲 CPU 时间/实例 | 建 10 个空闲 `HeapCache`，8 小时采 `cgroup` CPU 时间 |
| 5 | `Timer.after` 任务抛异常后是否还会按返回值重排 | `HeapCache.cj:146-155` | std 文档 / 观测 | 注入一次必抛异常的 tick（临时探针，不入库），观察后续是否继续清理 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_cache/src/ConcHashMap.cj` | .cj | ✅ | 见 §1 死代码（轻微 #1/#2/#5）、一般 #2（clear 与 size 扣减竞争） |
| 2 | `f_cache/src/ConcHashMap_test.cj` | .cj | ✅ | 覆盖 contains(all:)/size 记账，断言口径正确 |
| 3 | `f_cache/src/HeapCache.cj` | .cj | ✅ | 见 严重 #1、一般 #3/#4/#7/#8/#10、轻微 #3/#11 |
| 4 | `f_cache/src/HeapCacheBuilder.cj` | .cj | ✅ | 参数校验完整；`build()` 为 open 扩展点 |
| 5 | `f_cache/src/HeapCache_bench.cj` | .cj | ✅ | 4 个 `@Bench`，键空间有界；无实测结果产出 |
| 6 | `f_cache/src/HeapCache_test.cj` | .cj | ✅ | 27 条用例；见轻微 #7（sleep 紧耦合、自比较断言） |
| 7 | `f_cache/src/Priority.cj` | .cj | ✅ | 见 严重 #1、一般 #5（比较器）、轻微 #4/#11 |
| 8 | `f_cache/src/SyncLinkedHashMap.cj` | .cj | ✅ | 见 一般 #1、轻微 #2（size/isEmpty 无引用） |
| 9 | `f_cache/src/WeakHeapCache.cj` | .cj | ✅ | 见 一般 #6/#9、轻微 #6（未使用导入） |
| 10 | `f_cache/src/WeakHeapCache_test.cj` | .cj | ✅ | 4 条语义用例，与实现一致 |
| 11 | `f_cache/README.md` | .md | ✅ | 见 一般 #11、轻微 #8/#9 |
| 12 | `f_cache/README_en.md` | .md | ✅ | 与中文版同步（同样含 #11、#8 的问题） |

（另读了 `f_cache/cjpm.toml`：`fountain::f_exception` 依赖在 `src/` 内零引用，见轻微 #6。）

合计：`.cj` 10 个 / `.md` 2 个 / 共 12 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性见 严重 #1、一般 #4/#5；设计见 一般 #6（两套「锁外计算」策略不一致）；语言特性上 `Option` 均被显式处理、`Mutex` 可重入用法正确（同线程嵌套 `synchronized(p.lock)` 有 `set`/`once` 路径作证）；安全性无外部输入拼接、无硬编码凭据 |
| §1 死代码 | 3 | 逐符号全仓搜过：`ConcHashMapValues`/`ConcHashMapValuesIterator` 零引用；`ConcHashMap.create(map:concurrencyLevel:)`、`removeAll`、`removeIfLocked` 零引用；`SyncLinkedHashMap.size`/`isEmpty` 零引用。`Priority.birthNanos`/`lastUsedNanos`/`age`/`maxLife` getter 亦零引用，但 `Priority` 是 `public open class`，按硬原则一豁免，改列为可见性建议（轻微 #10）。`segmentCount`/`threadHandles`/`ConcHashMapKeys` 仅测试引用，列可见性建议 |
| §2 重复逻辑 | 3 | 逐文件把全部函数体压成「输入 → 输出 → 副作用」摘要后两两比对：`onceLocked`/`prolongLocked`/`prolongDeathAtLocked` 同形；过期判定散落 `HeapCache.expired`/`Priority.loadIfAlive`/`Priority.aliveAndDeathNanos` 三处；`ConcHashMapKeysIterator` 与 `ConcHashMapValuesIterator` 只差取值、`ConcHashMapKeys.contains(all:)` 与 `ConcHashMap.containsAll` 同语义两实现 |
| §3 空实现 | 1 | 无 `TODO`/`FIXME`/`UnsupportedException`；默认 `evictionCallback` 为有意 no-op（有注释）；`notifyEviction` 的 `catch {}` 计入一般 #10；两处 `close()` 的 `catch` 是保护性兜底并有注释，不另计 |
| §4 栈溢出 | 0 | 全模块无递归：`Priority.compare`/`orderOf` 单层、`ConcHashMapIterator` 是循环翻段、`checkOverSize` 是显式 while + 堆，无自引用结构 |
| §5 OOM | 2 | 一般 #4（无界淘汰队列 + 强引用值）、一般 #9（弱引用缓存无容量上限）；`maxSize` 超限有淘汰路径，`evictionQueue` 是唯一无背压的容器 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 结果；`HeapCache_bench.cj` 只有基准入口没有数据，热点结论不成立，已列待验证假设 #1–#4 |
| §6.2 大粒度锁 | 0 | 段锁临界区内只有哈希表读写 + 入队；`removeIf` 的 O(段) 快照与 `WeakHeapCache` 的锁内回调计入优化方案/一般 #6（缺持有时长数据，不定为热点） |
| §6.3 并发串行 | 0 | 唯一「串行段」是淘汰消费线程（单消费者），其输入是淘汰事件而非请求主路径；`close()` 的 `f.get()` 是收尾等待，不是请求路径 |
| §6.4 低效算法 | 0 | `segmentIterators` O(段数)、堆淘汰 O(n log k)、`removeIf` 两阶段 O(n)（每段一次），未见嵌套扫描或 `remove(at: 0)` 式用法；双 `hashCode` 列待验证假设 #1 |
| §7 降堆内存方案 | 2 | 快照字段外移（约 5 MB/10 万条）、`atExit` 槽位不注销；均无基线 |
| §8 降 CPU 方案 | 3 | `DeathNote` 命中路径分配、100 ms 空轮询（10 次/秒/实例）、`removeIf` 锁内整段快照；均无基线 |
| §9 local mode 可行性 | 0 | 候选只有 `checkOverSize`/`removeIfOutside` 的临时集合，规模 ≤ 段内条目数、生命周期极短，且逃逸到用户谓词；无前后峰值内存数据，收益无法证明 |
| §11 现有代码的 BUG（存量） | 7 | 严重 #1；一般 #1/#2/#4/#5/#7/#10；本轮读到的 10 个 `.cj` 边界与空值（空表、`Option`、`Int64` 饱和、负 `life`、关闭后调用）均已核对，其余无缺陷 |
| §12 并发安全与锁粒度 | 5 | 一般 #1（下界 check-then-store）、#2（clear 与相对扣减）、#4（无界队列）、#6（`entryView` 锁内用户代码）、#7（回调内 close 自等待）；另轻微 #11（快照字段无锁写 + `close` 的 check-then-set）；锁粒度本身合理（段锁保护 LRU 链表 + 哈希表，读也需写锁有实测依据） |
| §14 功能完备性与 README 覆盖 | 1 | public API 与 README 声明块基本逐项对齐；缺口：`WeakHeapCache` 声明块缺 `close`/`isClosed`、`Priority` 只列名字（见轻微 #8）；`HeapCache` 的 `Resource` 继承未出现在声明块（轻微 #9） |
| 文件覆盖（§13 等） | 12/12 | 无缺文件；`cjpm.toml` 一并核对（依赖冗余见轻微 #6） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 11 |
| 轻微 | 11 |
| 优化方案（堆内存 / CPU） | 2 / 3 |

存量缺陷 23 条（严重 1 / 一般 11 / 轻微 11，其中死代码与重复逻辑 5 条、可见性建议 1 条），是否纳入修复待用户决定；本轮无「本次改动」引入的问题（工作区快照，无 diff）。

## 总评

整体质量偏高：分段 + 段内 `Mutex` 的选择有实测依据，`Resource` / `close()` 的协作取消、`Future` 句柄、弱引用 `atExit`、惰性过期与段级下界这套设计都是成熟的工程取舍，README 对并发契约的覆盖度在仓库里属于较好水平，用例也覆盖到了「锁外计算」「关闭后抛异常」「下界重算」这些易错路径。

阻塞项只有一个，但影响面明确：`set(..., dieAt:)` 与 `prolong(..., deathTime:)` 对**已存在**的条目会把绝对死亡时间按 `now` 折算、再按 `birth` 生效，条目越老提前过期越多（严重 #1），而现有用例恰好绕开了这条路径，建议优先修并补用例。

其次是并发记账与清扫下界的两处竞争（一般 #1、#2）：都不崩溃，但会让「过期条目不再被扫」「`size` 变负 ⇒ `maxSize` 淘汰失效」，属于会随时间劣化的隐患，建议与 #1 一起排期。`once()` 的副作用与 README 描述不符（一般 #4）属于契约层问题，改文档或改实现都要尽快定。

其余（无界淘汰队列、`WeakHeapCache` 无上限、回调内 `close()` 自等待、定时器无异常兜底、比较器不满足传递性）建议纳入下一轮；死代码与重复逻辑集中在 `ConcHashMap` 的 `Keys/Values` 视图族和三个 `*Locked` 更新函数上，删除/合并成本低，可随手清理。性能类结论本轮全部没有测量数据，只作为待验证假设与无基线优化方案，不建议进 `todo.md` / `tasks.md`。
