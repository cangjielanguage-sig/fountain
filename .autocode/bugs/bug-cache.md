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
4. `CACHE-4`（§2.1）用户代码（`removeIf` 谓词 / `getOrCompute` 的 callable）在**段写锁内**执行 —— 同段操作被串行阻塞（实测：同段 292.87 ms vs 异段 0.0228 ms）　**✅已修复（2026-10-05，方案 C，见 §2.1 修复标记）**
5. `CACHE-5`（§2.2）每个 `HeapCache` 实例泄漏 1 个阻塞线程 + 1 条全局 `atExit` 强引用；`WeakHeapCache` 另泄漏 1 个 `while(true)` 清扫线程　**✅已修复（2026-10-05：实现 `Resource` + `close()` 取消线程；② 的 `atExit` 注册已改为持弱引用，`close()` 后实例可回收，见 §2.2）**
6. `CACHE-6`（§2.3）`once()` / `prolong()` 不判过期 ⇒ 可“复活”已过期条目（实测复现）　**✅已修复（2026-10-05，方案 A，见 §2.3 修复标记）**
7. `CACHE-7`（§2.4）缓存关闭（原 `destroy()`，现 `close()`）之后再写入的条目**永不被清理**（实测复现）　**✅已修复（2026-10-05，方案 A2 + 主动清空/join，见 §2.4 修复标记）**
8. `CACHE-8`（§2.5）`Priority` 比较基线的无锁竞争 + `compare` 的“保护新生”分支写反　**✅ 已修复（2026-10-05，①+②：② 按「保护新生」语义对称化年龄门并修正两条 recency 判据，④⑤ 两级 tie-break 亦已同向统一，见 §2.5）**
9. §3 低危 8 条已全清（见 §3.1）；待验证：`V1` 已了结；`V2` 已降级为**观测项**（不单造压测，随四个使用模块的端到端验证一起看，见 §3.2）

> 修复进度（2026-10-05）：§1 的 3 条严重级（`CACHE-1` = `3171d664`、`CACHE-2` = `0e3d70d6`、`CACHE-3` = `14733baf`）已修复并并入 `sts/1.3.x`（`0448df98` 把主线拉进分支、`4a01a26f` 合入主分支，合并后主工作区复跑 6/6 PASSED）；**§2.1 `CACHE-4` 已按方案 C 修复并并入 `sts/1.3.x`**（callable 移出段写锁 + `removeIf` 两阶段，见 §2.1；`302bd9f2` 拉齐主线进分支、`e131fa7f` 合入主分支）；**§2.2 `CACHE-5` 已修复并并入 `sts/1.3.x`**（实现 `Resource` + `close()` 取消内部线程；按指示删除 `destroy`、`atExit` 注册与用例统一改 `close()`，原 `testDestroyStopsEvictionThread` 更名 `testCloseStopsEvictionThread`，见 §2.2；`2b49dfc1` 拉齐主线进分支、`eb8363c8` 合入主分支）；**§2.3 `CACHE-6` 已修复并并入 `sts/1.3.x`**（`once`/`prolong` 拒绝过期条目，见 §2.3；`8dbe2fc8` 拉齐主线进分支、`5fbe5e5f` 合入主分支）；**§2.4 `CACHE-7` 已修复并并入 `sts/1.3.x`**（`close` 主动清空并等内部线程结束后再返回 + 关闭后一切操作抛 `IllegalStateException`，见 §2.4）；**§2.5 `CACHE-8` 已修复**（① 比较基线字段的读写纳入 `p.lock`；② 年龄门对称化 + `cmp()` 的两条 recency 判据按「保护新生」修正；④⑤ 两级 tie-break 亦已同向统一，见 §2.5）；**§2.2 的 ②（`atExit` 注册持强引用）已修复**（改为 `WeakRef<HeapCache<V>>` + `CleanupPolicy.EAGER` 的弱引用闭包 ⇒ 关闭后实例可被 GC 回收，退出时自动 `close()` 的语义不变，见 §2.2 ②；分支 `review/f_cache` 上待并入）；**已并入 `sts/1.3.x`**（`862eaf15` 拉齐主线进分支、`681f5156` 合入主分支，冲突标记清理 `7b69364e`/`f7711fc2`）；**§3 低危 8 条已全清**（`L4`+`L2` 修复 ⇒ 编译警告 2 → 0；`L1`/`L3` 修复并补用例、`L8` 补齐用例、`L5`~`L7` 命名与文档，均见 §3.1）；**§5 的基准与堆/RSS 采样已补做**（`cjpm bench` 4 条 + `cjprof heap`/`/proc` 探针，逐条确认 `CACHE-8`/`CACHE-4`/`CACHE-5`/`CACHE-2`/`CACHE-3`，见 §5「基准与采样」），仅 `V2` 观测项与「长稳压力」未做。用例 1 → 27 条（全绿）。

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

### 2.1 [中｜并发/契约] `CACHE-4` 用户代码在**段写锁内**执行：`removeIf` 谓词与 `getOrCompute` 的 callable 都会阻塞同段全部操作 → ✅已修复（2026-10-05，方案 C）

**✅ 修复标记（2026-10-05，方案 C：callable 移出锁 + `removeIf` 两阶段）**：分支 `review/f_cache`，**代码、用例、README、本标记在同一提交**（提交 `b772f1a5`：`fix(f_cache): CACHE-4 用户代码移出段写锁（callable 锁外计算 + removeIf 两阶段）（bug-cache §2.1 修复标记）`）。

- 改动：
  - `src/SyncLinkedHashMap.cj`：`computeIfAbsentCounted` 把 `callable()` 移到段写锁**之外**（锁内只做「查 → 二次判定 → 写」，重复计算的结果被丢弃）；新增 `removeIfOutside`（读锁取快照 → 锁外跑谓词 → 写锁按 key 删，返回实际删除数）；原 `removeIf` 改名 `removeIfLocked`（谓词在写锁内，保留给定时清扫）。
  - `src/ConcHashMap.cj`：`removeIf` 改为两阶段版（按删除数 `size_.fetchSub`）；新增 `removeIfLocked`（锁内版，带 `decrSize`）。
  - `src/HeapCache.cj`：`checkTimeout` 改走 `removeIfLocked`；公开 `removeIf` 走两阶段 ⇒ 用户谓词不再持段锁。
