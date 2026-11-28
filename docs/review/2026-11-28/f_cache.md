# f_cache 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_cache`（10 个 `.cj` + 2 个 `.md`，共 12 个文件）
- **基线**：工作区快照（sts/1.3.x，`git status f_cache` 无未提交改动，无 diff 可比 → 全部记「存量」）
- **审查重点**：缓存淘汰与并发安全、大粒度锁、OOM、死代码、重复逻辑、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [严重][存量] 段迭代器停在「已被删除的链表节点」上会自环，淘汰线程可能在 `checkOverSize` 里死循环

- **位置**：`src/SyncLinkedHashMap.cj:205-211`（`SyncLinkedHashMapIterator.next()` 每次 `next` 单独取锁、锁间释放）、`src/SyncLinkedHashMap.cj:42-44`（迭代器在锁外创建）；触发点 `src/HeapCache.cj:210-213`（补位循环反复 `segm.next()`）
- **来源**：存量（`git blame`：迭代器与 `checkOverSize` 均来自 `fd1a2dfe0`/`ba1db1525`，工作区无未提交改动）
- **判据**：review-checklist §12.1（迭代与修改并发）、§6.4（死循环）、§11（并发正确性）
- **证据**：静态确定 —— `f_collection/src/LinkedNode.cj:158-166` 的 `ValueNode.remove()` 在摘链后执行 `this.prev = this; this.next = this`（注释写「help GC」）；而 `f_collection/src/LinkedNode.cj:39-54` 的 `next()` 是 `current = n.next`，且 `case n: ValueNode<T>` 只看当前节点类型、不看节点是否已摘链。于是迭代器一旦停在节点 B 上而 B 被别的线程 `remove`/`removeIf`/过期清扫删掉，下一次 `next()` 返回 B 的值并把 `current` 设成 B 自己，此后每次 `next()` 都返回同一个元素。
- **描述**：`HeapCache` 的定时线程用 `segmItrMap` 保存每段迭代器，`next()` 之间不持锁；同一段上的业务 `remove()`（`HeapCache.cj:368-371`）、`removeIf()`（`376-379`）、`checkTimeout` 的过期清扫（`162-178`，走 `map.removeIf`）任一命中「迭代器当前节点」，该迭代器就变成永不前进。后果分两级：① 只取一个候选时反复拿到同一 key，`store.remove(p.key)` 第二次起返回 `None`、`size` 不再下降；② `HeapCache.cj:201-215` 的内层 `while (store.size > maxSize)` 会「弹出同一候选 → 删除无效 → 再从同一迭代器补同一条」无限循环，定时线程 100% CPU 空转且淘汰永久失效（期间不报错、不退出，`isClosed()` 仍为 false）。`HeapCache.get` 也会 `turnToTail` 摘链再插入（`f_collection/src/LinkedHashMap.cj:96-101`、`LinkedNode.cj:190-215`），虽最终会重链，但同样会让迭代器跳过或重复元素。README 只写了「弱一致」，没有覆盖「自环」这一档。
- **建议**：不要在锁外逐步 `next()` 链表迭代器。二选一：(a) `SyncLinkedHashMap` 提供 `snapshotKeys(): Array<(String, V)>`（锁内一次性拷出，O(段大小)），`checkOverSize` 只在锁内取快照、锁外比较与淘汰；(b) 迭代器记录「上一个返回节点」，若 `current == lastReturned` 或节点 `next` 指向自身则判定失效并结束本段（防御式，但保留了跨调用失效的语义）。同时在 `HeapCache_test` 增加「迭代中并发 remove 同一段所有 key」的压力用例。

### [一般][存量] `prolong(key, deathTime)` 与「已存在键的 `set(key, value, dieAt)`」把绝对死亡时间按 `lastUsed` 折算后切 `once`，实际死亡时间提前「条目年龄」

- **位置**：`src/HeapCache.cj:291-301`（`prolongDeathAtLocked`：`load()` → `deathNanos = X` → `once = true`）、`src/HeapCache.cj:324-327`（`set(..., dieAt)` 转调 `set(life: dieAt - now, once: true)`，命中已存在条目时走 `304-314`）；换算点 `src/Priority.cj:190-205`（`deathNanos` setter 用当前 `once_` 选基准）
- **来源**：存量（`git blame`：`prolong(deathTime)` 与 `Priority.deathNanos` 均早于本轮最近三次提交）
- **判据**：review-checklist §11（契约与实现不符、边界）、§10 正确性
- **证据**：静态确定 —— `Priority.deathNanos` 的 setter 是 `maxLife_ = Duration.nanosecond * (value - (once_ ? birth : lastUsed))`。`prolongDeathAtLocked` 先 `p.load()`（把 `lastUsed` 置为 now），此时 `once_` 仍为 `false` ⇒ `maxLife_ = X - now`；随后 `p.once = true` ⇒ 读取侧 `deathNanosLocked() = birth + maxLife_ = X - (now - birth)`。误差恰为条目年龄。`set(..., dieAt)` 对已存在且非一次性的条目同理（`life = dieAt - now`，随后 `once = true` 使基准切到 `birth`）。
- **描述**：一个 1 小时前写入、`maxLife` 5 s 但一直被读（因此未过期）的条目，调 `prolong(key, DateTime.now() + 1h)`，实际死亡时间变成 `now + 1h - 1h = now`，**立刻失效**；`set(key, v, dieAt)` 更新老条目同样提前。新键路径不受影响（`birth ≈ now`），所以 `testSetLifeOnNewKey` 覆盖不到。README（`README.md:37-51`）承诺「修改对象过期时间」/「指定缓存对象的过期时间」，实现不符。
- **建议**：`prolongDeathAtLocked` 里先 `p.once = true` 再 `p.deathNanos = deathNanos`（或直接按 `birth` 折算 `maxLife_`）；`set(..., dieAt)` 的更新分支不要复用相对 `life`，改为在锁内直接 `p.once = true; p.deathNanos = dieAt纳秒`。补两条用例：老条目 + `prolong(deathTime)`、老条目 + `set(dieAt)`，断言 `contains` 在 dieAt 之前仍为 true。

