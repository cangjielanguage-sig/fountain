# f_cache 模块代码审查报告

- **审查对象**：`f_cache`（强/弱引用堆缓存）@ 基线 `sts/1.3.x` = `7cd7863e`
- **审查分支 / worktree**：`review/f_cache` @ `.worktrees/review-f_cache`
- **审查日期**：2026-10-05
- **审查方式**：只读通读全部 8 个源文件（约 1100 行）+ std/仓库内依赖契约核对 + **临时探针实测**（探针文件均已删除，未入库；日志见 §5）
- **结论**：**严重 3 条 / 中 5 条 / 低危 8 条 / 待验证 2 条**；其中 3 条严重问题在仓库内**已有真实使用点**（f_data、f_orm、f_regex、f_jwt）

## 0. 摘要

| 严重度 | 条数 |
|---|---|
| 严重 | 3 |
| 中 | 5 |
| 低危 | 8 |
| 待验证 | 2 |

**建议修复顺序**：

1. `CACHE-1`（§1.1）`HeapCache.set(key, value, life!/dieAt)` 在**新建键**时忽略寿命参数 —— JWT id 过期语义失效（安全相关，实测复现）　**✅已修复（2026-10-05，见 §1.1 修复标记）**
2. `CACHE-2`（§1.2）`ConcHashMap.computeIfAbsent` 不记账 size —— `getOrCompute` 建的条目不计入 `size`，**`maxSize` 上限完全失效**（f_data/f_orm/f_regex 三处真实使用，实测复现）　**✅已修复（2026-10-05，见 §1.2 修复标记）**
3. `CACHE-3`（§1.3）`ConcHashMap.add` 覆盖已存在键多计、`clear()` 不归零 —— `size`/`isEmpty` 失真（实测复现）　**✅已修复（2026-10-05，见 §1.3 修复标记）**
4. `CACHE-4`（§2.1）用户代码（`removeIf` 谓词 / `getOrCompute` 的 callable）在**段写锁内**执行 —— 同段操作被串行阻塞（实测：同段 292.87 ms vs 异段 0.0228 ms）
5. `CACHE-5`（§2.2）每个 `HeapCache` 实例泄漏 1 个阻塞线程 + 1 条全局 `atExit` 强引用；`WeakHeapCache` 另泄漏 1 个 `while(true)` 清扫线程
6. `CACHE-6`（§2.3）`once()` / `prolong()` 不判过期 ⇒ 可“复活”已过期条目（实测复现）
7. `CACHE-7`（§2.4）`destroy()` 之后再写入的条目**永不被清理**（实测复现）
8. `CACHE-8`（§2.5）`Priority` 比较基线的无锁竞争 + `compare` 的“保护新生”分支疑似写反
9. 其余低危/待验证见 §3

> 修复进度（2026-10-05）：**§1 的 3 条严重级已全部修复**（`CACHE-1`/`CACHE-2`/`CACHE-3`）；§2 的 5 条中危与 §3 的低危/待验证**均未动**。全部改动在分支 `review/f_cache`（尚未并入 `sts/1.3.x`）；用例 1 → 6 条（全绿）。

---

## 1. 严重（3 条）

### 1.1 [严重｜正确性+安全] `CACHE-1` `HeapCache.set(key, value, life!/dieAt)` 在**新建键**时忽略寿命参数：新建时用缓存级 `maxLife`，覆盖时才用 `life` → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `review/f_cache`（审查 worktree 内直接修），**代码、用例、本标记在同一提交**（提交 `3171d664`：`fix(f_cache): CACHE-1 新建键忽略 set(life!/dieAt)（bug-cache §1.1 修复标记）`）。

- 改动（`src/HeapCache.cj:185-188`）：新建路径改为 `Priority<V>(key, value, life, checkDuration, once)`（原为缓存级 `maxLife`）。`life` 的默认值就是 `this.maxLife` ⇒ **不传 life 时行为不变**；`set(key, value, dieAt:)` 走 `life: dieAt - now()` ⇒ 一并恢复。
- 用例（`src/HeapCache_test.cj`）：新增 `testSetLifeOnNewKey` —— 新建键 `set(life=100ms)`、已存在键同参数（对照，修复前即正确）、新建键 `set(dieAt=now+100ms)`，300 ms 后三者都断言不存在；`checkDuration` 取 30 s 以隔离定时清扫。
- 测量证据：**修复前** PASSED 1 / **FAILED 1**（`Assert Failed: (false == cache.contains('newLife'))`，EXIT=1）→ **修复后** = **2/2 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**，f_cache 自身编译警告仍 2 条。日志 `/tmp/cache1_before.log`、`/tmp/cache1_after.log`。
- 影响面：`f_jwt/src/JwtIdCache.cj:58-63` 两条 `put` 都是「新建键」路径 ⇒ jti 的过期时间恢复生效；`f_security`/`fdemo` 走默认寿命 ⇒ 行为不变。

**位置**：`src/HeapCache.cj:176-192`（`set` 两个重载）；相关契约：`README.md:46-51`、`src/HeapCacheBuilder.cj:18`