- 契约变化（有意，已写入 `f_cache/README.md` 新增的「并发与约定」）：① `getOrCompute` 的 callable 在段锁外执行 ⇒ **同一键可能被并发计算多次、只有第一次的结果落库**（纯计算/幂等 callable 无影响）；② `removeIf` 是两阶段 ⇒ 「判定—删除」不再原子，两阶段之间新写入的条目也可能按快照里的旧值被删除；需要原子且谓词廉价时用内部的 `removeIfLocked`；③ 顺带写明 `size` 含「已过期但未清扫」条目的口径（覆盖 `CACHE-L7` 的文档诉求）。
- 用例（`src/HeapCache_test.cj`）：`testGetOrComputeComputesOnceWhenPresent`（已存在时 callable 只被调用 1 次）、`testGetOrComputeDoesNotHoldSegmentLock`（callable 睡 400 ms，同段 `get` < 100 ms）、`testRemoveIfDoesNotHoldSegmentLock`（谓词睡 400 ms，同段 `get` < 100 ms；并断言谓词为真的被删、其余保留）。
- 测量证据：**修复前** PASSED 7 / **FAILED 2**（两条并发用例均报 `Assert Failed: (true == cost.value < 100.0)` —— 同段 `get` 被拖住约 300 ms，EXIT=1）→ **修复后** = **9/9 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**；f_cache 自身编译警告仍 2 条、无新增。日志 `/tmp/cache4_before.log`、`/tmp/cache4_after.log`。
- 影响面：`f_data` / `f_orm` / `f_regex` 三处 `getOrCompute` 的昂贵 callable 不再阻塞同段读写（并发未命中时可能重复编译一次，重复结果被丢弃）；仓库内暂无 `HeapCache.removeIf` 的调用方。

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

### 2.2 [中｜资源] `CACHE-5` 线程与实例泄漏：每实例 1 个阻塞淘汰线程 + 1 条全局强引用；`WeakHeapCache` 另加 1 个 `while(true)` 线程 → ✅已修复（2026-10-05，实现 `Resource` + 协作取消）

**✅ 修复标记（2026-10-05，方案：两个缓存实现 `Resource`，用线程句柄 + `Future.cancel()` + `hasPendingCancellation` 协作取消）**：分支 `review/f_cache`，**代码、用例、README、本标记在同一提交**（提交 `981e1005`：`feat(f_cache): HeapCache/WeakHeapCache 实现 Resource，close() 取消内部线程（bug-cache §2.2 修复标记）`；按指示删除 `destroy` 并统一 `close()` 的补做为 `0b9d3240`）。

- 改动：
  - `src/HeapCache.cj`：类改为 `<: Resource`；`alive` 换成 `closedFlag`；新增两个**内部线程/定时器句柄字段** `evictionTask: ?Future<Unit>`、`timerHandle: ?Timer`（另有轮询常量 `EVICTION_POLL_INTERVAL = 100 ms`）；淘汰消费线程改为「`q.remove(轮询间隔)` + 每轮检查 `Thread.currentThread.hasPendingCancellation`」，收到取消后把**已入队**的淘汰回调投递完再退出；新增 `close()`（置位 + `Timer.cancel()` + `Future.cancel()` + `store.clear()`，可重复调用）与 `isClosed()`；`destroy()` 保留为 `close()` 的别名。
  - `src/WeakHeapCache.cj`：类改为 `<: Resource`；新增 `closedFlag` 与 `cleanerTask: ?Future<Unit>`（清扫周期常量 `CLEAN_INTERVAL = 1 s`）；清扫线程由 `while (true)` 改为 `while (!Thread.currentThread.hasPendingCancellation)`；新增 `close()`/`isClosed()`。
  - `f_cache/README.md`「并发与约定」补 `Resource` 与关闭语义（含「最迟 100 ms / 1 s 退出」「关闭后不再自动清理」）。
- 用例（`src/HeapCache_test.cj`）：`testDestroyStopsEvictionThread`（**钉住用例**，只用修复前已存在的 `destroy()` + 内部句柄）、`testHeapCacheIsResource`、`testWeakHeapCacheIsResource`（这两条属**接口补齐型**：`close()`/`isClosed()` 修复前不存在、断言写不出来 ⇒ 没有「修复前失败」证据，与 `MOCK-L6` 同类）。
- 测量证据：**修复前** PASSED 9 / **FAILED 1**（`testDestroyStopsEvictionThread` 卡满 3 006 740 863 ns ≈ 3.01 s —— `f.get(3 s)` 抛 `TimeoutException`，即 `destroy()` 后消费线程永不退出；EXIT=1）→ **修复后** = **12/12 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**：`testDestroyStopsEvictionThread` **421 729 ns（≈0.42 ms，线程立即退出）**、`testHeapCacheIsResource` ≈100.8 ms、`testWeakHeapCacheIsResource` ≈1.01 s（分别对应两个线程的轮询周期）；f_cache 自身编译警告仍 2 条。日志 `/tmp/cache5_before.log`、`/tmp/cache5_after.log`。
- 附带说明（2026-10-05 按指示补做）：`HeapCache.destroy()` **已删除**，全部调用点改为 `close()`（`atExit` 注册、用例；原 `testDestroyStopsEvictionThread` 更名 `testCloseStopsEvictionThread`，README 成员表同步）；`close()` 只负责线程/内存的释放，**关闭后 `set`/`get` 仍可调用**（`CACHE-7` 的语义另议，见 §2.4）。
- **✅ 已修复（本条目 ②，2026-10-05，方案 A：弱引用间接层）**：`ExitCallbacks.atExit(254, close)` 改为注册**只捕弱引用**的闭包（`src/HeapCache.cj` 构造函数：`let selfRef = WeakRef<HeapCache<V>>(this, CleanupPolicy.EAGER)` + `ExitCallbacks.atExit(254, {=> if (let Some(cache) <- selfRef.value) { cache.close() }})`）⇒ `f_base` 的全局注册表（`TreeMap<UInt16, ArrayList<() -> Unit>>`，**无注销 API**）不再是实例的强根，**`close()` 之后对象可被 GC 回收**；「进程退出时若实例仍在 ⇒ 自动 `close()`（把已入队的淘汰回调投递完）」的语义保持不变。`EAGER` 不会误伤未 close 的实例：那种实例被自己的定时器/消费线程闭包强引用着（不满足「不可达」），弱引用不会提前清掉它 —— 本条目真正解决的就是「已 close 的实例仍被钉住」。提交 `fae91596`：`fix(f_cache): CACHE-5 ② atExit 注册改持弱引用（bug-cache §2.2 ②）`。
  - 平台相关：`ExitCallbacks` 整体被 `@When[os != "Windows"]` 包着，Windows 上 `atExit` 是空实现 ⇒ 该泄漏只在非 Windows 平台存在（本改动在 Windows 上也无副作用）。
  - 诚实标注：**无确定性用例可钉**（仓颉没有公开的 GC 触发入口，用例里无法断言「对象被回收」）⇒ 验收 = 代码层论证（修复前强根 = 注册闭包捕获 `this`；现改为捕 `WeakRef`）+ 20 条用例全绿。注册表仍随实例数线性增长（每实例一条小闭包，与修复前相同）——若将来实例数很大，再考虑「进程级只注册一次」或给 `f_base` 加注销能力。
  - 相邻的独立条目：`HeapCache.cj:20` 的 `unused import 'std.env.atExit'` 当时未动，**已随 `CACHE-L4` 修复（2026-10-05）**。

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