### [一般][存量] 段级死亡时间下界的「登记」与「清扫后重算」存在丢失更新：`deathVer` 在 CAS 成功之后才自增

- **位置**：`src/SyncLinkedHashMap.cj:150-161`（`noteDeathNanos`：CAS 成功后才 `deathVer.fetchAdd(1)`）、`src/SyncLinkedHashMap.cj:174-196`（`sweepLocked`：读 `ver0` → 遍历 → `deathVer == ver0` 才回写 `minDeath`）
- **来源**：存量（`git blame`：`fd1a2dfe0` 引入增量清扫）
- **判据**：review-checklist §12.1（检查-然后-写入 / 丢失更新）、§5（过期条目滞留）
- **证据**：静态确定（给出交错即可复现该窗口）—— ① 清扫线程读 `ver0 = deathVer`；② 业务线程 `noteDeathNanos` 的 CAS 成功，把 `minDeath` 下调到更早的 X，但**尚未**执行 `fetchAdd`；③ 清扫线程遍历结束，读到 `deathVer == ver0`（自增还不可见），执行 `minDeath.store(st.minDeath)`，用「存活条目的最小死亡时间」覆盖掉 X；④ 业务线程这才 `fetchAdd`。结果：段的 `minDeath` 高于真实最小值，`ConcHashMap.cj:340-349` 的 `segment.minDeathNanos <= nowNanos` 判定会一直跳过该段。
- **描述**：被覆盖的那次登记如果是该段唯一一次「更早死亡时间」，则该段内已过期条目不会被定时清扫删除，只能靠读路径（`get`/`contains` 判过期）表现为 miss，物理条目与 `size` 会长期偏大 —— 对以「有界」为目的的缓存而言是内存滞留；`testSweepKeepsUpUnderConcurrentWrites` 只断言最终 `size == 0`，窗口极窄，跑不出来不代表不存在。
- **建议**：把版本自增提到 CAS 之前（先 `fetchAdd` 再 CAS），或把 `(minDeath, ver)` 打包进单个 `AtomicReference` 一次 CAS；`sweepLocked` 回写时对 `minDeath` 做 `compareAndSwap(cur, min(cur, st.minDeath))` 而不是无条件 `store`。

### [一般][存量] 淘汰按 key 删除，未校验「候选仍是采样时那一条」：并发 `set` 覆盖后可能把新写入的条目删掉

- **位置**：`src/HeapCache.cj:203-207`（`store.remove(p.key)` 后无条件 `evictionQueue.add(Some((p.key, p.load())))`）
- **来源**：存量（`git blame`：`ba1db1525` 快照化改造时保留的按 key 删除）
- **判据**：review-checklist §11（检查-然后-写入）、§12.1
- **证据**：静态确定（时序竞争）—— 采样时把 `Priority` 实例 `p` 放进堆；`p` 出堆时只按 `p.key` 删除，`ConcHashMap.remove(key)` 不比较值身份（`src/ConcHashMap.cj:298-304`）。若两动作之间业务线程 `set(p.key, newValue)` 覆盖了同键（旧 `Priority` 已被替换成新对象），被删除的是**新写入**的条目。
- **描述**：在 `store.size > maxSize` 的持续写入场景下，刚写入的热条目可能被上一轮采样结果淘汰，形成写-淘汰抖动（`maxSize` 越小越明显）；被删条目的值与 `p.load()` 的值不一致，淘汰回调也会报告一个「已不是当前值」的值。
- **建议**：给 `ConcHashMap` 加 `removeIfSame(key, expect: V): Bool`（段锁内 `map.get(key) == expect` 才删），或把 `Priority` 的 `value` 换成带版本号的包装，删除成功后用被删的那个值投递回调。

### [一般][存量] `clear()` 先清段再 `size_.store(0)`，与并发 `add` 竞争会抹掉已有条目的计数

- **位置**：`src/ConcHashMap.cj:370-375`（`clear`）、`src/ConcHashMap.cj:265-272`（`add` 的 `incrSize`）
- **来源**：存量（`git blame`：记账逻辑来自 `ba1db1525`）
- **判据**：review-checklist §12.1（复合操作非原子）、§5（`size` 失真导致 `maxSize` 失效）
- **证据**：静态确定 —— `clear()` 逐段 `segm.clear()` 之后执行 `size_.store(0)`。若业务线程在「某段已清空」与「`store(0)`」之间对**已清空的段**执行 `add`，该条目留在 map 中且 `incrSize()` 生效，随后被 `store(0)` 抹掉 ⇒ `size` 比实际少。README（`README.md:156`）明确 `clear` 可并发调用。
- **描述**：少计是永久性的（没有重算路径），`HeapCache` 的 `maxSize` 淘汰以 `store.size` 为准（`HeapCache.cj:188`），持续「clear + 写入」的缓存会长期超限而不被淘汰；`size` 对外也会长期偏小。
- **建议**：`clear()` 改为逐段清空时返回删除条数并 `fetchSub`（复用 `removeIfOutside` 的计数方式），最后**不**做 `store(0)`；或加一个 `clearing` 标志让 `add` 与 `clear` 互斥（代价是写入路径多一次原子读）。

### [一般][存量] 淘汰回调队列无容量上限，元素强引用被淘汰的值