```176:192:f_cache/src/HeapCache.cj
    public func set(key: String, value: V, life!: Duration = this.maxLife, once!: Bool = false): ?V {
        if (let Some(p) <- store.get(key)) {
            synchronized(p.lock) {
                let old = p.load()
                p.store(value)
                p.maxLife = life      // ← 覆盖路径：life 生效 ✓
                p.once = once
                old
            }
        } else {
            store.add(key, Priority<V>(key, value, maxLife, checkDuration, once))   // ← 新建路径：用的是缓存级 maxLife，不是 life ✗
            Option<V>.None
        }
    }
    public func set(key: String, value: V, dieAt: DateTime): ?V {
        set(key, value, life: dieAt - DateTime.now(), once: true)   // ← dieAt 走 life 参数 ⇒ 新建时同样失效
    }
```

**影响**：`set(k, v, life: d)` 与 `set(k, v, dieAt:)` 对**不存在的键**完全不生效，条目寿命取缓存级 `maxLife`（默认 5 s，或构造时给的值）。两个方向都错：

- 期望寿命 **短于** `maxLife` ⇒ 条目滞留过久；
- 期望寿命 **长于** `maxLife` ⇒ 条目提前消失。

真实使用点（安全相关）：`f_jwt/src/JwtIdCache.cj:58-63`

```58:63:f_jwt/src/JwtIdCache.cj
    public func put(id: T, expire: Duration): Unit {
        cache.set(id.toString(), this, life: expire)
    }
    public func put(id: T, expireAt: DateTime): Unit {
        cache.set(id.toString(), this, expireAt)
    }
```

JWT id 缓存用于一次性 id（防重放）登记：`put` 的过期时间被忽略 ⇒ 若真实 token 有效期**长于**缓存级 `maxLife`，id 会提前被淘汰 ⇒ 同一 jti 可再次通过校验（重放面）；反之则拒绝本应合法的请求。注意 `getOrCompute` 三条重载都正确地把算出的寿命传给构造器（`:201`、`:207`、`:213`）⇒ 本处是**实现遗漏**，不是设计取舍（README 也明确写「同时指定缓存对象的过期时间」）。

**修法**：新建路径改用 `life`：

```cangjie
store.add(key, Priority<V>(key, value, life, checkDuration, once))
```

**DT（设计用例）**：新建键 `set(k, v, life: 100ms)` ⇒ 300 ms 后 `contains(k)` 应为 `false`；已存在键同样操作同样为 `false`；`set(k, v, dieAt: now+100ms)` 同理。

**实测（探针 P1a/P1b/P1c）**：新建键 life=100ms ⇒ 300 ms 后 `contains=true` ✗；已存在键同参数 ⇒ `contains=false` ✓；新建键 dieAt=+100ms ⇒ `contains=true` ✗（日志 `/tmp/cache_probe1.log`、`/tmp/cache_probe3.log`）。

### 1.2 [严重｜正确性+内存] `CACHE-2` `ConcHashMap.computeIfAbsent` 不记账 `size`：`getOrCompute` 建的条目不计入 size ⇒ `maxSize` 上限完全失效、size 可为负 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `review/f_cache`，**代码、用例、本标记在同一提交**（提交 `0e3d70d6`：`fix(f_cache): CACHE-2 getOrCompute 计入 size（bug-cache §1.2 修复标记）`）。

- 改动：`src/SyncLinkedHashMap.cj:44-62` 的 `computeIfAbsent` 改为 `computeIfAbsentCounted(key, callable): (V, Bool)`（仍在同一段写锁内完成「查—算—写」，第二个返回值表示本次是否真的新建）；`src/ConcHashMap.cj:276-283` 改用它并在 `added` 时 `incrSize()`。两处类都是包内实现（全仓 grep 确认段级方法只有这一个调用方），公开 API 不变。
- 用例（`src/HeapCache_test.cj`）：`testGetOrComputeAccountsSize`（`getOrCompute×5` ⇒ `size==5`、`remove` 一个 ⇒ `size==4` 且不为负）、`testGetOrComputeObeysMaxSize`（`maxSize=2`、`getOrCompute×5`、等 1 s ⇒ 存活数与 `size` 都 ≤2）。
- 测量证据：**修复前** PASSED 2 / **FAILED 2**（`Assert Failed: (5 == cache.size)` 实测 `0`；`(true == alive <= 2)` 实测 5 条全部存活，EXIT=1）→ **修复后** = **4/4 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**；f_cache 自身编译警告仍 2 条。日志 `/tmp/cache2_before.log`、`/tmp/cache2_after.log`。
- 影响面：`f_data`（`CacheDataPath`）、`f_orm`（`dslcache`）、`f_regex`（`CACHE`）三处 `getOrCompute` 缓存恢复 `maxSize: 10000` 上限；`set`/`get`/`remove`/`removeIf` 路径不受影响。

**位置**：`src/ConcHashMap.cj:276-278`（对比 `add` 在 `:260-264`、`remove` 在 `:285-291` 都有记账）

```276:278:f_cache/src/ConcHashMap.cj
    func computeIfAbsent(key: String, callable: () -> V): V {
        segment(key).computeIfAbsent(key, callable)
    }
```