### 2.3 [中｜正确性] `CACHE-6` `once()` / `prolong()` 不做过期判定 ⇒ 可“复活”已过期但未被清扫的条目 → ✅已修复（2026-10-05，方案 A）

**✅ 修复标记（2026-10-05，方案 A：与 `get`/`contains` 同口径）**：分支 `review/f_cache`，**代码、用例、README、本标记在同一提交**（提交 `2e642b0b`：`fix(f_cache): CACHE-6 once/prolong 拒绝已过期条目（bug-cache §2.3 修复标记）`）。

- 改动（`src/HeapCache.cj`）：`once`、`prolong(key, life!, once!)`、`prolong(key, deathTime)` 三个入口的 `case Some(p)` 加上 `where !evicated(p)` 守卫 ⇒ 已过期（即使尚未被定时清扫）的条目一律按「不存在」处理，与 `get`/`contains` 一致；不能再把过期条目「复活」。
- 用例（`src/HeapCache_test.cj`）：`testOnceRejectsExpiredEntry`、`testProlongRejectsExpiredEntry` —— 都是「`set` → `set(life: 100ms)`（更新路径）→ 等 300 ms（< checkDuration，保证未被定时清扫）」后断言 `contains`、`once`、两个 `prolong` 全为 `false`，且续期被拒后 `contains` 仍为 `false`。
- 测量证据：**修复前** PASSED 12 / **FAILED 2**（`Assert Failed: (false == cache.once('k'))` 实测 `true`；`(false == cache.prolong('k', Duration.second * 5))` 实测 `true`；EXIT=1）→ **修复后** = **14/14 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**；f_cache 自身编译警告仍 2 条。日志 `/tmp/cache6_before.log`、`/tmp/cache6_after.log`。
- 契约变化（有意，已写入 `f_cache/README.md`「并发与约定」）：过期条目不再能通过 `once`/`prolong` 续期/复活 ⇒ 调用方要「续期已过期条目」请改用 `set` 重建。仓库内目前**没有** `once`/`prolong` 的调用方（grep 确认），故无下游影响。

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

### 2.4 [中｜内存] `CACHE-7` `close()` 之后再 `set` 的条目永不被清理（定时器已停、仍可写） → ✅已修复（2026-10-05，方案 A2 + 主动清空/join）

**✅ 修复标记（2026-10-05，方案 A2：close 主动清空并等线程结束 + 关闭后一切操作抛异常）**：分支 `review/f_cache`，**代码、用例、README、本标记在同一提交**（提交 `65e5bc8d`：`fix(f_cache): CACHE-7 close 主动清空并等线程结束，关闭后一切操作抛异常（bug-cache §2.4 修复标记）`）。

- 改动：
  - `src/HeapCache.cj`：新增 `private func ensureOpen()`（关闭后抛 `IllegalStateException('heap cache is closed')`），`get`/`contains`/`once`/`prolong`×2/`set`×2/`getOrDefault`/`getOrStore`/`getOrCompute`×3/`remove`/`removeIf`/`size`/`clear` 共 16 个公开入口全部先校验；`close()` 改为「置位 → `Timer.cancel()` → **主动 `store.clear()`** → `Future.cancel()` → **`f.get()` 等消费线程结束**」⇒ close 返回即「清理完成」；回调投递抽出 `notifyEviction`（吞掉用户回调异常：否则消费线程会被杀死、之后淘汰全部静默失效，且 close 的 join 会把异常重抛）。
  - `src/WeakHeapCache.cj`：同样的 `ensureOpen()` + 9 个公开入口校验；`close()` 改为「置位 → 主动清空 → `Future.cancel()` → `f.get()` 等清扫线程结束」。
  - `f_cache/README.md`「并发与约定」：关闭语义改写为「close 主动清空全部条目、等内部线程结束才返回；此后一切操作抛 `IllegalStateException`（仅 `isClosed`/`close` 例外，close 可重复调用）」。
- 用例（`src/HeapCache_test.cj`）：新增 `testOperationsAfterCloseThrow`（16 个入口逐一断言抛 `IllegalStateException`，并验证 `isClosed`/`close` 幂等不抛）、`testCloseClearsAndJoinsBeforeReturn`（close 返回后 `f.get(1 ms)` 必须立即成功）；`testWeakHeapCacheIsResource` 扩充为「清扫线程 join + 9 个入口全抛」；`testClearResetsSize` 与 `testHeapCacheIsResource` 中「close 之后读 `size`」的断言按新语义移除。
- 测量证据（`git stash` 把两个源文件回退到改动前、测试保持新版运行）：**修复前** PASSED 14 / **FAILED 2**（`testOperationsAfterCloseThrow`：关闭后 `get` 未抛异常；`testWeakHeapCacheIsResource`：清扫线程未 join、入口未抛；EXIT=1）→ **修复后** = **16/16 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**；f_cache 自身编译警告仍 2 条。日志 `/tmp/cache7_before.log`、`/tmp/cache7_after.log`。
  - 诚实标注：`testCloseClearsAndJoinsBeforeReturn` 在「修复前」那次运行是**通过**的（1 ms 窗口偶合上 100 ms 轮询边界，属运气）⇒ 它**不是**可靠的修复前失败证据，作为**修复后的保证性用例**保留（修复后为确定性通过）。