- **位置**：`src/HeapCache.cj:38`（`LinkedBlockingQueue<Option<(String, V)>>()` 默认容量 `Int64.Max`）、生产点 `src/HeapCache.cj:173`（过期清扫）与 `206`（超限淘汰）
- **来源**：存量（`git blame`：队列声明早于 `ce64e9534`）
- **判据**：review-checklist §5（无界容器、长期持有）、§12.1（有界性）
- **证据**：静态确定（无界的部分）；量级需实测 —— `std.collection.concurrent.LinkedBlockingQueue()` 的默认 `capacity` 为 `Int64.Max`（std 1.3.0 `collection_concurrent_class.html`，`init()` 说明「默认初始容量 Int64.Max」）。生产者是定时线程，单次 tick 可入队「本 tick 内到期/超限的全部条目」；消费者只有 1 个（`onEviction` 的 spawn），速度等于用户 `evictionCallback` 的耗时。
- **描述**：回调慢（例如回调里写日志/发 MQ）时，队列按「每 tick 淘汰量」累积且每个元素**强引用** `V`，被淘汰对象无法释放 —— 缓存本应限制内存，这里反而在关闭前把值钉住；`close()` 的排空循环（`112-117`）也会把积压全部串行执行完才返回，`close` 时长随积压线性增长。
- **建议**：给队列设上限（如 `max(1024, maxSize/10)`）并用 `tryAdd`，满时降级为「合并/丢弃并计数告警」；或改成「每 tick 只投递固定条数 + 剩余留到下一 tick」的有界窗口。

### [一般][存量] 在淘汰回调里调用 `close()` 会让消费线程 join 自己，永久阻塞

- **位置**：`src/HeapCache.cj:394-416`（`close()` 的 `f.get()`）、`src/HeapCache.cj:126-132`（`notifyEviction` 在消费线程上执行用户回调）
- **来源**：存量
- **判据**：review-checklist §12.1（死锁：线程等待自身）、§6.2
- **证据**：静态确定（路径）—— `evictionCallback` 在 `onEviction` 的 `spawn` 线程内被调用（`103-108` → `126-132`）；若回调里调用 `cache.close()`，`close` 走到 `f.cancel(); f.get()`，而 `get()` 的语义是「阻塞当前线程等待对应线程结束」（std 1.3.0 `core_package_classes.html` `Future.get()`），等待对象正是当前线程 ⇒ 永不返回。README（`README.md:157`）与 `evictionCallback` 参数说明都没有禁止这种用法。
- **描述**：使用者在回调里做「缓存失效后关闭/降级」这类收尾逻辑即可触发；表现是回调线程永久挂住、`close()` 不返回、后续 `close()` 因 `closedFlag` 已置位直接返回，于是「关闭完成」与「回调未跑完」状态不一致。
- **建议**：`close()` 记录 `evictionThreadId`（spawn 时写入 `Thread.currentThread.id`），若 `close()` 在消费线程上被调用则只置 `closedFlag` + 投哨兵、跳过 `f.get()`；README 增加一句「不要在 `evictionCallback` 内调用 `close()`」。

### [一般][存量] `WeakHeapCache.getOrCompute` 的用户回调在 `entryView` 原子区内执行，回访同一缓存会破坏 std 的并发约束

- **位置**：`src/WeakHeapCache.cj:110-122`
- **来源**：存量（`git blame`：`entryView` 写法早于 `ce64e9534`）
- **判据**：review-checklist §6.2（锁内调用外部回调）、§12.1（重入 / 死锁）、§13（未记录的约束）
- **证据**：静态确定（约束来自 std 文档）—— `ConcurrentHashMap.entryView(key, fn)` 文档（std 1.3.0 `collection_concurrent_class.html`）写明「该操作具有原子性…回调 fn 调用过程中对 key-value 键值对的修改不会即时更新到当前映射中，等到 entryView 函数调用结束再将修改整体更新」，并明确「参数 fn 中不能并发调用函数 entryView、remove、replace」。`getOrCompute` 把用户 `fn()` 直接放在该回调里，而 `set`（`100-109`）内部就是 `cache.get` + `cache[key] = ...`（即 `entryView`/`replace` 路径）。
- **描述**：① 用户 `fn` 里写 `cache.set(otherKey, x)` 或 `cache.remove(...)` 即落入文档禁止的重入范围，结果至少是丢更新（外层 entryView 结束时整体回写），可能死锁；② `fn` 是任意耗时计算，却持有该桶的原子视图区，阻塞同桶的其它键读写（与 `HeapCache` 的「callable 在锁外」形成相反语义，README 只描述了前者）。
- **建议**：改成「先 `get` 命中即返回；未命中则在锁外算 `fn()`，再用 `addIfAbsent` 写回并返回最终值（`std.collection.concurrent.ConcurrentMap.addIfAbsent`）」，与 `HeapCache.getOrCompute` 的语义对齐；README 补一段说明「`fn` 可能在并发下被调用多次、只有首个写入生效」。

### [一般][存量] 定时回调没有异常兜底，一次异常会让 `Timer` 永久失效：清扫与 `maxSize` 淘汰静默停摆

- **位置**：`src/HeapCache.cj:146-155`（`Timer.after` 的 lambda 全程无 `try/catch`，内部依次调用 `162-178`、`179-224`）
- **来源**：存量
- **判据**：review-checklist §3（静默失效）、§11（错误处理缺失）、§5（失效后无界增长）
- **证据**：静态确定 —— std 1.3.0 `sync_package_classes.html` 的 `Timer` 说明：「Timer 不会主动捕获关联 Task 抛出的异常。只要 Task 有未被捕获的异常，Timer 就会失效」；`Timer.after` 的 lambda 里 `(store.iterator() as ConcHashMapIterator<Priority<V>>).getOrThrow()`（`147`）依赖类型转换成功、`PriorityQueue.add`/`HashMap.add` 可能因内存不足抛错，均未捕获。
- **描述**：任一次 tick 抛异常后定时器不再重排，`closedFlag` 仍为 false、`isClosed()` 仍返回 false、所有读接口正常，但过期条目再也不会被删、`maxSize` 淘汰再也不会执行 ⇒ 缓存无界增长直至 OOM，且没有任何日志线索。这与「缓存必须有界」的核心承诺冲突。
- **建议**：把 `checkTimeout`/`checkOverSize` 包在 `try { ... } catch (e: Exception) { f_log 记录一次 }` 内，异常时仍返回 `checkDuration` 继续下一轮；`iterator` 的 `as` 强转改为直接依赖 `store.iterator()` 的具体返回类型（去掉 `getOrThrow`）。