`HeapCache.getOrCompute` 三条重载全部走这条路径（`src/HeapCache.cj:199-215`），而 `HeapCache.checkOverSize` 的淘汰条件是 `store.size > maxSize`（`src/HeapCache.cj:96`）⇒ **经 `getOrCompute` 建立的条目永远不会参与 maxSize 淘汰**；同时 `remove` 会对它们 `decrSize`（`:285-291`）⇒ `size` 可变为**负数**，`isEmpty()`（`size == 0`，`:340-342`）会谎报。

真实使用点（三处，全部是 `getOrCompute`）：

| 模块 | 位置 | 缓存 | 期望上限 |
|---|---|---|---|
| f_data | `src/path/CacheDataPath.cj:21,24` | `HeapCache<DataPath>(maxLife: Duration.day, maxSize: 10000)` | ≤ 10000 |
| f_orm | `src/base/SqlDSL.cj:45,47` | `dslcache = HeapCache<ArrayList<SqlDSLPart>>(maxLife: Duration.day, maxSize: 10000)` | ≤ 10000 |
| f_regex | `src/RegexFromString.cj:28,61` | `CACHE = HeapCache<Regex>(maxLife: Duration.day, maxSize: 10000)` | ≤ 10000 |

⇒ 三个缓存各自只受「1 天 + 键空间」约束，声明里的 `maxSize: 10000` 形同虚设 ⇒ 键空间大时（每条不同 SQL / 正则 / 路径都建一条）无界增长。

**修法**：`computeIfAbsent` 感知「是否新建」，新建时 `incrSize()`；`SyncLinkedHashMap.computeIfAbsent` 已有足够信息（内层 `map.add` 返回旧值，`:44-58`）。最简做法：让段级 `computeIfAbsent` 返回 `(V, Bool)`（是否新建），或在 `ConcHashMap` 层用「先 `contains` 再 `computeIfAbsent` + 二次判定」实现（注意要保持段内原子性）。

**DT**：`maxSize=2` 的缓存用 `getOrCompute` 建 5 个键 ⇒ `size==5`，等 2 个检查周期后仍存活 ≤ 2；`remove` 一个后 `size==4`（不得为负）；`isEmpty()` 与 `contains` 口径一致。

**实测（探针 P2a/P2b/P2c/P2d/P2e）**：`getOrCompute×5` 后 `size=0` ✗；等 800 ms 后 **5/5 仍存活**（对照：用 `set` 建的 5 个只剩 2 个 ✓）；`remove` 一个后 `size=-1` ✗。

### 1.3 [严重｜正确性] `CACHE-3` `ConcHashMap.add` 覆盖已存在键时多计 size；`clear()` 不归零 ⇒ `size`/`isEmpty` 长期失真 → ✅已修复（2026-10-05）

**✅ 修复标记（2026-10-05）**：分支 `review/f_cache`，**代码、用例、本标记在同一提交**（提交 `14733baf`：`fix(f_cache): CACHE-3 add 覆盖记账 + clear 归零（bug-cache §1.3 修复标记）`）。

- 改动（`src/ConcHashMap.cj`）：`add` 只在段级 `add` 返回 `None`（确为新增）时 `incrSize()`（`:260-268`）；`clear()` 清空各段后 `size_.store(0)`（`:325-331`）—— `destroy()` 走 `clear()`，一并归零。
- 用例（`src/HeapCache_test.cj`）：`testAddOverwriteCountsOnce`（同键 `add`×2 ⇒ `size==1`，再 `add` 一个新键 ⇒ `2`）、`testClearResetsSize`（`set`×3 ⇒ 3；`clear()` ⇒ 0；再 `set` ⇒ 1；`destroy()` ⇒ 0）。
- 测量证据：**修复前** PASSED 4 / **FAILED 2**（`Assert Failed: (1 == map.size)` 实测 `2`；`(0 == cache.size)` 实测 `3`，EXIT=1）→ **修复后** = **6/6 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**；f_cache 自身编译警告仍 2 条。日志 `/tmp/cache3_before.log`、`/tmp/cache3_after.log`。
- 影响面：`HeapCache.clear()` / `destroy()` 之后 `size` 与 `isEmpty()` 恢复同口径；`maxSize` 判定不再被幻影计数放大 ⇒ 不再出现「刚清空就被提前淘汰」。

**位置**：`src/ConcHashMap.cj:260-264`、`:320-324`

```260:264:f_cache/src/ConcHashMap.cj
    func add(key: String, value: V): Option<V> {
        let opt = segment(key).add(key, value)
        incrSize()          // ← 未判断 opt 是否 None（是否真的新增）
        return opt
    }
```

```320:324:f_cache/src/ConcHashMap.cj
    public func clear(): Unit {
        for (segm in segments) {
            segm.clear()
        }
    }                        // ← 没有 size_.store(0)
```

**影响**：`size` 只增不清 ⇒ ①`HeapCache.clear()` 之后 `size` 仍是旧值，`isEmpty()` 为 false；②`checkOverSize` 用 `store.size > maxSize` 判定 ⇒ 幻影计数会让**真实条目被提前淘汰**（刚 clear 完再写入时尤其明显）；③`add` 的覆盖路径虽被 `HeapCache.set`（先 `get` 再决定）绕开，但两线程同时 `get`=None 后都 `add` 的竞态下会多计。