- 契约变化（有意）：关闭后不再允许任何读写/清理操作（此前是「可继续写入且永不清理」）⇒ 已写入 README；仓库内使用方（f_data / f_orm / f_regex / f_jwt / f_security / fdemo）都不调用 `close()`、也不会关闭后复用实例 ⇒ **无下游影响**。
- 相关（`CACHE-5` 的 ②）：`ExitCallbacks.atExit(254, close)` 曾是每实例一条全局**强引用**注册 ⇒ 关闭后实例本身仍被全局表引用（条目与线程已释放，但对象无法回收）。**✅ 2026-10-05 已修复**：注册改持弱引用（`WeakRef` + `CleanupPolicy.EAGER`），关闭后实例可被 GC 回收，退出时自动 `close()` 的语义不变 —— 见 §2.2 ②。

**位置**：`src/HeapCache.cj` 的 `close()` 与 `startTimer()` 回调

`close()`（原 `destroy()`）置 `closedFlag=true` 并清空 ⇒ 定时器已 `cancel()` ⇒ **不再有清扫**；而修复前 `set`/`get`/`getOrCompute` 都没有 `isClosed()` 守卫 ⇒ 关闭之后写入的条目既没有过期清扫、也没有 maxSize 淘汰。

**影响（修复前）**：关闭后复用同一实例（或忘记关闭后又被继续写入）会得到只增不减的 map；`size` 也随之永久虚高（叠加 `CACHE-3`）。

**修法（已采纳）**：`close()` 主动清空并在返回前等内部线程结束；全部公开入口在 `isClosed()` 时抛 `IllegalStateException`（关闭即不可用）。

**DT**：`close()` → 等 1 个检查周期 → `set(k1)/set(k2)` ⇒ 断言抛 `IllegalStateException`。

**实测（探针 P7/P8，当时走 `destroy()`）**：关闭后 `set` 两次、等 1 s（`maxLife=300ms`、`maxSize=1`）：`d1=false d2=false`（按寿命已过期）但 **`size=2` 且此后不降** ⇒ 过期条目永驻。

### 2.5 [中｜并发] `CACHE-8` `Priority` 比较基线字段无锁读写竞争；`compare` 的“保护新生”分支写反且含不可达分支 → ✅ 已修复（2026-10-05：① 无锁竞争、②「保护新生」重写，④⑤ 口径同向统一）

**✅ 修复标记（2026-10-05，①+② 一次完成）**：分支 `review/f_cache`，**代码、用例、README 与本标记在同一提交**（三次提交：`00ff79a5` = ① 比较基线字段纳入 `p.lock`；`21c9cf65` = ② 年龄门对称化 + `cmp()` 两条 recency 判据；`db3b55f6` = ④⑤ 口径统一）。语义按作者指示定为**保护新生**。

**① 比较基线字段纳入 `p.lock`（无锁竞争）**：

- 改动（`src/Priority.cj`）：`lastCheckedTime`、`usedCountUtilLastChecked` 两个 getter 与 `updateLastChecked(current)` 都包进 `synchronized(lock)` ⇒ 定时线程的批量写入与业务线程（`compare` 路径）的读取互斥。`usedCount` 本就是 `AtomicInt64`、`once` 原子、`birth` 不可变、`lastUsed`/`maxLife_` 已有锁 ⇒ `Priority` 的字段访问现在全部受锁或原子保护（`Mutex` 可重入；`compare` 内逐个取锁、不嵌套两把锁 ⇒ 无死锁面）。
- 用例（`src/HeapCache_test.cj`）：`testEvictionKeepsMoreUsedEntry`（`maxSize=1`：`hot` 在本次检查周期内被访问 3 次、`cold` 0 次 ⇒ 断言 `hot` 存活、`cold` 被淘汰），冻结「用量是 `compare` 第一层依据」这条不变量。
- 诚实标注：这是**可见性/一致性**问题（普通字段被定时线程写、被业务线程读），给不出确定性失败证据（依赖并发时序）⇒ 属「同步型」：只有代码层证明 + 回归用例。带探针那次实测（21/21）里用量维度的淘汰结果**是对的**（探针 P-b）⇒ 该竞争在实测中未显形，但按内存模型此前是未定义行为。

**② 「保护新生」年龄门对称化 + `cmp()` 两条 recency 判据修正**：先把「谁被淘汰」的判定链钉死 —— **P-a** `PriorityQueue` 是最小堆（`add(3,1,2)` 后 `remove()` = **1**）⇒ `compare` 返回 `GT` = **被保留**、`LT` = 先淘汰；`checkOverSize` 用 `topVals.remove()` 的结果当淘汰对象（`HeapCache.cj:141-147`）。**P-b** 反向验证：年龄接近、用量 hot=3 / cold=0 ⇒ hot 存活 ✓（用量主键方向本来就是对的）。修复前实测（4 条临时探针，跑完即删）：

| 探针 | 构造 | 修复前实测 |
|---|---|---|
| P-a | `PriorityQueue<Int64>` 依次 `add(3,1,2)` 后 `remove()` | **1** ⇒ 堆顶是最小元素 ⇒ `GT` = 保留 |
| P-b | `maxSize=1`、年龄接近、用量 hot=3 / cold=0 | hot 存活、cold 淘汰 ✓（用量主键方向正确） |
| P-c | `checkDuration=1s`、年龄差 1.5 个周期、用量相同 | **old（更老）存活、new（更新）被淘汰** ✗ 与注释「保护新生」相反 |
| P-d | 年龄差 0.2 个周期、用量相同 | **first（更老）存活、second（更新）被淘汰** ✗ 第③级 tie-break 同样偏老 |