### [一般][存量] 淘汰评分的「本周期访问次数」口径与 README 不符：`lastChecked` 只在候选出堆后刷新

- **位置**：`src/HeapCache.cj:216-223`（只对当轮堆内剩余候选调用 `updateLastChecked`）、`src/Priority.cj:224-230`（`usedUtilLastChecked = ref`）、`src/Priority.cj:96-102`（tie-break ①）；文档承诺 `README.md:153`
- **来源**：存量（`git blame`：`ba1db1525` 引入快照化时同步改造）
- **判据**：review-checklist §13（规格与实现漂移）、§11（语义与注释不符）
- **证据**：静态确定 —— `updateLastChecked` 的唯一调用点是 `HeapCache.cj:221`，且只作用于「本轮进过堆、最后仍未淘汰」的条目（每轮 ≤ 段数，默认 ≤128 个）。未进入该集合的条目 `lastChecked` 永远停在 `birth`、`usedUtilLastChecked` 永远停在 `1`，于是 tie-break ① 的 `ref - usedUtilLastChecked` 等于**生命周期累计访问量**而非「本次检查周期内」的访问量。
- **描述**：README 承诺「本次检查周期内使用次数多者…优先保留」，实现是「自上次成为淘汰候选以来」。历史访问多但近期已冷的条目会被持续保护（`ref` 只增不减），而新写入条目 `ref=1` 在堆里最小、优先被淘汰，与「保护新生」的宣称方向相反，会造成新键抖动。具体退化幅度需实测（见待验证假设 #5）。
- **建议**：在 `get`/`loadIfAlive` 路径里以「tick 序号」而不是布尔基线做窗口统计（例如 `ref - refAtLastTick`，`refAtLastTick` 在每 tick 开始时按段抽样刷新，或直接用 `lastUsed` 的滑动窗口），并把 README 改成与实现一致的口径。

### [轻微][存量] 未使用的内部声明与未使用的通配 import

- **位置**：`src/ConcHashMap.cj:87-137`（`ConcHashMapValues` / `ConcHashMapValuesIterator`，全仓零引用、从未实例化）、`src/ConcHashMap.cj:191-204`（`create(map:concurrencyLevel:)`，零引用）、`src/ConcHashMap.cj:310-314`（`removeAll(keys:)`，零引用）、`src/ConcHashMap.cj:355-365`（`removeIfLocked(predicate:)`，零引用，仅注释里提到）、`src/WeakHeapCache.cj:22`（`import fountain::f_collection.*`，文件内无任何 `f_collection` 符号）
- **来源**：存量（`git blame`：`ConcHashMapValues` 来自最初版本，`removeIfLocked` 在改为增量清扫后成为残留）
- **判据**：review-checklist §1（无调用者 / 未使用的 import / 兼容残留）
- **证据**：静态确定 —— `class ConcHashMap` 为包内可见类型，其 `public` 成员对外不可达，按「全项目无使用」判：`grep -rn "\bConcHashMapValues\b"` 除定义外零命中（含测试）；`removeAll`、`removeIfLocked`、`create(map:` 同样除定义外零命中；`removeIfLocked` 只在 `HeapCache.cj:160` 的注释与 `HeapCache_test.cj:672` 直接调用**段类**的同名方法，不经 `ConcHashMap`。
- **描述**：`ConcHashMapValues` 与 `ConcHashMapValuesIterator` 是一整条死链（内部类 + 内部迭代器，`ConcHashMap` 也没有 `values()` 入口），保留会让人误以为存在 `values()` API；`ConcHashMap.removeIfLocked` 是「关闭时锁内清空」方案的残留，现由 `sweepExpired` 承担。
- **建议**：删除上述 4 处声明与 1 处 import；若 `ConcHashMapKeys`/`ConcHashMapKeysIterator` 只服务测试（`ConcHashMap_test.cj:29`），把它们降为 `private` 或移到测试辅助文件 —— 这是可见性建议，不按死代码处理。

### [轻微][存量] `once` / `prolong` / `set` 的「取锁 → `load()` → 改字段 → 读 `deathNanos` → `noteDeath`」四段实现重复

- **位置**：`src/HeapCache.cj:255-264`（`onceLocked`）、`273-283`（`prolongLocked`）、`291-301`（`prolongDeathAtLocked`）、`304-314`（`set` 更新分支）
- **来源**：存量
- **判据**：review-checklist §2（只改字段名的近似重复）
- **证据**：静态确定 —— 四个函数体结构逐行对齐，差异仅三处：写入的字段组合（`once` / `once+maxLife` / `deathNanos` / `value+maxLife+once`）、`noteDeath` 用的纳秒值来源（`p.deathNanos` vs 入参）、返回值（`Bool` vs `?V`）。上一节的死亡时间口径缺陷正是四处各写一遍导致的漂移。
- **描述**：任何与「死亡时间基准」相关的修正都要改四处，容易再漂移（`prolongDeathAtLocked` 已经漂了）。
- **建议**：抽一个 `private func mutate(key: String, p: Priority<V>, f: (Priority<V>) -> Unit): Unit`（锁内执行 `f` 后统一取 `p.deathNanos` 并 `store.noteDeath`），四个 API 只保留各自的字段赋值闭包；返回旧值等差异留在调用点。

### [轻微][存量] `ConcHashMapKeys.contains(all:)` 与 `ConcHashMap.containsAll` 是同一判定

- **位置**：`src/ConcHashMap.cj:75-84` 与 `src/ConcHashMap.cj:246-255`
- **来源**：存量
- **判据**：review-checklist §2（换控制流）
- **证据**：静态确定 —— 两处都是「遍历 key，全部命中才 true」，一处 `for + return false`，一处 `cont &&= ...; if (!cont) break`；错误路径与空集合语义（vacuously true）一致。
- **描述**：`containsAll` 只被测试用（`ConcHashMap_test.cj:63-64`），`contains(all:)` 只被测试用；两份实现让「containsAll 应该等价于 contains(all:)」这一约定靠人肉维护。
- **建议**：保留 `contains(all:)`（它是 `EquatableCollection` 的接口语义），删掉 `containsAll`，测试改为断言 `keys.contains(all: [...])`；或在 `containsAll` 里直接 `contains(all: keys)`。