**修法**：`if (opt.isNone()) { incrSize() }`；`clear()` 内 `size_.store(0)`（`size_` 是 `AtomicInt64`，`:175`）。

**DT**：同一键 `add` 两次 ⇒ `size==1`；三个键 ⇒ `size==3`；`clear()`/`HeapCache.clear()` 后 ⇒ `size==0`、`isEmpty()==true`；`destroy()` 后同样为 0。

**实测（探针 P9a/P9c/P2g）**：同键 `add` 两次 ⇒ `size=2` ✗；`clear()` 后 ⇒ `size=3` ✗；`HeapCache.clear()` 后 ⇒ `size=1`、`isEmpty=false` ✗。

---

## 2. 中（5 条）

### 2.1 [中｜并发/契约] `CACHE-4` 用户代码在**段写锁内**执行：`removeIf` 谓词与 `getOrCompute` 的 callable 都会阻塞同段全部操作

**位置**：`src/SyncLinkedHashMap.cj:44-58`（`computeIfAbsent` 在 `synchronized(wl)` 内调用 `callable()`）、`:64-68`（`removeIf` 在写锁内跑谓词）；`src/ConcHashMap.cj:305-315`（逐段持有写锁）；`src/HeapCache.cj:219-221`（谓词包装）

```44:58:f_cache/src/SyncLinkedHashMap.cj
    public func computeIfAbsent(key: String, callable: () -> V): V {
        if (let Some(v) <- get(key)) {
            v
        } else {
            synchronized(wl) {
                if (let Some(v) <- map.get(key)) {
                    v
                } else {
                    let v = callable()      // ← 用户代码在段写锁内
                    map.add(key, v)
                    v
                }
            }
        }
    }
```

**影响**：
- `getOrCompute` 的 callable 在仓库里是**昂贵操作**：`f_data` 的 `doCompile`、`f_regex` 的正则编译、`f_orm` 的 `cangjieLex`+DSL 解析 ⇒ 一次未命中就会让**该段所有键**的读写（`get`/`set`/`contains`/`remove`，含其他线程）排队等待；
- `removeIf` 的谓词同理；谓词/回调用**另一线程**回访同段（如 `spawn { cache.get(k) }.get()`）会**死锁**（std 的 `ReadWriteLock` 可重入 ⇒ 同线程回读不会死锁，见 §6 已排除假设）；
- 该限制在 `README.md` 中没有任何说明（std 的 `ConcurrentHashMap.entryView` 明确写了「fn 中不能并发调用 entryView/remove/replace」，本模块没有）。

**修法**：①`computeIfAbsent` 改为「锁内只查、锁外计算、锁内二次判定写入」（注意避免重复计算——可用 `Box`/`OnceCell` 或允许重复计算后丢弃）；②或在文档里明确「callable/谓词在一个分段的写锁内执行，不得跨线程回访同一缓存」。`f_data`/`f_orm`/`f_regex` 的高成本 callable 建议先算后存（`set`）而不是 `getOrCompute`。

**DT**：谓词内 `sleep(400ms)`，另一线程读**同段**键耗时 ≥ 300 ms、读**异段**键耗时 < 1 ms。

**实测（探针 P10）**：谓词内 `sleep(400 ms)` 期间，同段 `get` = **292.87 ms**，异段 `get` = **0.0228 ms**（≈ 1.3 万倍差）。

### 2.2 [中｜资源] `CACHE-5` 线程与实例泄漏：每实例 1 个阻塞淘汰线程 + 1 条全局强引用；`WeakHeapCache` 另加 1 个 `while(true)` 线程

**位置**：`src/HeapCache.cj:49-57`、`:43`；`src/WeakHeapCache.cj:48-55`

```49:57:f_cache/src/HeapCache.cj
    private func onEviction(): LinkedBlockingQueue<(String, V)> {
        let q = LinkedBlockingQueue<(String, V)>()
        spawn {
            while (let (k, v) <- q.remove()) {
                evictionCallback(k, v)
            }
        }
        q
    }
```

std 契约（`std.collection.concurrent.LinkedBlockingQueue.remove()`）：**阻塞出队，队列空则阻塞等待**，返回类型为元素类型 ⇒ 这里的 `while (let … <- q.remove())` 恒真，线程**永远不会退出**（没有队列关闭语义）。`destroy()`（`:233-236`）只置 `alive=false` 并 `store.clear()`，不结束该线程，也不释放队列。

`ExitCallbacks.atExit(254, destroy)`（`:43`）把每个实例注册进 `f_base` 的**全局静态表**（`f_base/src/signal.cj:36-58`，`TreeMap<UInt16, ArrayList<() -> Unit>>`，追加且从不清理）⇒ 该表强引用每个 `HeapCache` 实例 ⇒ 被应用丢弃的实例（连同它的线程）永远不会被 GC 回收。

`WeakHeapCache.init`（`src/WeakHeapCache.cj:48-55`）为每个实例 spawn 一个 `while (true) { removeIf; sleep(1s) }` 的清扫线程，且类里**没有** close/destroy 入口。