- 改动（`src/Priority.cj` 的 `compare`）：**年龄门对称化** —— `ageSub > 1.0`（本对象更老）⇒ `LT`（老的先淘汰）；其余（本对象更新、且差超过一个生命周期）⇒ `GT`（留下）；**删掉不可达的 `age < -1.0` 分支**（`age` = 距今时长/周期，正常时钟下恒 ≥ 0）。**`cmp()` 第②③级改成「更新者更大」**：`duration.compare(otherDuration)`、`lastUsed.compare(otherLastUsed)`（原为 `otherX.compare(x)`，两处都偏老）。
- **第④⑤级一并统一（2026-10-05，按指示；提交 `db3b55f6`）**：④ 改为 `ref.load().compare(other.ref.load())`（历史访问总量**多**者更大，与①同向）、⑤ 改为 `birth.compare(other.birth)`（出生**更晚**者更大）⇒ `cmp()` 的 ②~⑤ 四级 tie-break 已全部与「保护新生」同向。**这两级在现有实现下几乎不可达**：要 ①②③ 全部同分，意味着两个候选的 `lastUsed` 必须纳秒级完全相同（`lastUsed` 只在 `load`/`store` 里取 `DateTime.now()`）⇒ 属**口径统一**而非行为修复，**无法用确定性用例钉住**（同①「同步型」的标注方式）。
- 用例（`src/HeapCache_test.cj`，新增 3 条）：`testCompareProtectsNewEntryBeyondOneLifecycle`（直接驱动 `PriorityQueue`，年龄差 1.5 个周期 ⇒ 淘汰更老的；不依赖分段布局）、`testCompareProtectsRecentlyUsedEntryWithinOneLifecycle`（年龄差 0.2 个周期、用量同分 ⇒ 淘汰更老的）、`testEvictionInAgeGapProtectsNewEntry`（端到端 `maxSize=1`，老的/新的各占一个分段 ⇒ 新的留下、老的被淘汰）。
- **既有用例 `test()` 的期望按新语义修正（重要，属语义变更）**：原断言「`test2` 存活、`test3`（最新）被淘汰」——`test2`/`test3` 在「周期内使用次数」与「新鲜度」上都同分，实际由第③级 tie-break 决出 ⇒ **旧断言锁定的正是「偏老」行为**。修正为：`test1` 存活（周期内读多次）、`test3` 存活（更新的留下）、`test2` 被淘汰（更老的先走）。
- 测量证据：修复前 **17 PASSED / 3 FAILED**（恰好 3 条新用例红、`test()` 仍绿）⇒ 修复 + 同步 `test()` 期望后 **20/20 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**；f_cache 自身编译警告仍 2 条。日志 `/tmp/cache8b_before.log`、`/tmp/cache8b_after.log`、`/tmp/cache8b_final.log`。
- README 同步：「并发与约定」新增一条 `maxSize` 超限时的淘汰顺序（更老者先淘汰；一个周期内则按使用次数、最后使用时间，更多/更晚者优先保留）。

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

**影响（修复前）**：①基线字段的读写竞争使淘汰顺序在高并发下不稳定（读到的可能是旧值）；②「保护新生」失效 —— 候选中同时有「很久未用」与「刚用过」的条目时，淘汰扔掉刚用过的 ⇒ 与「保频繁/护新生」的设计目标相反，命中率受损。

**补充更正（审查结论的一处修正）**：审查时判断「现有用例覆盖不到这条分支」只对**年龄门**成立；`test()` 里 `test2`/`test3` 这对候选是由第③级 tie-break 决出的，旧断言 `!contains('test3')` 实际锁定了「偏老」的行为（修复时已按新语义改写，见上）。

**DT（已落地）**：`testCompareProtectsNewEntryBeyondOneLifecycle`、`testCompareProtectsRecentlyUsedEntryWithinOneLifecycle`、`testEvictionInAgeGapProtectsNewEntry` —— 构造仅「最后使用时间」不同的条目（`checkDuration` 取 1 s），断言淘汰的是更老的一个。

---

## 3. 低危（8 条）/ 待验证（2 条）

### 3.1 低危（8 条）

- **`CACHE-L1` `ConcHashMapKeys.contains(all!)` 是「任一包含」而非「全部包含」**：`src/ConcHashMap.cj:75-80` 在循环里 `return true` 命中即返回 ⇒ 与 std `contains(all:)` 语义相反；且 `ConcHashMapKeys`/`ConcHashMapValues`/两个 Iterator（`src/ConcHashMap.cj:22-133`）在本仓库**无任何使用点**（死代码，只有 `ConcHashMapKeysIterator` 经 `keys()`… 实际 `ConcHashMap` 也没有 `keys()`/`values()` 成员）。修法：改成「全部命中才 true」，或直接删除这 4 个类。**实测（P4）**：`contains(all: ['b','a'])` 在只有 `'a'` 时返回 `true`。　**✅ 已修复（2026-10-05，改法取「修正语义」而非「删类」）**：`contains(all:)` 改为「全部命中才 true」（与 std `Collection.contains(all:)` 及本 map 的 `containsAll` 一致；空集合按 vacuous truth 返回 true）。取此路线的原因：这 4 个类是**包内可见**（`class …` 无修饰符、构造器也不收 `public`）⇒ 改语义**不涉及公开 API**、零破坏；删类族虽然更彻底，但留待单独决定。用例：新建 `src/ConcHashMap_test.cj` 的 `testKeysContainsAllRequiresEveryElement`（单键 / 全命中 / 有一个缺失 / 全缺失 / 空集合 / size / isEmpty）—— 修复前 **20 PASSED / 1 FAILED**，修复后 **21/21 PASSED、FAILED 0、ERROR 0、EXIT=0**，编译警告仍 0 条。日志 `/tmp/cache_l1_before.log`、`/tmp/cache_l1_after.log`。
- **`CACHE-L2` `WeakHeapCache.get` 的 lambda 返回值被丢弃**（`src/WeakHeapCache.cj:81-89`，编译警告 `unused expression` 指向 `:86`）：`entryView` 的回调返回 `Unit`，真正取值靠 `entryView` 自身返回 `?V`；写法容易误导（看起来像回调在产出结果）。`set` 里的 `try/finally`（`:59-68`）同样绕。修法：把回调体写成纯副作用（显式 `()`），或直接换成「`get` 未命中就用 `add`」的两步写法并注释原子性理由。　**✅ 已修复（2026-10-05，与 `L4` 同一提交）**：`get` 改为直接 `cache.get(...)` 纯读取，不再有被丢弃的 lambda 返回值。**更正一处过度声明**：查证 std 文档 —— `entryView` **只有当回调把 value 置为非 `None` 时才新增条目**，原实现只读不写 ⇒ **不会虚增 `size`**，所以本条是**写法/警告**问题（那条 `unused expression` 警告的来源），**行为不变**；先前「miss 会插入空条目 ⇒ size 虚增」的说法已作废（代码注释、用例注释、`§0` 与 `L4` 标记同步更正）。`set` 去掉 `try/finally` 绕写法，改为「先取旧值（仅当仍存活）→ 写入 → 返回旧值」，`weakRef()` 补显式返回类型 `WeakRef<T>`。`getOrCompute` 保留 `entryView`（它的 lambda 本就是语句体、需要原子「查-算-写」）不动。
- **`CACHE-L3` `WeakKey` 把「键」放进弱引用**（`src/WeakHeapCache.cj:22-45`）：键是每次调用新构造的 `Box<String>`，只被 `WeakRef` 弱引用 ⇒ 在 `CleanupPolicy.DEFERRED`（GC 尽量保活、内存不足才回收）下平时可用（**实测 P5 通过**），但内存紧张时键会被回收 ⇒ 值仍被强引用时条目也会静默消失、且 `get` 期间键可能失效导致 miss。弱引用缓存的常规做法是**键强、值弱**。修法：`WeakKey` 持强引用（`Box<String>`/`String`），只让值 `WeakRef`。顺带：每次 `get`/`set` 都新分配 `Box<String>+WeakRef`（热路径额外分配），键强引用后也可缓存键对象。　**✅ 已修复（2026-10-05）**：`WeakKey` 改为**持强引用**（`private let key: String`，去掉 `WeakRef<Box<String>>` 与 `deferred()` 工厂，构造点统一改 `WeakKey(key)`），只让值保持 `WeakRef<T>`（`CleanupPolicy.DEFERRED` 不变）⇒ 「值仍被强引用、条目却因键被回收而静默消失 / `get` 期间键失效导致 miss」的隐患消除；顺带省掉每次 `get`/`set` 的 `Box<String>` + `WeakRef` 两次分配。连带改动：清扫线程条件由 `k.isNone() || v.value.isNone()` 简化为 `v.value.isNone()`（键已不可能失效），`removeIf` 的谓词直接取强引用键。用例：新建 `src/WeakHeapCache_test.cj`（4 条：`set`/`get`/`getOrDefault`/`remove` 语义；`getOrCompute`/`getOrStore`；`get` 未命中不建条目 + `removeIf`/`clear`；关闭后抛异常与可重复 `close`）⇒ 全量 **25/25 PASSED、FAILED 0、ERROR 0、EXIT=0**，编译警告 0 条（`/tmp/cache_l3b.log`）。
  - 诚实标注：**键被 GC 回收导致条目消失**这一后果取决真实 GC 时机，用例里无法确定性复现（无 GC 触发入口，`DEFERRED` 下小规模压测也不必然触发）⇒ 本条验收 = 代码层论证（键已不是弱引用）+ 上述语义用例；丢失率量化属 `CACHE-V2`，该条已按作者决策降级为**观测项**（2026-10-05，见 §3.2）。