### [轻微][存量] `contains(key)` 走 `get()`：纯查询会 `ref++`、更新 `lastUsed` 并移动 LRU 链表

- **位置**：`src/HeapCache.cj:243-246`
- **来源**：存量
- **判据**：review-checklist §11（语义与命名不符）、§10 可读性
- **证据**：静态确定 —— `contains` 直接 `get(key).isSome()`，`get` 调 `Priority.loadIfAlive()`（`src/Priority.cj:239-249`）内部的 `ref++` 与 `lastUsed = now`；`store.get` 还经 `LinkedHashMap.get(key, turn: true)` 触发 `turnToTail`（`f_collection/src/LinkedHashMap.cj:110-122`）。
- **描述**：`contains` 在多数缓存 API 里是「只看不摸」，这里却延长寿命、抬高淘汰评分、改变段内 LRU 顺序；用 `contains` 做健康检查/打点会改变缓存行为，README 未说明（`README.md:150` 只说了 `size` 与 `get`/`contains` 的过期口径）。
- **建议**：`contains` 改为 `store.get(key)` 后只判 `aliveAndDeathNanos(now).0`（不加 `ref`、不动 LRU），或在 README 明确「`contains` 等价于 `get` 的一次使用」。

### [轻微][存量] `once()` 与 `prolong(once: true)` 会把「已存活超过 `maxLife` 的非一次性条目」当场变成过期

- **位置**：`src/HeapCache.cj:255-264`（`onceLocked`：`load()` 后 `once = true`，死亡时间切到 `birth + maxLife`）、`src/HeapCache.cj:273-283`
- **来源**：存量
- **判据**：review-checklist §11（边界）、§3（契约）
- **证据**：待确认 —— 语义取决于产品预期：`once` 的定义是「取用不重新计时」，实现把基准从 `lastUsed` 切到 `birth`，因此一个 10 分钟前创建、`maxLife=5s`、但因持续读取而未过期的条目，调 `once()` 返回 `true` 的同时把死亡时间设为「10 分钟前 + 5s」（已过去），下一次 `get` 即 miss。`testOnceRejectsExpiredEntry` 只覆盖「已过期 → false」，没有覆盖「未过期但年龄 > maxLife」的活条目。
- **描述**：调用方拿到 `true` 却得到「立刻失效」的条目；若这是有意设计（一次性 = 总寿命从出生算），需要在 README 写明风险，否则属契约缺口。
- **建议**：确认预期后二选一：① 保持语义但在 README/注释写明「`once` 会按 `birth + maxLife` 重新判定，可能立即过期」；② 切 `once` 时同步把 `maxLife` 调整为 `max(maxLife, now - birth + maxLife)`，避免「刚标记就死」。补一条活条目用例。

### [轻微][存量] README 对 `WeakHeapCache` 的引用强度自相矛盾，并把 private 类型的成员列为模块级公开 API

- **位置**：`README.md:105`（「内部维持的键和值被弱引用包装」）vs `README.md:151`（「键强、值弱」）vs 实现 `src/WeakHeapCache.cj:24-31`（`WeakKey` 持强引用 `String`，注释明确「键持强引用：弱引用缓存只该弱『值』」）；`README.md:169` 把 `public func hashCode(): Int64` 列为模块级公开 API，实体是 `src/WeakHeapCache.cj:32-34`（`private struct WeakKey` 的方法，对外不可达）
- **来源**：存量（`git blame`：`README.md` 2026-10-15，`WeakHeapCache.cj` 键改强引用的改动未同步文档）
- **判据**：review-checklist §13（文档与代码不符）、§14.2（公开 API 清单准确性）
- **证据**：静态确定 —— 同一文件两处结论相反，且实现只弱值；`WeakKey` 是 `private struct`，其 `hashCode` 不构成模块 API。`README_en.md:105/151/168` 同样问题（英文版同步照抄）。
- **描述**：按 `README.md:105` 理解的使用者会以为「键被 GC 后条目自动消失」，实际键永远强引用、只有值会失效；`hashCode` 一条会让读者去找一个不存在的模块级函数。
- **建议**：`README.md:105` / `README_en.md:105` 改为「键强引用、值弱引用，值被回收后条目在一个清扫周期内摘除」；删掉 `169`/`168` 行的 `hashCode` 条目（或改为「`WeakKey`（内部）实现 `Hashable`」）。

### [轻微][存量] 测试与基准创建的 `HeapCache` 多数没有 `close()`：每个实例遗留 1 个线程 + 1 个定时器 + 1 条退出回调

- **位置**：`src/HeapCache_test.cj:29, 51, 68, 81, 111, 202, 220, 244, 294, 304, 321, 339, 353, 357, 517, 530, 543, 558, 573, 593, 609`（未 close 的用例；只有 `testAutoConcurrencyLevel`、`testExplicitConcurrencyLevelRoundsUpToPowerOfTwo`、`testEvictionCallbackReceivesEvictedEntries`、`testConcurrentAccessDistinctKeys`、`testSweepKeepsUpUnderConcurrentWrites`、`testHeapCacheIsResource` 等显式 close）；`src/HeapCache_bench.cj:29-34`（三个字段实例全生命周期不 close）
- **来源**：存量
- **判据**：review-checklist §11（资源释放不对称）、§5（长期持有）
- **证据**：静态确定 —— `HeapCache` 构造即 `startTimer()`（`src/HeapCache.cj:61`）+ `onEviction()` 的 `spawn`（`99`）+ `ExitCallbacks.atExit`（`65`），只有 `close()` 会取消它们；上述用例结束后实例只在用例栈上，线程与定时器继续存活到进程结束。
- **描述**：单模块测试跑完会留下数十个常驻线程与每秒触发的定时器（`checkDuration` 默认 1 s），拉高 `cjpm test` 的尾部耗时与 RSS，也让「线程计数」类断言（`testCloseStopsEvictionThread` 之外）失真；bench 场景还会把三个实例的淘汰活动叠加到同一测量窗口。
- **建议**：给 `@Test` 类加 `@AfterAll func cleanup()` 统一 close；或在每个用例末尾 close（可参考 `testAutoConcurrencyLevel` 的写法）。