**影响**：长生命周期进程里反复创建缓存实例（例如按租户/按请求创建 `HeapCacheStore`）会累积线程与不可回收对象；进程退出不受影响（仓颉运行时不等待 spawn 线程，见 §6）。

**修法**：①给淘汰队列一个关闭语义（用 `tryRemove(timeout)` + `alive` 判定退出循环，或 `remove(timeout)` 返回 `None` 时检查 `alive`）；②`destroy()` 里等待/终止消费线程；③`atExit` 注册改为「按需注册一次」或提供注销；④`WeakHeapCache` 增加 `close()`。

**DT**：创建 N 个缓存实例并 `destroy()`，断言消费线程数回落（可用线程计数或队列可关闭性间接断言）；`WeakHeapCache.close()` 后清扫线程退出。

### 2.3 [中｜正确性] `CACHE-6` `once()` / `prolong()` 不做过期判定 ⇒ 可“复活”已过期但未被清扫的条目

**位置**：`src/HeapCache.cj:144-175`（对比 `get`/`contains` 在 `:135-140` 会先判 `evicated(p)`）

```144:153:f_cache/src/HeapCache.cj
    public func once(key: String): Bool {
        match (store.get(key)) {
            case Some(p) => synchronized(p.lock) {
                p.load()
                p.once = true          // ← 无 evicated 判定
                true
            }
            case _ => false
        }
    }
```

**影响**：清扫是按 `checkDuration` 周期跑的（默认 1 s），期间过期条目仍在 map 里 ⇒ `get`/`contains` 认为「不存在」，而 `once()` 返回 true、`prolong()` 返回 true 并真的改变其寿命（`p.maxLife = life`）⇒ **同一条目在两个 API 集合里有两种存在性**；`prolong` 还会把一个本该死掉的条目救活（若调用方本意是「续期一个存在的条目」，对已过期条目的续期语义需要明确）。

**修法**：两处 `Some(p)` 分支加 `where` 守卫（`!evicated(p)`），或明确文档化「once/prolong 对未清扫的过期条目仍生效」。

**DT**：`set(k,v)` → `set(k,v,life:100ms)` → 等 300 ms（< checkDuration）⇒ `contains==false`、`once(k)==false`、`prolong(k,5s)==false`。

**实测（探针 P3a/P3b/P3c）**：`contains=false` ✓（已过期）、`once=true` ✗、`prolong=true` ✗ 且随后 `contains=true`（被复活）✗。

### 2.4 [中｜内存] `CACHE-7` `destroy()` 之后再 `set` 的条目永不被清理（定时器已停、仍可写）

**位置**：`src/HeapCache.cj:233-236`、`:58-72`

`destroy()` 置 `alive=false` 并 `store.clear()`；定时器回调下一次执行时 `alive=false` ⇒ `checkTimeout` 的谓词对**所有**条目返回 true（清空），随后回调返回 `None<Duration>` ⇒ **定时器永久停止**（`Timer.after` 契约：返回 None 即失效）。但 `set`/`get`/`getOrCompute` 都没有 `alive` 守卫 ⇒ 之后写入的条目：既没有过期清扫，也没有 maxSize 淘汰。

**影响**：文档（`README.md:88`）只说「销毁的堆缓存不可再用」，实现上却是「可继续写入且永不回收」⇒ 误用（忘记销毁、或销毁后复用同一实例）会得到只增不减的 map；`size` 也随之永久虚高（叠加 `CACHE-3`）。

**修法**：`set`/`getOrCompute` 在 `!alive.load()` 时抛 `IllegalStateException`（与文档一致），或 `destroy()` 后彻底禁用；二期再考虑让 `checkTimeout` 在销毁时清空而不依赖「最后一次 tick」。

**DT**：`destroy()` → 等 1 个检查周期 → `set(k1)/set(k2)` → 再等 1 个周期 ⇒ `size==0`（当前实测 2）、或按文档抛异常。

**实测（探针 P7/P8）**：`destroy()` 后 `set` 两次、等 1 s（`maxLife=300ms`、`maxSize=1`）：`d1=false d2=false`（按寿命已过期）但 **`size=2` 且此后不降** ⇒ 过期条目永驻。

### 2.5 [中｜并发] `CACHE-8` `Priority` 比较基线字段无锁读写竞争；`compare` 的“保护新生”分支疑似写反且含不可达分支

**位置**：`src/Priority.cj:127-141`（`lastCheckedTime` / `usedCountUtilLastChecked` 无锁读取）、`:167-170`（`updateLastChecked` 无锁写入，由定时线程经 `HeapCache.cj:126-128` 调用）、`:48-88`（`compare`）

`lastChecked` 与 `usedUtilLastChecked` 是普通字段：定时线程在 `checkOverSize` 末尾批量写入（此时**不持有** `p.lock`），业务线程在 `compare`（被 `PriorityQueue` 调用）里无锁读取 ⇒ 无同步保证（`usedCount` 是 `AtomicInt64` ✓、`lastUsed`/`maxLife_` 有锁 ✓）。

`compare` 的分支谱系也与注释不符（`:74-88`）：