- **`CACHE-L4` 两处编译警告**（原有 2 条，行号随 `CACHE-5`/`CACHE-7` 的改动后移）：`src/HeapCache.cj:20` `unused import 'std.env.atExit'`（实际用的是 `f_base` 的 `ExitCallbacks.atExit`）；`src/WeakHeapCache.cj:135` `unused expression`（见 L2）。　**✅ 已修复（2026-10-05，与 `L2` 同一提交）**：删掉未用的 `import std.env.atExit`；`unused expression` 由 `L2` 的 `get` 改写消除 ⇒ **f_cache 自身编译警告 2 → 0**（强制全量重编验证，`/tmp/cache_l4l2.log`）。
- **`CACHE-L5` 命名/文档细节**：`HeapCache.evicated`（`src/HeapCache.cj:131-133`）应为 expired 语义；`README.md:102`「弱引用堆缓存」一节把 `WeakHeapCache` 的 `remove`/`removeIf`/`size` 等成员列全了，但没有说明**清扫有 1 s 延迟**（`size` 含未被清扫的失效条目，实测 `P5` 的 `size` 与 `contains` 口径差 ≤ 1 s）。　**✅ 已修复（2026-10-05）**：`evicated` → `expired`（`private` 方法，改名不涉公开 API；定义 + 6 处调用点一并改）；README「并发与约定」新增 `WeakHeapCache` 条目（键强值弱、清扫线程 1 s 一轮、`size` 与 `get`/`contains` 的口径差最长 1 s、`close()` 主动清空并等线程结束）。
- **`CACHE-L6` 迭代一致性未文档化**：`SyncLinkedHashMap.iterator()`（`src/SyncLinkedHashMap.cj:26-28`）在**锁外**创建底层迭代器、每次 `next()` 才取读锁；`ConcHashMapIterator.next()`（`src/ConcHashMap.cj:146-155`）跨段无快照，`doNextSegment` 的越界分支与循环条件 `cur <= m.concurrency`（`:147`）冗余。定时淘汰与业务读并发时迭代结果不保证包含本轮新增——可接受，但应写进 README。　**✅ 已修复（2026-10-05）**：README「并发与约定」新增「迭代一致性」条目（弱一致：锁外创建、逐段/逐项取锁、跨段无快照 ⇒ 不保证看到本轮写入、不保证顺序）；顺带把 `ConcHashMapIterator.next()` 的循环条件由 `cur <= m.concurrency` 收紧为 `cur < m.concurrency`（原条件会多跑一轮空迭代）；`doNextSegment` 的越界分支保留（防御式）。新增的 `ConcHashMap` 迭代用例（见 `L8`）覆盖该路径。
- **`CACHE-L7` 惰性过期与口径差**：`get` 对已过期条目只返回 `None`，不摘除（`src/HeapCache.cj:135-140`）⇒ `size` 会包含「已过期未清扫」的条目（最长 `checkDuration`）。属常见惰性过期设计，但与 `contains` 的口径差异未文档化（叠加 `CACHE-7` 后会变成永驻）。　**✅ 已修复（2026-10-05，文档路线）**：`HeapCache` 一侧的口径差**审查前已在 README「并发与约定」写明**（`size` 与 `get`/`contains` 的口径差条目）；本次补上 `WeakHeapCache` 一侧（值失效后最长 1 s 仍计入 `size`）⇒ 两个缓存的口径差现在都在 README。**行为不变**：惰性过期保留（`get` 对已过期条目只返回 `None`、不摘除，摘除交给定时清扫/`removeIf`），与 `CACHE-7` 的「关闭后清空」互不影响。
- **`CACHE-L8` 用例覆盖极薄**　**✅ 已补齐（2026-10-05）**：审查时整个模块只有 1 个用例（`src/HeapCache_test.cj`，8.02 s，绝大部分是 `sleep`）；`CACHE-1`~`CACHE-8` 的修复过程中补到 **20 条** —— `getOrCompute` 系列（含「不持段锁」）、`once`/`prolong` 拒绝过期、`removeIf` 不持段锁、`Priority`/`compare` 的年龄差与 tie-break、`close`/`Resource`/关闭后抛异常、`set(life:)`、`clear`、`set` 覆盖计数、`maxSize` 淘汰用量维度（原 `destroy` 相关用例随接口删除改为 `close()`）。**已补齐（2026-10-05，随 `L1`~`L3` 与本条一并）**：再补 7 条 ⇒ 全模块 **27 条**（`ConcHashMap` 直接用例 2 条：`contains(all:)` 语义、`size` 记账/覆盖/`computeIfAbsent`/迭代/`remove`/`removeIf`；`WeakHeapCache` 语义 4 条：`set`/`get`/`getOrDefault`/`remove`、`getOrCompute`/`getOrStore`、`get` 未命中不建条目 + `removeIf`/`clear`、关闭后抛异常；`evictionCallback` 1 条）。**唯一未单独立用例的是 `SyncLinkedHashMap`**：它是 `ConcHashMap` 的分段实现，`add`/`get`/`remove`/`removeIf`/迭代均通过 `ConcHashMap` 直接用例与 `HeapCache`/`WeakHeapCache` 全链路用例覆盖 ⇒ 如需直接用例请示意。测量：**27/27 PASSED、FAILED 0、ERROR 0、EXIT=0**，编译警告 0 条（`/tmp/cache_l8b.log`）。