### [轻微][存量] 每个 `HeapCache` 实例都向 `f_base.ExitCallbacks` 追加一条永不注销的闭包

- **位置**：`src/HeapCache.cj:64-65`
- **来源**：存量
- **判据**：review-checklist §5（注册表不注销、长期持有）
- **证据**：静态确定 —— `ExitCallbacks.atExit`（`f_base/src/signal.cj:48-59`）把闭包 `add` 进 `TreeMap<UInt16, ArrayList<() -> Unit>>`，只增不删；`close()` 不会移除注册项。闭包捕获 `WeakRef<HeapCache<V>>`，因此实例可回收，但**闭包对象本身**永久留在全局表里（`callbacks` 是 static）。
- **描述**：按请求/按租户创建短命 `HeapCache` 的用法会让全局退出回调表随实例数线性增长（每项 ≈ 闭包对象 + `ArrayList` 槽位），`close()` 之后也不会回收；数量级到百万级才明显，故记轻微。
- **建议**：让 `atExit` 返回可注销句柄（`f_base` 侧提供 `removeAtExit(handle)`），`close()` 时注销；或在 `f_cache` 内维护单个全局注册项，遍历自己的弱引用集合完成关闭。

### [轻微][存量] README 缺少快速开始与依赖说明，`WeakHeapCache` 的 `close`/`isClosed` 未进 API 片段

- **位置**：`README.md:1-4`（只有三行能力列表）、`README.md:106-141`（`WeakHeapCache` 代码块只到 `clear()`）、`README.md:163-170`（「其他公开 API」未提 `close`/`isClosed`）；`README_en.md:1-4/106-141/164-169` 同
- **来源**：存量
- **判据**：review-checklist §14.2（缺关键段落、公开 API 未文档化）
- **证据**：静态确定 —— `src/WeakHeapCache.cj:69-88` 实现了 `close()`/`isClosed()`（`Resource` 契约），README 的 Weak 片段（`106-141`）没有这两个签名，只在散文 `151/157-159` 提及；README 通篇没有可运行的「创建 → 读写 → 关闭」示例，也没有 `cjpm.toml` 依赖/版本说明。`HeapCache` 片段有 `close`/`isClosed`，两版不对称。
- **描述**：按 README 复制 `WeakHeapCache` 用法会漏掉 `close()`（Weak 版本持有常驻清扫线程，不 close 就是线程泄漏）；缺少最小示例使得「`maxLife`/`checkDuration` 该怎么配」只能读源码。
- **建议**：在 `WeakHeapCache` 代码块补 `close()`/`isClosed()`；加一节 20 行以内可运行示例（构造 → `set`/`getOrCompute` → `close`），并补依赖与版本一行。

## 优化可行性方案

### [堆内存] 把淘汰比较快照 `PrioritySnap` 从「每条目常驻字段」改为「淘汰轮内局部数据」

- **现状**：每个缓存条目是一个 `Priority<V>` 对象，除 `key`/`value`/三个时间戳/两个计数外，还常驻 ① 一把 `Mutex`（`src/Priority.cj:50`）、② 一个 `PrioritySnap` 结构（6 个 `Int64`/`Float64` 字段，`src/Priority.cj:30-47, 63`），而 `snap` 只在淘汰轮（`HeapCache.cj:196/212` 的 `snapshot`）被写、堆内比较时被读。10 万条目即 10 万个 `Mutex` + 约 4.8 MB 的 `snap` 字段常驻（按 6×8 B 估算，不含对齐与对象头）。
- **方案**：把 `snap`/`snapReady` 从 `Priority` 移出，改成淘汰轮内的并行结构（`HashMap<Priority<V>, PrioritySnap>` 或与候选数组同下标的 `ArrayList<PrioritySnap>`），堆元素改成 `struct EvictCandidate { let p: Priority<V>; let snap: PrioritySnap }`；`Priority.compare` 保持现状（公开语义不变），`compareSnapshot` 删除。
- **预期**：每条目省 1 个 `PrioritySnap`（≈48 B）与 2 个布尔/引用字段；10 万条目常驻内存约降 5 MB 量级（相对当前条目自身开销约 1/4~1/3，需实测确认占比）。
- **代价**：淘汰轮多一次 `HashMap` 插入/查找（每轮 ≤段数 条，可忽略）；`Priority` 的 `protected snapshot/compareSnapshot` 消失，属对外 API 收窄（`Priority` 是 public 类型，需按契约变更处理）。
- **验证**：同机同 SDK `-O2`，10 万条目稳态后 `getUsedHeapSize()` / RSS 前后对照，跑 3 轮取中位数；同时确认 `evict 50000 / maxSize=1000` 的收敛时间不退化。
- **证据状态**：`无基线（待验证，不进 tasks）`（README 提到的 `cron-bench` 日志不在本仓库内，无法复核）