```79:87:f_cache/src/Priority.cj
        if (ageSub >= -1.0 && ageSub <= 1.0) {
            cmp() //两个待比较数据都在最近一个生命周期内刚访问过
        } else if (ageSub > 1.0) { //两个待比较数据的最后访问时间距今的时间差超过一个生命周期，保护新生
            GT
        } else if (age < -1.0) {
            LT
        } else { //两个待比较数据的最后访问时间距今都超过了一个生命周期，成年了不需要保护了
            cmp()
        }
```

- `age = (现在 - 最后使用时间)/checkDuration` 在正常时钟下 **≥ 0** ⇒ `age < -1.0` 分支不可达（除非时钟回拨）；
- 注释说「保护新生」，但只对 `ageSub > 1.0`（本对象**更老**）返回 `GT`；本对象**更新**的一侧落到最后一个 `cmp()` 分支 ⇒ 保护逻辑不对称、疑似写反（按 `PriorityQueue` 默认取堆顶最小元素理解）。

**影响**：淘汰顺序在高并发下不稳定（基线字段读到的可能是旧值），且“新生保护”是否生效不可判定；现有用例（`HeapCache_test.test`）的淘汰结果由「使用次数」主键决定（`cmp()` 的第一项），**覆盖不到**这条分支 ⇒ 需要作者确认意图后再补用例。

**修法**：①`lastChecked`/`usedUtilLastChecked` 读写纳入 `p.lock`（或改原子类型）；②按设计意图厘清 `ageSub`/`age` 两侧的分支并删除不可达分支。

**DT（待作者确认后再定）**：构造两个仅「最后使用时间」不同的条目（`checkDuration` 取 1 s），断言淘汰的是更老的一个。

---

## 3. 低危（8 条）/ 待验证（2 条）

### 3.1 低危（8 条）

- **`CACHE-L1` `ConcHashMapKeys.contains(all!)` 是「任一包含」而非「全部包含」**：`src/ConcHashMap.cj:75-80` 在循环里 `return true` 命中即返回 ⇒ 与 std `contains(all:)` 语义相反；且 `ConcHashMapKeys`/`ConcHashMapValues`/两个 Iterator（`src/ConcHashMap.cj:22-133`）在本仓库**无任何使用点**（死代码，只有 `ConcHashMapKeysIterator` 经 `keys()`… 实际 `ConcHashMap` 也没有 `keys()`/`values()` 成员）。修法：改成「全部命中才 true」，或直接删除这 4 个类。**实测（P4）**：`contains(all: ['b','a'])` 在只有 `'a'` 时返回 `true`。
- **`CACHE-L2` `WeakHeapCache.get` 的 lambda 返回值被丢弃**（`src/WeakHeapCache.cj:81-89`，编译警告 `unused expression` 指向 `:86`）：`entryView` 的回调返回 `Unit`，真正取值靠 `entryView` 自身返回 `?V`；写法容易误导（看起来像回调在产出结果）。`set` 里的 `try/finally`（`:59-68`）同样绕。修法：把回调体写成纯副作用（显式 `()`），或直接换成「`get` 未命中就用 `add`」的两步写法并注释原子性理由。
- **`CACHE-L3` `WeakKey` 把「键」放进弱引用**（`src/WeakHeapCache.cj:22-45`）：键是每次调用新构造的 `Box<String>`，只被 `WeakRef` 弱引用 ⇒ 在 `CleanupPolicy.DEFERRED`（GC 尽量保活、内存不足才回收）下平时可用（**实测 P5 通过**），但内存紧张时键会被回收 ⇒ 值仍被强引用时条目也会静默消失、且 `get` 期间键可能失效导致 miss。弱引用缓存的常规做法是**键强、值弱**。修法：`WeakKey` 持强引用（`Box<String>`/`String`），只让值 `WeakRef`。顺带：每次 `get`/`set` 都新分配 `Box<String>+WeakRef`（热路径额外分配），键强引用后也可缓存键对象。
- **`CACHE-L4` 两处编译警告**（本次构建中 f_cache 自身仅 2 条）：`src/HeapCache.cj:20` `unused import 'std.env.atExit'`（实际用的是 `f_base` 的 `ExitCallbacks.atExit`）；`src/WeakHeapCache.cj:86` `unused expression`（见 L2）。
- **`CACHE-L5` 命名/文档细节**：`HeapCache.evicated`（`src/HeapCache.cj:131-133`）应为 expired 语义；`README.md:102`「弱引用堆缓存」一节把 `WeakHeapCache` 的 `remove`/`removeIf`/`size` 等成员列全了，但没有说明**清扫有 1 s 延迟**（`size` 含未被清扫的失效条目，实测 `P5` 的 `size` 与 `contains` 口径差 ≤ 1 s）。
- **`CACHE-L6` 迭代一致性未文档化**：`SyncLinkedHashMap.iterator()`（`src/SyncLinkedHashMap.cj:26-28`）在**锁外**创建底层迭代器、每次 `next()` 才取读锁；`ConcHashMapIterator.next()`（`src/ConcHashMap.cj:146-155`）跨段无快照，`doNextSegment` 的越界分支与循环条件 `cur <= m.concurrency`（`:147`）冗余。定时淘汰与业务读并发时迭代结果不保证包含本轮新增——可接受，但应写进 README。
- **`CACHE-L7` 惰性过期与口径差**：`get` 对已过期条目只返回 `None`，不摘除（`src/HeapCache.cj:135-140`）⇒ `size` 会包含「已过期未清扫」的条目（最长 `checkDuration`）。属常见惰性过期设计，但与 `contains` 的口径差异未文档化（叠加 `CACHE-7` 后会变成永驻）。
- **`CACHE-L8` 用例覆盖极薄**：整个模块只有 1 个用例（`src/HeapCache_test.cj`，8.02 s，绝大部分是 `sleep`），且只覆盖 `set`/`get`/`contains`/`getOrDefault` 与「maxSize=2 时最新的先被淘汰」；`WeakHeapCache`、`ConcHashMap`、`Priority`、`getOrCompute` 系列、`once`/`prolong`、`removeIf`、`destroy`、`evictionCallback` 全部无用例。建议补测（可直接采用本报告各条的 DT）。