### 3.2 待验证（`V1` 已了结；`V2` 定为观测项）

- **`CACHE-V1` `Priority.compare` 的淘汰顺序是否符合设计**（见 `CACHE-8`）　**✅ 已了结（2026-10-05）**：作者确认期望方向为**保护新生**，`CACHE-8` ② 已按此重写 `compare`（年龄门对称化 + `cmp()` ②~⑤ 级判据全部同向），并新增 3 条仅一维差异的用例逐一固定（周期内使用次数 / 最后使用时间 / 年龄差）；`test()` 的旧断言（锁定「偏老」行为）已按新语义修正 —— 见 §2.5。
- **`CACHE-V2` `WeakRef` 条目在真实内存压力下的失效率**　**已降级为观测项（2026-10-05，作者决策：不单造压测）**。理由：① `CACHE-L3` 修复后「键被 GC 回收 ⇒ 条目静默消失」的**前提已不存在**（键改强引用）；② 剩下的只有**值**被 GC 回收一种情形，而值被回收本就是弱引用缓存的正常语义（值活多久由调用方决定）；③ 仓颉无 GC 触发入口、`DEFERRED` 策略下小规模压测不必然触发 ⇒ 库内做不出可信数字。
  - **观测结果（2026-10-05，四个使用模块各跑一遍全量用例）**：`f_data` **104/104 PASSED**、`f_regex` **3/3**、`f_jwt` 14 条中 3 PASSED / **11 ERROR**（全是 HMAC/密钥类用例，主线同版本**同样 11 ERROR** ⇒ 原有问题，与缓存无关）、`f_orm` 33 条中 **32 PASSED / 1 ERROR**（`ORMConfigTest.testPoolMaxWaiting`：`Config.getData<Duration>` 的配置解析/默认值问题；`f_config`/`ORMConfig` 依赖里**没有** `f_cache`，也不使用本次改动的 `ConcHashMap`/`SyncLinkedHashMap`；**主线基线复跑同一结果（32/33、同一条 ERROR）** ⇒ 确认为原有问题）。
  - **结论**：没有任何一条端到端失败与缓存行为相关，也没有观测到条目异常消失 ⇒ 观测项在本轮以「无异常」结项；量的丢失率仍只能在真实长跑里看（不单独立项）。日志 `/tmp/cache_e2e.log`、`/tmp/jwt_branch.log`、`/tmp/orm_branch.log`。

---

## 4. 覆盖面（结构小结 + 已确认「无实例」的维度）

**结构**：`f_cache` = 强引用缓存 `HeapCache`（定时线程 + 分段并发 map）+ 弱引用缓存 `WeakHeapCache`（`std.collection.concurrent.ConcurrentHashMap` + 弱引用键值 + 1 s 清扫线程）+ 三个内部支撑件 `ConcHashMap`（分段，段内 `SyncLinkedHashMap`，读写锁；自维护 `size_`）、`SyncLinkedHashMap`（`LinkedHashMap` + 读写锁）、`Priority`（寿命/使用次数/出生时间，供淘汰排序）。运行期线程：1 个 `Timer` 调度（`Timer.after` 自续期）、1 个淘汰消费线程（`HeapCache` per instance）、1 个清扫线程（`WeakHeapCache` per instance）。

**已确认「无实例」的维度**：

- 无文件 / 网络 / CFFI / 原生内存 / 句柄类资源；无 reflect（`f_cache` 无 `std.reflect`），无宏。
- 无 `ThreadLocal`、无对象池；唯一的进程级静态可变状态是 `f_base` 的 `ExitCallbacks` 注册表（被 `HeapCache` 用来注册 `destroy`）与各模块里的静态缓存实例（`f_data`/`f_orm`/`f_regex` 各一个）。
- 无持久化/序列化；无「键过期通知」以外的副作用（`evictionCallback` 是唯一对外回调，且**实测通路正常**，见 §5 P6）。

**仓库内使用面**：`f_data/src/path/CacheDataPath.cj:21,24`（`getOrCompute`）、`f_orm/src/base/SqlDSL.cj:45,47`（`getOrCompute`）、`f_regex/src/RegexFromString.cj:28,61`（`getOrCompute`）、`f_jwt/src/JwtIdCache.cj:40-63`（`set(life:)`/`set(dieAt:)`）、`f_security/src/HeapCacheStore.cj:19-24`（`set` 默认寿命 ✓ 不受 `CACHE-1` 影响）、`fdemo/user/src/util/UserSessionCache.cj:27`（经 f_security）、`src/cache/cache.cj:18`（对外 re-export）。`WeakHeapCache` **无任何使用者**（包外）；用例：审查后已有 5 条（4 条语义 + 1 条 `Resource`，见 `L3`/`L8`）。