> 本轮不产出 CPU 优化方案：`scope.md` 的「已有性能资料」只给了 `docs/LocalMode*.md`，没有本模块的 `cjprof`/`cjpm bench` 前后对照数据；所有 CPU 相关线索按铁律写入下方「待验证假设」，不写成方案。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `checkOverSize` 每轮重建 `Array<Iterator>`（段数个迭代器）与 `HashMap<Int64, Iterator>`，超限严重时轮数多，单 tick 成本高 | `src/HeapCache.cj:188-215` | 单 tick 耗时、轮数、条目数 | `cjprof record` 跑「写入 5 万键 / maxSize=1000 / checkDuration=100ms」，对比 tick 内 self time |
| 2 | `sweepLocked` 在段锁内遍历整段并逐条取 `p.lock`，单次持锁时长随段内条目数线性增长，可能造成该段读延迟尖刺 | `src/SyncLinkedHashMap.cj:174-196` + `src/HeapCache.cj:165-177` | 持锁时长分布、P99 读延迟 | 在 `sweepLocked` 前后加 `MonoTime` 分段计时，跑 10 万条目、读 QPS 固定的混合负载 |
| 3 | `HeapCache.get` 每命中要过两把锁（段 `Mutex` → `Priority.lock`），高并发同段命中时竞争占比可观 | `src/HeapCache.cj:235-242` + `src/SyncLinkedHashMap.cj:45-49` | 锁等待时间、核利用率 | 线程状态采样（BLOCKED 占比）+ `cjpm bench` 多点并发对照（1/4/16 线程） |
| 4 | 淘汰回调队列的峰值深度与回调耗时线性相关，回调慢时会积压大量强引用值 | `src/HeapCache.cj:38, 173, 206` | 队列峰值、回调单次耗时 | 加 `evictionQueue.size` 打点，回调内 `sleep(1ms)` 模拟慢回调，观察峰值与 RSS |
| 5 | 「本周期访问次数」口径偏差会让历史热点条目长期驻留、新条目频繁被淘汰（写多读少负载下命中率下降） | `src/HeapCache.cj:216-223` + `src/Priority.cj:96-102` | 命中率、淘汰命中新键比例 | 构造「1 万热点键 → 转冷 → 持续写入 10 万唯一键」的负载，统计被淘汰条目的 `ref` 分布与命中率 |
| 6 | `autoConcurrencyLevel` 的段数（16~128）对该模块真实负载是否合适（段太少→锁竞争，太多→内存与构造开销） | `src/HeapCache.cj:75-81` | 段数与吞吐/内存的关系曲线 | `cjpm bench` 固定 maxSize 扫描 `concurrencyLevel ∈ {1,4,16,64,128}`，同机 `-O2` |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `README.md` | .md | ✅ | 与实现基本一致；键/值弱引用表述矛盾、`hashCode` 误列、缺快速开始 → 见 §13/§14 问题 |
| 2 | `README_en.md` | .md | ✅ | 与中文版同步（同样带 `README.md` 的三处问题），无独立缺失 |
| 3 | `src/ConcHashMap.cj` | .cj | ✅ | 分段路由、size 记账、两阶段 `removeIf`、增量清扫入口；死代码与 `clear` 竞争见发现 |
| 4 | `src/ConcHashMap_test.cj` | .cj | ✅ | 覆盖 size 记账与 `contains(all:)`；`ConcHashMapKeys` 仅此处使用 |
| 5 | `src/HeapCache.cj` | .cj | ✅ | 主体：定时清扫/淘汰/关闭/回调；1 严重 + 6 一般 + 若干轻微均落在此文件 |
| 6 | `src/HeapCacheBuilder.cj` | .cj | ✅ | 四个默认值与五个 setter 校验完整，与 `HeapCache` 构造校验一一对应，无问题 |
| 7 | `src/HeapCache_bench.cj` | .cj | ✅ | 4 个基准；三个字段实例未 close（资源泄漏，并入测试清理一条） |
| 8 | `src/HeapCache_test.cj` | .cj | ✅ | 覆盖淘汰/关闭/并发/清扫；未覆盖 `prolong(deathTime)` 与「活条目 once」，多数用例未 close |
| 9 | `src/Priority.cj` | .cj | ✅ | 纳秒时间戳、`deathNanos` 基准、快照比较；`deathNanos` setter 与 `once` 的顺序问题见发现 |
| 10 | `src/SyncLinkedHashMap.cj` | .cj | ✅ | 段锁 + LRU 链表 + 段级下界；迭代器自环与 `deathVer` 窗口见发现 |
| 11 | `src/WeakHeapCache.cj` | .cj | ✅ | 键强/值弱、清扫线程、`Resource`；`entryView` 内跑用户回调见发现 |
| 12 | `src/WeakHeapCache_test.cj` | .cj | ✅ | 覆盖 set/get/remove/close 语义；`getOrCompute` 只测单线程路径，无回访缓存的用例 |