### 3.2 待验证（2 条，需与作者确认或压测）

- **`CACHE-V1` `Priority.compare` 的淘汰顺序是否符合设计**（见 `CACHE-8`）：需作者确认「保护新生」的期望方向，再构造仅一维差异的用例（使用次数 / 最后使用时间 / 出生时间）逐一固定；当前唯一用例靠使用次数决定结果，覆盖不到分支。
- **`CACHE-V2` `WeakRef` 键在真实内存压力下的丢失率**：`CACHE-L3` 的后果需要压测（持续分配 + 观察 `WeakHeapCache` 命中率/条目数）才能量化；本次未做（无 GC 触发入口，且 `DEFERRED` 策略下小规模压测不必然触发）。

---

## 4. 覆盖面（结构小结 + 已确认「无实例」的维度）

**结构**：`f_cache` = 强引用缓存 `HeapCache`（定时线程 + 分段并发 map）+ 弱引用缓存 `WeakHeapCache`（`std.collection.concurrent.ConcurrentHashMap` + 弱引用键值 + 1 s 清扫线程）+ 三个内部支撑件 `ConcHashMap`（分段，段内 `SyncLinkedHashMap`，读写锁；自维护 `size_`）、`SyncLinkedHashMap`（`LinkedHashMap` + 读写锁）、`Priority`（寿命/使用次数/出生时间，供淘汰排序）。运行期线程：1 个 `Timer` 调度（`Timer.after` 自续期）、1 个淘汰消费线程（`HeapCache` per instance）、1 个清扫线程（`WeakHeapCache` per instance）。

**已确认「无实例」的维度**：

- 无文件 / 网络 / CFFI / 原生内存 / 句柄类资源；无 reflect（`f_cache` 无 `std.reflect`），无宏。
- 无 `ThreadLocal`、无对象池；唯一的进程级静态可变状态是 `f_base` 的 `ExitCallbacks` 注册表（被 `HeapCache` 用来注册 `destroy`）与各模块里的静态缓存实例（`f_data`/`f_orm`/`f_regex` 各一个）。
- 无持久化/序列化；无「键过期通知」以外的副作用（`evictionCallback` 是唯一对外回调，且**实测通路正常**，见 §5 P6）。

**仓库内使用面**：`f_data/src/path/CacheDataPath.cj:21,24`（`getOrCompute`）、`f_orm/src/base/SqlDSL.cj:45,47`（`getOrCompute`）、`f_regex/src/RegexFromString.cj:28,61`（`getOrCompute`）、`f_jwt/src/JwtIdCache.cj:40-63`（`set(life:)`/`set(dieAt:)`）、`f_security/src/HeapCacheStore.cj:19-24`（`set` 默认寿命 ✓ 不受 `CACHE-1` 影响）、`fdemo/user/src/util/UserSessionCache.cj:27`（经 f_security）、`src/cache/cache.cj:18`（对外 re-export）。`WeakHeapCache` **无任何使用者**、也无用例（其缺陷目前只在库内暴露）。

---

## 5. 基线与验证状态

| 项 | 命令 | 结果 |
|---|---|---|
| 既有用例 | `cjpm test --no-capture-output`（WSL Ubuntu-24.04，SDK 1.3.0-alpha.20261001001050） | **1/1 PASSED，ERROR 0，FAILED 0，`cjpm test success`（EXIT=0）**；唯一用例 `test` 耗时 8 024 104 487 ns（≈ 8.02 s，主要是 `sleep`）。日志 `/tmp/cache_base.log` |
| 编译警告 | 同一构建 | 构建过程共 30 条 warning（含依赖模块 f_base/f_collection），**f_cache 自身 2 条**：`HeapCache.cj:20` unused import、`WeakHeapCache.cj:86` unused expression（见 `CACHE-L4`） |

**探针实测**（临时用例，跑完即删，未入库）：