---

## 5. 基线与验证状态

| 项 | 命令 | 结果 |
|---|---|---|
| 既有用例 | `cjpm test --no-capture-output`（WSL Ubuntu-24.04，SDK 1.3.0-alpha.20261001001050） | **1/1 PASSED，ERROR 0，FAILED 0，`cjpm test success`（EXIT=0）**；唯一用例 `test` 耗时 8 024 104 487 ns（≈ 8.02 s，主要是 `sleep`）。日志 `/tmp/cache_base.log` |
| 编译警告 | 同一构建 | 构建过程共 30 条 warning（含依赖模块 f_base/f_collection），**f_cache 自身 2 条**：`HeapCache.cj:20` unused import、`WeakHeapCache.cj:86` unused expression（见 `CACHE-L4`） |
| **修复完成后**（2026-10-05，分支 `review/f_cache`；本轮多次强制全量重编 f_cache） | `cjpm test --no-capture-output`（同一 SDK/WSL） | **27/27 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**；**f_cache 自身编译警告 2 → 0 条**。用例 1 → 27；§1 严重 3 条 + §2 中危 5 条 + §3 低危 8 条全部了结（`V1` 已了结、`V2` 未做）。提交范围 `00ff79a5`…`3a8a01cc`（详见 §0）。末次全量日志 `/tmp/cache_l567.log` |

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

### 基准与采样（2026-10-05：`cjpm bench` + 探针 + `cjprof heap`）

**基准**（`f_cache/src/HeapCache_bench.cj`，`cjpm bench`，WSL / SDK 1.3.0-alpha.20261001001050；单次运行中位数，Err% ≤ 11%，日志 `/tmp/cache_bench.log`）：

| 用例 | 覆盖点 | Median | Mean |
|---|---|---|---|
| `benchGetHit` | 命中：分段读锁 → `Priority.load`（含 `CACHE-8` ① 新增的 `p.lock`） | **2.561 µs** | 2.658 µs |
| `benchSetSameKey` | 同键写：段写锁 + 覆盖 | **2.578 µs** | 2.751 µs |
| `benchSetDistinctKeys` | 不同键写：新建 `Priority` + size 记账 + 淘汰压力（键空间 2×`maxSize`） | **5.317 µs** | 5.395 µs |
| `benchSetUnderEvictionPressure` | `maxSize=1` 两键交替写，定时淘汰持续竞争（`compare` 路径） | **3.925 µs** | 4.062 µs |

⇒ **`CACHE-8` 确认**：①新增的两处加锁没有给命中路径带来可见代价（2.56 µs，与「同键写」同量级）；②重写后的 `compare`/淘汰路径在持续竞争下无病态成本（3.9 µs）。`cjpm bench` = `PASSED: 4, FAILED: 0, ERROR: 0`、`cjpm bench success`。
（过程说明：`benchSetDistinctKeys` 首版用无界键空间 `k${i}`，38 s 灌入数百万条导致 OOM 崩溃 —— 属**基准设计问题**，改 `i % 2000` 有界后通过；崩溃不是产品缺陷。）

**探针 1（`CACHE-4`）—— 同段读不再被用户代码阻塞**（复现本表 P10；`concurrencyLevel=4` 精确挑同段键，谓词内 `sleep(400ms)`）：

| | 修复前（§5 P10 记录） | 本次实测（修复后） |
|---|---|---|
| 同段 `get` 延迟 | 292.87 ms | **55 µs 613 ns**（≈5300×） |
| 异段 `get` 延迟 | 0.0228 ms | 2.7 µs |

⇒ 同段与异段回到同一量级 ⇒ 谓词确实在段写锁之外执行 ✓ **`CACHE-4` 确认**。

**探针 2（`CACHE-5`）—— create+close 不泄漏线程**：连续 50 轮 `HeapCache` + `WeakHeapCache` 各建一个并 `close()`：

| 采样点 | `Threads:` | `VmRSS:` |
|---|---|---|
| 基线 | **10** | 38 700 kB |
| 50 轮 create+close 后 | **10** | 51 724 kB |
| 静置 3 s | **10** | 51 980 kB |

⇒ 线程数**持平**（修复前每实例泄漏 1~2 个线程，50 轮至少 +75）✓；RSS +13 MB 属「未触发 GC 的分配」而非泄漏证据（同点线程数不变；`cjprof heap -t` 快照里线程栈全是 unittest 框架自己的 —— `testRunnerEntryMain`/`ProgressReporter`/`parallelOrderedMap`，**没有**缓存的定时器/消费线程/清扫线程）⇒ **`CACHE-5` 确认**。

**探针 3（`CACHE-2`/`CACHE-3`）—— size 记账真实、上限生效**：`maxSize=1000` 的缓存经 `getOrCompute` 灌 20 000 个不同键：

| 采样点 | `size` | `VmRSS:` |
|---|---|---|
| 灌入前 | — | 52 236 kB |
| 灌 20 000 键后 | **20 000**（记账跟得上真实条目数；修复前恒为 0） | 95 696 kB |
| 静置 3 s（定时淘汰跑过） | **1 000**（= `maxSize`，上限生效；修复前完全失效） | 80 948 kB |

⇒ **`CACHE-2`/`CACHE-3` 确认**（记账真实 + 上限收口 + 淘汰后 RSS 回落）。

**剩余未做**：长稳压力（线程/实例累积速率）。**已补做（2026-10-05）**：基准与堆/RSS 采样（见上）；真实业务路径的端到端复现 —— 四个使用模块各跑一遍全量用例：`f_data` **104/104 PASSED**、`f_regex` **3/3**、`f_jwt` 3/14（11 条 HMAC/密钥类 ERROR，主线同样复现，属原有问题，见 `bug-cross.md` `X-3`）、`f_orm` 32/33（1 条 `ORMConfigTest.testPoolMaxWaiting`，主线基线同一条，属原有问题，见 `bug-cross.md` `X-2`）；`WeakRef` 压测项按 `CACHE-V2` 的决策取消（改为观测项）。日志 `/tmp/cache_e2e.log`、`/tmp/cache_bench.log`、`/tmp/cache_probe_run.log`、`/tmp/cache_heap.data`。

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