合计：`.cj` 10 个 / `.md` 2 个 / 共 12 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 4（死亡时间基准、按 key 删除、`clear` 少计、`once` 边界）；可读性/契约 2（`contains` 副作用、`size` 口径）；语言特性方面核对了 `struct` 值语义（`PrioritySnap` 按值复制）、`Mutex` 可重入（std 1.3.0 文档，嵌套 `synchronized` 合法）、`Future.get` 阻塞语义；安全性 0（无外部输入解析、无凭据、无注入面） |
| §1 死代码 | 1 | 逐个核对全部非 public 声明：`ConcHashMapValues`/`ValuesIterator`/`create(map:)`/`removeAll`/`removeIfLocked` 全仓零引用（已用 `grep -rn` 排除 `.worktrees`）；`SyncLinkedHashMap` 与 `ConcHashMap` 的 `size`/`isEmpty`/`clear`/`add(all:)`/`removeIf` 是 `Collection` 接口成员（另有内部调用点），不判；`ConcHashMapKeys` 仅测试引用 → 记为可见性建议；`Priority` 的 `protected` 成员属 `public open class`（非 sealed）扩展点，不判；对外可达的 `public`（`HeapCache`/`WeakHeapCache`/`HeapCacheBuilder`/`Priority`/4 个默认值）不判 |
| §2 重复逻辑 | 2 | 已把 24 个函数体压成「输入→输出→副作用」两两比对：`once/prolong/prolongDeathAt/set` 四段同构（命中）；`ConcHashMapKeys.contains(all:)` 与 `containsAll` 同义（命中）；`Priority.loadIfAlive` 与 `aliveAndDeathNanos` 的过期判定重复但返回形态不同、且都被热路径使用，合并会把 `Option` 与 `(Bool, Int64)` 揉成一个带副作用的接口，收益为负，不报 |
| §3 空实现 | 0 | 无 `TODO`/`FIXME`/空函数体/`UnsupportedException`；`notifyEviction`（`HeapCache.cj:126-132`）与两处 `close` 的 `catch` 都有注释说明「回调异常不得杀死消费线程/不得让 close 失败」，属有意的吞异常，非静默失效；`WeakKey` 的 `hashCode`/`==` 是接口实现 |
| §4 栈溢出 | 0 | 模块内无递归调用（`nextPowerOf2` 的 `default` 分支只递归一层且参数为常量）；`Priority.compare` 不递归比较 `value`；`checkOverSize` 是循环而非递归 |
| §5 OOM | 2 | 淘汰回调队列无界（含强引用值）；`ExitCallbacks` 注册项随实例数累积。`maxSize` 默认 `Int64.Max` 属文档化默认值，不计 |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 `cjprof`/`cjpm bench` 数据，`scope.md` 只有 `LocalMode` 文档；6 条线索全部写入「待验证假设」，不写成发现 |
| §6.2 大粒度锁 | 0 | 发现不成立：`sweepLocked` 的临界区是 O(段内条目) 但每 `checkDuration` 才一次、且不碰 I/O；`checkTimeout` 在段锁内做 `evictionQueue.add` 与 `p.lock`（队列无界→不阻塞）。两者都缺持锁时长数据，已进待验证假设 #2。锁顺序核对：段锁 → `Priority.lock`（`get`/`sweep`）、段锁 → 队列锁（`checkTimeout`），无反向路径，无死锁 |
| §6.3 并发串行 | 0 | 无 `spawn` 后立刻 `get` 的模式；消费线程单线程是队列语义要求（回调需保序），不算串行热点；`close()` 的 `f.get()` 是终止等待，非任务汇合 |
| §6.4 低效算法 | 0 | 无嵌套全表扫描、无 `remove(at: 0)`、无循环内字符串拼接；`checkOverSize` 每轮 O(段数) + 每段取 1 个候选是设计取舍，成本问题归入待验证假设 #1 |
| §7 降堆内存方案 | 1 | `PrioritySnap` 从每条目常驻改为淘汰轮局部（`无基线（待验证）`）；`mem §3.2` 提醒：`clear()` 只清元素不还物理内存，方案收益只能靠 heapUsed/RSS 前后对照证明 |
| §8 降 CPU 方案 | 0 | 无 bench/profile 基线，按铁律不产出方案，全部线索进待验证假设 |
| §9 local mode 可行性 | 0 | 不成立：`Priority`/`String`/值对象都要逃逸进 `ConcHashMap` 并跨线程（定时线程、消费线程）访问，`@ local!` 无法满足逃逸检查；`evictionQueue` 元素同样跨线程传递 |
| §11 现有代码的 BUG（存量） | 19 | 本轮 19 条发现全部为存量（工作区快照、`git status f_cache` 干净）：逐条核对了边界（`prolong` 死亡时间、`once` 年龄、`clear` 计数）、空值（`Option` 未 `getOrThrow` 丢弃）、错误处理（定时回调无兜底、`notifyEviction` 吞异常已文档化）、资源（线程/定时器/退出回调/队列）、并发（5 条）与契约不符（README 键/值弱引用、评分口径、API 片段三处） |
| §12 并发安全与锁粒度 | 5 | ①段迭代器自环（严重）②`deathVer` 丢失更新 ③`clear` 与 `add` 的 size 竞争 ④回调内 `close()` 自 join ⑤`entryView` 内跑用户回调。均给出了共享路径与缺失的同步手段；`Mutex` 可重入性已按 std 文档确认，嵌套 `synchronized` 不构成死锁 |
| §14 功能完备性与 README 覆盖 | 1 | `WeakHeapCache.close/isClosed` 未进 API 片段 + 缺快速开始/依赖段落；其余 public 声明（`HeapCache` 全部方法、`HeapCacheBuilder` 五个 setter、4 个默认值、`Priority`）已逐项与 README 对照，无遗漏；无「承诺但未实现」的入口（`WeakHeapCache` 仓内无调用方，但属对外 API，不判死代码） |
| 文件覆盖（§13 等） | 12/12 | 12 个文件全部读完，无跳过 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 9 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

## 总评

整体结构清晰：分段 `Mutex` + 段内 LRU 链表 + 段级死亡时间下界的增量清扫是合理设计，`size` 记账、两阶段 `removeIf`、`close()` 的哨兵唤醒都有注释与用例支撑，绝大多数公开方法的并发契约在 README 里写清楚了。风险集中在「并发时序」而非「写法」：最需要先处理的是 **段迭代器在节点被并发删除后自环**（定时线程可能空转、淘汰永久失效，属阻塞项）；其次是 **`prolong(key, deathTime)` / `set(dieAt)` 对老条目提前过期**这类契约级偏差（可由调用方直接观察到，且现有用例完全没覆盖），以及 **段级下界丢失更新**、**按 key 淘汰未校验候选身份**、**`clear()` 的计数竞争** 三条会削弱「有界」承诺的并发缺陷。`WeakHeapCache` 的 `entryView` 内跑用户回调与「回调里 `close()` 自 join」是两条需要文档约束 + 代码兜底的重入路径。死代码与重复逻辑量不大，但 `ConcHashMapValues` 整条死链与四处同构的「改字段 + 登记死亡时间」应一并清理，否则死亡时间口径会继续漂移。

存量缺陷共 19 条（严重 1 / 一般 9 / 轻微 9），是否纳入修复、按什么顺序修，待用户决定；性能与内存方向本轮只有 1 条无基线方案，其余 6 条仅作下轮补数据的假设，不进 `todo.md` / `tasks.md`。