| 探针 | 断言的现象 | 实测 | 日志 |
|---|---|---|---|
| P1a/b/c | 新建键 `set(life:)` / `set(dieAt:)` 是否生效 | 新建 `true`（不生效）／已存在 `false`（生效）／dieAt `true` | `/tmp/cache_probe1.log`、`/tmp/cache_probe3.log` |
| P2a-e | `getOrCompute` 的 size 记账与 maxSize 淘汰 | `size=0`；800 ms 后 5/5 存活；对照（`set`）2/5 | 同上 |
| P2f/P2g | 覆盖 size / clear 归零 | `set` 两次 `size=1` ✓（该路径无此问题）；`clear()` 后 `size=1` ✗ | 同上 |
| P3a/b/c | `once`/`prolong` 对已过期条目 | `contains=false`；`once=true`；`prolong=true` 且复活 | 同上 |
| P4 | `ConcHashMapKeys.contains(all:)` | `['b','a']` ⇒ `true` | 同上 |
| P5 | `WeakHeapCache` 基本可用性 | `set→get=Some`、`getOrStore`、`remove` 全部正常（键弱引用当前不致命） | 同上 |
| P6 | 淘汰回调通路（对照） | maxSize 淘汰触发回调 1 次 ✓ | 同上 |
| P7/P8 | `destroy()` 语义 | 销毁后写入的条目过期仍计数：`d1=false d2=false`、`size=2` 且不降 | `/tmp/cache_probe2.log` |
| P9a-c | `ConcHashMap` 记账 | 同键 `add`×2 ⇒ `size=2`；3 键 ⇒ 3；`clear()` 后 ⇒ 3 | `/tmp/cache_probe2.log` |
| P10 | 谓词持段写锁的阻塞面 | 同段 `get` **292.87 ms** vs 异段 **0.0228 ms** | `/tmp/cache_probe3.log` |

探针原文（节选，完整版已在审查后删除）：

```cangjie
// P1：新建键 set(life=100ms) 后 300ms contains=true（期望 false）
let c = HeapCache<ProbeVal>(maxLife: Duration.second * 30, maxSize: 100, checkDuration: Duration.second * 30)
c.set('new', ProbeVal(1), life: Duration.millisecond * 100)
sleep(Duration.millisecond * 300)
println('P1a contains=${c.contains("new")}')

// P2：maxSize=2 的缓存用 getOrCompute 建 5 个键
for (i in 0..5) { c.getOrCompute('g${i}') {ProbeVal(i)} }
println('P2a size=${c.size}')                       // 0（期望 5）
// P10：谓词内 sleep 400ms，另一线程读同段/异段键
c.removeIf { k, _ => if (k == 'victim') { sleep(Duration.millisecond * 400) }; false }
```

**未做**：基准（`cjpm bench`）、堆/RSS 采样（`cjprof heap`）、长稳压力（线程/实例累积速率）、`WeakRef` 键丢失率的压测、真实业务路径（f_data 编译 / f_regex 编译 / f_jwt 过期语义）的端到端复现。`CACHE-1`/`CACHE-2` 的业务影响是按调用点静态推断 + 库内探针实测，**未**在四个使用模块里端到端验证。

---

## 6. 审查方法与备注

- 本次审查**只读**（未改动 `f_cache` 任何生产代码）；报告落在本分支 `.autocode/bugs/bug-cache.md`（与 `bug.md`、`bug-mockdb.md` 同目录）。探针文件 `src/zz_review_probe*_test.cj` 与临时脚本已删除、未入库。
- 依赖契约以**本地官方文档**为准（`cangjie-coding`/`cangjie-doc-lookup` 技能）：`LinkedBlockingQueue.remove()` 阻塞语义、`ReadWriteLock` **可重入**（写锁持有者可再取读锁 ⇒ 同线程回读不死锁）、`WeakRef`+`CleanupPolicy.DEFERRED`（内存不足才回收）、`Timer.after` 的回调返回值语义、`MapEntryView`/`entryView`（空视图不插入、置 `None` 等价删除、回调内不得并发调用 entryView/remove/replace）、`Duration` 单位常量、`Box<T>` 无内容语义的 `hashCode` 覆写（`WeakKey` 靠 `Box<String>` 内层字符串的 `hashCode` 参与分段 —— 实测可用，未列为缺陷）。
- **已排除的假设**（写在这里避免后续重复怀疑）：① `removeIf` 谓词在同线程回读同段**不会**死锁（`ReadWriteLock` 可重入，已核对文档）；② 淘汰回调不会丢（`P6` 触发正常）；③ `WeakHeapCache` 基本读写正常（`P5`）；④ `Priority.compare` 在第一层比较上的语义与现有用例一致（用例结果由使用次数决定），因此 §2.5 只列「疑似写反/不可达分支 + 无锁读取」，不下「淘汰顺序错误」的结论。
- 未纳入本报告的相邻模块问题：`f_base` 的 `ExitCallbacks` 只有注册没有注销（本报告只在 `CACHE-5` 里引用其后果）、`f_collection` 的 `LinkedHashMap`/`PriorityQueue` 内部问题（另有待专门审查）。
- 复现命令（在本 worktree 内）：

```bash
source /mnt/d/docs/work/cangjie/cangjie.sh
cd /mnt/d/docs/work/cangjie/projects/fountain/.worktrees/review-f_cache/f_cache
cjpm test --no-capture-output        # 基线 1/1；探针文件已删除故当前只剩该用例
```
