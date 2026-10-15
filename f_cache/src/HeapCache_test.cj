/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::f_cache

import std.unittest.*
import std.unittest.testmacro.*
import std.time.{DateTime, MonoTime}
import std.collection.ArrayList
import std.sync.Mutex
import fountain::f_collection.PriorityQueue

@Test
public class HeapCache_test {
    @TestCase
    public func test(): Unit {
        let cache = HeapCache<Test>(maxSize: 2)
        cache.set("test1", Test())
        @Assert(cache.get("test1").isSome())
        sleep(Duration.second)
        cache.set("test2", Test())
        let test1 = cache.get('test1').isSome()
        @Assert(test1)
        @Assert(cache.get('test1')?.value, cache.get('test1')?.value)
        @Assert(cache.getOrDefault("test99999999", Test(8888888)).value, 8888888)
        cache.set("test3", Test())
        sleep(2 * Duration.second)
        @Assert(cache.contains("test1"))//test1 在本次检查周期内被读多次 ⇒ 保留
        @Assert(cache.contains("test3"))//test2 与 test3 同分（都未被使用）⇒ 更新的 test3 留下（保护新生）
        @Assert(!cache.contains("test2"))//⇒ 更老的 test2 被淘汰
        sleep(5 * Duration.second)
        @Assert(!cache.contains("test1"))
        @Assert(!cache.contains("test3"))
    }

    @TestCase
    public func testSetLifeOnNewKey(): Unit {
        //checkDuration 放大到 30s：本用例只考察「寿命判定」，不让定时清扫介入
        let cache = HeapCache<Test>(maxLife: Duration.second * 30, maxSize: 100,
            checkDuration: Duration.second * 30)
        //新建键：life 必须生效
        cache.set('newLife', Test(1), life: Duration.millisecond * 100)
        //已存在键：life 生效（修复前就正确，作为对照）
        cache.set('updLife', Test(2))
        cache.set('updLife', Test(3), life: Duration.millisecond * 100)
        //新建键 + dieAt：等价于「一次性 + 指定死亡时间」，必须生效
        cache.set('newDieAt', Test(4), DateTime.now() + Duration.millisecond * 100)
        sleep(Duration.millisecond * 300)
        @Assert(false, cache.contains('newLife'))
        @Assert(false, cache.contains('updLife'))
        @Assert(false, cache.contains('newDieAt'))
    }

    @TestCase
    public func testGetOrComputeAccountsSize(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30, maxSize: 100,
            checkDuration: Duration.second * 30)
        for (i in 0..5) {
            cache.getOrCompute('g${i}') {Test(i)}
        }
        //getOrCompute 建的条目同样要计入 size（否则 maxSize 淘汰失效、remove 会把 size 减成负数）
        @Assert(5, cache.size)
        @Assert(true, cache.remove('g0').isSome())
        @Assert(4, cache.size)
    }

    @TestCase
    public func testGetOrComputeObeysMaxSize(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30, maxSize: 2,
            checkDuration: Duration.millisecond * 200)
        for (i in 0..5) {
            cache.getOrCompute('m${i}') {Test(i)}
        }
        sleep(Duration.second)
        var alive = 0
        for (i in 0..5) {
            if (cache.contains('m${i}')) {
                alive++
            }
        }
        //maxSize=2 ⇒ 定时淘汰后存活条目不应超过 2
        @Assert(true, alive <= 2)
        @Assert(true, cache.size <= 2)
    }

    @TestCase
    public func testAddOverwriteCountsOnce(): Unit {
        let map = ConcHashMap<Test>.create(concurrencyLevel: 4)
        map.add('a', Test(1))
        map.add('a', Test(2))
        //覆盖已存在的键不是新增，size 只能 +1
        @Assert(1, map.size)
        map.add('b', Test(3))
        @Assert(2, map.size)
    }

    @TestCase
    public func testClearResetsSize(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30, maxSize: 100,
            checkDuration: Duration.second * 30)
        for (i in 0..3) {
            cache.set('c${i}', Test(i))
        }
        @Assert(3, cache.size)
        cache.clear()
        @Assert(0, cache.size)
        //clear 之后重新计数：幻影计数会让真实条目被提前淘汰
        cache.set('c0', Test(0))
        @Assert(1, cache.size)
    }

    /**断言 body 抛出 IllegalStateException（关闭后的统一行为）*/
    private func expectClosed(body: () -> Unit): Unit {
        try {
            body()
            @Assert(false)
        } catch (e: IllegalStateException) {
            @Assert(true)
        }
    }

    /**断言 body 抛出 IllegalArgumentException（参数校验失败）*/
    private func expectIllegalArgument(body: () -> Unit): Unit {
        try {
            body()
            @Assert(false)
        } catch (e: IllegalArgumentException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testOperationsAfterCloseThrow(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30, checkDuration: Duration.second * 30)
        cache.set('a', Test(1))
        cache.close()
        @Assert(true, cache.isClosed())
        cache.close()//close 幂等
        @Assert(true, cache.isClosed())
        //关闭后一切操作都抛异常（只有 isClosed/close 例外）
        expectClosed {let _ = cache.get('a')}
        expectClosed {let _ = cache.contains('a')}
        expectClosed {let _ = cache.once('a')}
        expectClosed {let _ = cache.prolong('a', Duration.second)}
        expectClosed {let _ = cache.prolong('a', DateTime.now())}
        expectClosed {let _ = cache.set('a', Test(2))}
        expectClosed {let _ = cache.set('a', Test(2), life: Duration.second)}
        expectClosed {let _ = cache.getOrDefault('a', Test(0))}
        expectClosed {let _ = cache.getOrStore('a', Test(0))}
        expectClosed {let _ = cache.getOrCompute('a') {Test(0)}}
        expectClosed {let _ = cache.remove('a')}
        expectClosed {cache.removeIf {_, _ => true}}
        expectClosed {let _ = cache.size}
        expectClosed {cache.clear()}
    }

    @TestCase
    public func testCloseClearsAndJoinsBeforeReturn(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30,
            checkDuration: Duration.millisecond * 200)
        for (i in 0..5) {
            let _ = cache.set('j${i}', Test(i))
        }
        @Assert(5, cache.size)
        cache.close()
        //close 返回时内部线程必须已经结束（而不是“还要等下一次轮询”）
        for (f in cache.threadHandles()) {
            try {
                f.get(Duration.millisecond * 1)
                @Assert(true)
            } catch (e: TimeoutException) {
                @Assert(false)
            }
        }
    }

    /**找一个与 key0 落在同一分段的键（concurrencyLevel=4 ⇒ 掩码 3），用于「同段操作是否被阻塞」的对照*/
    private func sameSegmentKey(key0: String): String {
        for (i in 0..100) {
            let k = 'sk${i}'
            if ((k.hashCode() & 3) == (key0.hashCode() & 3)) {
                return k
            }
        }
        throw Exception('no same segment key for ${key0}')
    }

    @TestCase
    public func testGetOrComputeComputesOnceWhenPresent(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30, checkDuration: Duration.second * 30)
        let calls = Box<Int64>(0)
        let first = cache.getOrCompute('once') {
            calls.value++
            Test(7)
        }
        let second = cache.getOrCompute('once') {
            calls.value++
            Test(8)
        }
        //已存在时不得再算：callable 只能被调用一次，两次拿到同一个值
        @Assert(1, calls.value)
        @Assert(7, first.value)
        @Assert(7, second.value)
    }

    @TestCase
    public func testGetOrComputeDoesNotHoldSegmentLock(): Unit {
        let cache = HeapCache<Test>(concurrencyLevel: 4, maxLife: Duration.second * 30,
            checkDuration: Duration.second * 30)
        let computed = 'gcVictim'
        let reader = sameSegmentKey(computed)
        cache.set(reader, Test(1))
        let cost = Box<Float64>(0.0)
        let f = spawn {
            sleep(Duration.millisecond * 100)
            let t0 = DateTime.now()
            let _ = cache.get(reader)
            cost.value = (DateTime.now() - t0) / Duration.millisecond
        }
        //callable 睡 400ms：若它被关在段写锁里，上面那次同段 get 会被拖住 ~300ms
        let computedValue = cache.getOrCompute(computed) {
            sleep(Duration.millisecond * 400)
            Test(2)
        }
        f.get()
        @Assert(2, computedValue.value)
        @Assert(true, cost.value < 100.0)
    }

    @TestCase
    public func testRemoveIfDoesNotHoldSegmentLock(): Unit {
        let cache = HeapCache<Test>(concurrencyLevel: 4, maxLife: Duration.second * 30,
            checkDuration: Duration.second * 30)
        let victim = 'rfVictim'
        let reader = sameSegmentKey(victim)
        cache.set(victim, Test(1))
        cache.set(reader, Test(2))
        cache.set('rfOther', Test(3))
        let cost = Box<Float64>(0.0)
        let f = spawn {
            sleep(Duration.millisecond * 100)
            let t0 = DateTime.now()
            let _ = cache.get(reader)
            cost.value = (DateTime.now() - t0) / Duration.millisecond
        }
        //谓词对 victim 睡 400ms：若谓词在段写锁内跑，同段 get 会被拖住
        cache.removeIf {k, _ =>
            if (k == victim) {
                sleep(Duration.millisecond * 400)
                true
            } else {
                false
            }
        }
        f.get()
        @Assert(true, cost.value < 100.0)
        //语义不变：谓词为真的被删，其余保留
        @Assert(false, cache.contains(victim))
        @Assert(true, cache.contains(reader))
        @Assert(true, cache.contains('rfOther'))
    }

    @TestCase
    public func testCloseStopsEvictionThread(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30,
            checkDuration: Duration.millisecond * 200)
        @Assert(1, cache.threadHandles().size)
        cache.close()
        //close 之后内部淘汰消费线程必须结束（修复前该路径阻塞在队列上，线程永不退出）
        for (f in cache.threadHandles()) {
            try {
                f.get(Duration.second * 3)
                @Assert(true)
            } catch (e: TimeoutException) {
                @Assert(false)
            }
        }
    }

    @TestCase
    public func testOnceRejectsExpiredEntry(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30, checkDuration: Duration.second * 30)
        cache.set('k', Test(1))
        cache.set('k', Test(2), life: Duration.millisecond * 100)//更新路径：life 生效
        sleep(Duration.millisecond * 300)
        @Assert(false, cache.contains('k'))//已过期（且未被定时清扫）
        @Assert(false, cache.once('k'))//过期即不存在：once 不应返回 true
    }

    @TestCase
    public func testProlongRejectsExpiredEntry(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30, checkDuration: Duration.second * 30)
        cache.set('k', Test(1))
        cache.set('k', Test(2), life: Duration.millisecond * 100)
        sleep(Duration.millisecond * 300)
        @Assert(false, cache.contains('k'))
        @Assert(false, cache.prolong('k', Duration.second * 5))
        @Assert(false, cache.prolong('k', DateTime.now() + Duration.second * 5))
        //被拒的续期不得把过期条目“复活”
        @Assert(false, cache.contains('k'))
    }

    /**
     * 寿命被改短的条目：段的死亡时间下界必须随之下调，否则清扫会跳过该段（条目留在表里）。
     * 单段（concurrencyLevel = 1）+ 全量 size 断言，把「读时判过期」与「真的被清扫删掉」区分开。
     */
    @TestCase
    public func testSweepClearsShortenedLife(): Unit {
        let cache = HeapCache<Test>(concurrencyLevel: 1, maxLife: Duration.second * 10,
            maxSize: 100, checkDuration: Duration.millisecond * 100)
        cache.set('byProlong', Test(1))//下界初始 ≈ t0+10s
        cache.set('bySet', Test(2))
        sleep(Duration.millisecond * 100)
        cache.prolong('byProlong', Duration.millisecond * 100)//死亡时间改短到 ≈ t0+200ms
        cache.set('bySet', Test(3), life: Duration.millisecond * 100)//同上
        @Assert(2, cache.size)//尚未到期：不得被误清
        sleep(Duration.millisecond * 800)
        @Assert(0, cache.size)//到期后必须真删，而不是仅“读时判过期”
    }

    /**
     * 清扫后必须把段下界**重算**为剩余条目的最小死亡时间：
     * 首轮下界（life=200ms）到点扫一次时续期过的条目仍活着 ⇒ 保留；重算出的下界再到点时必须清掉它。
     */
    @TestCase
    public func testSweepReschedulesAfterSweep(): Unit {
        let cache = HeapCache<Test>(concurrencyLevel: 1, maxLife: Duration.millisecond * 200,
            maxSize: 100, checkDuration: Duration.millisecond * 100)
        cache.set('k', Test(1))//下界 ≈ t0+200ms
        cache.prolong('k', Duration.millisecond * 400)//死亡时间 ≈ t0+400ms
        sleep(Duration.millisecond * 300)//首轮下界到点：k 仍活着，不得被误清
        @Assert(1, cache.size)
        @Assert(true, cache.contains('k'))
        sleep(Duration.millisecond * 600)//重算后的下界到点：必须被清掉（写成 Int64.Max 会漏清）
        @Assert(0, cache.size)
    }

    /** getOrCompute 两种重载新建的条目也必须登记死亡时间：到点后被清扫真删，长寿命条目保留 */
    @TestCase
    public func testSweepClearsComputedEntries(): Unit {
        let byDuration = HeapCache<Test>(concurrencyLevel: 1, maxLife: Duration.second * 10,
            maxSize: 100, checkDuration: Duration.millisecond * 100)
        let _ = byDuration.getOrCompute('alive') {Test(1)}//对照：活到 10s
        let _ = byDuration.getOrCompute('short') {(Test(2), Duration.millisecond * 200, false)}
        let byDateTime = HeapCache<Test>(concurrencyLevel: 1, maxLife: Duration.second * 10,
            maxSize: 100, checkDuration: Duration.millisecond * 100)
        let _ = byDateTime.getOrCompute('alive') {Test(1)}//对照
        let _ = byDateTime.getOrCompute('short') {(Test(2), DateTime.now() + Duration.millisecond * 200)}
        sleep(Duration.millisecond * 800)
        @Assert(1, byDuration.size)
        @Assert(true, byDuration.contains('alive'))
        @Assert(1, byDateTime.size)
        @Assert(true, byDateTime.contains('alive'))
    }

    /**
     * 并发写入短寿命条目：清扫与「登记下界」（含 deathVer 保护下的重算）竞争时不得漏清，
     * 全部到期后 size 必须归零，而不是留下永远无人清扫的条目。
     */
    @TestCase
    public func testSweepKeepsUpUnderConcurrentWrites(): Unit {
        let cache = HeapCache<Test>(concurrencyLevel: 4, maxLife: Duration.millisecond * 100,
            maxSize: 10000, checkDuration: Duration.millisecond * 50)
        let threads = 4
        let per = 300
        let futures = ArrayList<Future<Unit>>()
        for (t in 0..threads) {
            let myT = t
            futures.add(spawn {
                for (i in 0..per) {
                    let _ = cache.set('w${myT}_${i}', Test(i), life: Duration.millisecond * 100)
                }
            })
        }
        for (f in futures) {
            f.get()
        }
        sleep(Duration.second)
        @Assert(0, cache.size)
        cache.close()
    }

    /**段数按预期条目数推导：显式指定优先（非 2 的幂时向上取整）；传 0（默认）时每段目标 ≤1024 条、段数取 2 的幂且不超过 128 */
    @TestCase
    public func testAutoConcurrencyLevel(): Unit {
        let c1024 = HeapCache<Test>(concurrencyLevel: 0, maxSize: 1024)
        @Assert(16, c1024.segmentCount())
        c1024.close()
        let c16k = HeapCache<Test>(maxSize: 16384)//默认参数（concurrencyLevel 省略）同样走自动推导
        @Assert(16, c16k.segmentCount())
        c16k.close()
        let c20k = HeapCache<Test>(concurrencyLevel: 0, maxSize: 20000)
        @Assert(32, c20k.segmentCount())
        c20k.close()
        let cBig = HeapCache<Test>(concurrencyLevel: 0, maxSize: 200000)
        @Assert(128, cBig.segmentCount())
        cBig.close()
        let cExplicit = HeapCache<Test>(concurrencyLevel: 4, maxSize: 200000)
        @Assert(4, cExplicit.segmentCount())//显式指定优先
        cExplicit.close()
        let built = HeapCacheBuilder<Test>().setMaxSize(8192).build()
        @Assert(16, built.segmentCount())
        built.close()
    }

    /**
     * 显式 concurrencyLevel 向上取到 ≥ 该值的最小 2 的幂：段索引用 `hashCode & (段数 - 1)` 取模，
     * 段数不是 2 的幂时部分段永远取不到、且分布不均。
     */
    @TestCase
    public func testExplicitConcurrencyLevelRoundsUpToPowerOfTwo(): Unit {
        let c1 = HeapCache<Test>(concurrencyLevel: 1, maxSize: 1_000_000)
        @Assert(1, c1.segmentCount())//1 已是 2 的幂
        c1.close()
        let c3 = HeapCache<Test>(concurrencyLevel: 3, maxSize: 1_000_000)
        @Assert(4, c3.segmentCount())
        c3.close()
        let c17 = HeapCache<Test>(concurrencyLevel: 17, maxSize: 1_000_000)
        @Assert(32, c17.segmentCount())
        c17.close()
        let c100 = HeapCache<Test>(concurrencyLevel: 100, maxSize: 1_000_000)
        @Assert(128, c100.segmentCount())
        c100.close()
        let c128 = HeapCache<Test>(concurrencyLevel: 128, maxSize: 1_000_000)
        @Assert(128, c128.segmentCount())//已是 2 的幂 ⇒ 原值不动
        c128.close()
        let c200 = HeapCache<Test>(concurrencyLevel: 200, maxSize: 1_000_000)
        @Assert(256, c200.segmentCount())//显式值不受自动推导上限 128 的约束
        c200.close()
        let cBuilder = HeapCacheBuilder<Test>().setConcurrencyLevel(5).setMaxSize(1_000_000).build()
        @Assert(8, cBuilder.segmentCount())//builder 同样按 2 的幂取整
        cBuilder.close()
    }

    /**没有 ≥ concurrencyLevel 的 2 的幂可表示时（> 2^62）明确报错，而不是取到溢出后的负数 */
    @TestCase
    public func testConcurrencyLevelTooLargeThrows(): Unit {
        expectIllegalArgument {let _ = HeapCache<Test>(concurrencyLevel: (Int64(1) << 62) + 1, maxSize: 1_000_000)}
        expectIllegalArgument {let _ = HeapCache<Test>(concurrencyLevel: Int64.Max, maxSize: 1_000_000)}
    }

    /**
     * 淘汰比较快照：进堆前 snapshot 一次，堆内比较（compareSnapshot）之后不再受实时状态影响；
     * 且与实时比较（compare）遵循同一套排序规则。
     */
    @TestCase
    public func testEvictionSnapshotIsStableAndMatchesLiveCompare(): Unit {
        let older = Priority<Test>('old', Test(1), Duration.second * 30, Duration.second, false)
        let newer = Priority<Test>('new', Test(2), Duration.second * 30, Duration.second, false)
        older.incr()
        newer.incr()
        newer.incr()//newer 本周期用得多 ⇒ 更该保留
        @Assert(Ordering.LT, older.compare(newer))
        let now = DateTime.now()
        older.snapshot(now)
        newer.snapshot(now)
        @Assert(Ordering.LT, older.compareSnapshot(newer))
        //快照之后再改实时状态：堆内比较（读快照）不变；实时比较（compare）已反转
        older.store(Test(3))
        older.incr()
        older.incr()
        @Assert(Ordering.LT, older.compareSnapshot(newer))
        @Assert(Ordering.GT, older.compare(newer))
    }

    /**时间戳统一为 Unix 纳秒后的口径守护：deathNanos 与判定用的死亡时间一致；once 切换后按 birth 起算 */
    @TestCase
    public func testDeathNanosIsConsistentAndOnceSwitchesToBirth(): Unit {
        let p = Priority<Test>('k', Test(1), Duration.millisecond * 200, Duration.second, false)
        let (alive, dead) = p.aliveAndDeathNanos(DateTime.now())
        @Assert(true, alive)
        @Assert(dead, p.deathNanos)
        sleep(Duration.millisecond * 60)
        p.incr()//lastUsed 前进 ⇒ 非 once 时死亡时间随之推后
        let usedBased = p.deathNanos
        @Assert(true, usedBased > dead)
        p.once = true//切到 once：死亡时间改为从 birth 起算 ⇒ 回到（更早的）初值
        @Assert(dead, p.deathNanos)
    }

    @TestCase
    public func testHeapCacheIsResource(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30,
            checkDuration: Duration.millisecond * 200)
        cache.set('r1', Test(1))
        @Assert(false, cache.isClosed())
        cache.close()
        @Assert(true, cache.isClosed())
        cache.close()//close 可重复调用
        @Assert(true, cache.isClosed())
        //close 之后内部线程结束、定时器已取消、缓存已清空（清空后 size 不可读：会抛异常）
        for (f in cache.threadHandles()) {
            try {
                f.get(Duration.second * 3)
                @Assert(true)
            } catch (e: TimeoutException) {
                @Assert(false)
            }
        }
    }

    @TestCase
    public func testEvictionKeepsMoreUsedEntry(): Unit {
        //用量是 compare 的第一层依据：本次检查周期内被访问更多的条目应当活下来
        let cache = HeapCache<Test>(maxSize: 1, maxLife: Duration.second * 30,
            checkDuration: Duration.millisecond * 200)
        cache.set('hot', Test(1))
        cache.set('cold', Test(2))
        for (_ in 0..3) {
            let _ = cache.get('hot')
        }
        sleep(Duration.second)
        @Assert(true, cache.contains('hot'))
        @Assert(false, cache.contains('cold'))
    }

    @TestCase
    public func testCompareProtectsNewEntryBeyondOneLifecycle(): Unit {
        //只让「最后使用时间」一维不同、且相差超过一个生命周期：更老的应当「更小」⇒ 在最小堆里先被淘汰
        let checkDuration = Duration.second
        let oldP = Priority<Test>('old', Test(1), Duration.second * 30, checkDuration, false)
        sleep(Duration.millisecond * 1500)
        let newP = Priority<Test>('new', Test(2), Duration.second * 30, checkDuration, false)
        let q = PriorityQueue<Priority<Test>>.create<Priority<Test>>(capacity: 8)
        q.add(newP)
        q.add(oldP)
        @Assert('old', q.remove().getOrThrow().key)
    }

    @TestCase
    public func testCompareProtectsRecentlyUsedEntryWithinOneLifecycle(): Unit {
        //年龄接近（差 0.2 个周期）、用量与检查基线都相同：由「最后使用时间」这一层决出，更新的留下
        let checkDuration = Duration.second
        let first = Priority<Test>('first', Test(1), Duration.second * 30, checkDuration, false)
        sleep(Duration.millisecond * 200)
        let second = Priority<Test>('second', Test(2), Duration.second * 30, checkDuration, false)
        let q = PriorityQueue<Priority<Test>>.create<Priority<Test>>(capacity: 8)
        q.add(second)
        q.add(first)
        @Assert('first', q.remove().getOrThrow().key)
    }

    @TestCase
    public func testEvictionInAgeGapProtectsNewEntry(): Unit {
        //端到端：老的与新的同时成为候选（两个键各自落在不同分段）时，被淘汰的应是更老的那个
        let cache = HeapCache<Test>(maxSize: 1, maxLife: Duration.second * 30,
            checkDuration: Duration.second)
        cache.set('old', Test(1))
        sleep(Duration.millisecond * 1500)
        cache.set('new', Test(2))
        sleep(Duration.millisecond * 2500)
        @Assert(true, cache.contains('new'))
        @Assert(false, cache.contains('old'))
    }

    @TestCase
    public func testEvictionCallbackReceivesEvictedEntries(): Unit {
        //淘汰回调在内部消费线程上执行：用锁保护收集器，等 close()（会把已入队的回调投递完）后再断言
        let delivered = ArrayList<String>()
        let mtx = Mutex()
        let cache = HeapCache<Test>(maxSize: 1, maxLife: Duration.second * 30,
            checkDuration: Duration.millisecond * 200,
            evictionCallback: {k, _ => synchronized(mtx) {
                delivered.add(k)
            }})
        cache.set('a', Test(1))
        cache.set('b', Test(2))
        sleep(Duration.second)
        cache.close()
        //同分候选（都没被用过、都新鲜）里淘汰更老的 'a'（保护新生），回调应拿到它的键
        @Assert(1, delivered.size)
        @Assert('a', delivered[0])
    }

    /**
     * close() 不应等待淘汰消费线程的轮询超时（修复前阻塞在 `q.remove(100ms)`，close 需 ~100ms）。
     * 这里用 50ms 上限守护：哨兵唤醒后 close 应在毫秒级返回。
     */
    @TestCase
    public func testCloseDoesNotWaitForEvictionPollInterval(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30, checkDuration: Duration.second * 30)
        for (i in 0..5) {
            let _ = cache.set('p${i}', Test(i))
        }
        let t0 = MonoTime.now()
        cache.close()
        let spentMs = (MonoTime.now() - t0) / Duration.millisecond
        @Assert(true, spentMs < 50.0)
    }

    /**
     * 淘汰采样的链表序守护：每段候选是 LinkedHashMap 链表头（最久未访问），
     * 所以反复访问过的键必须存活。单段（concurrencyLevel = 1）时候选池只有链表头，最能暴露采样退化。
     */
    @TestCase
    public func testEvictionKeepsFrequentlyUsedKeys(): Unit {
        let cache = HeapCache<Test>(concurrencyLevel: 1, maxSize: 200, maxLife: Duration.second * 30,
            checkDuration: Duration.millisecond * 100)
        for (i in 0..400) {
            let _ = cache.set('e${i}', Test(i))
        }
        for (_ in 0..5) {
            for (i in 0..100) {
                let _ = cache.get('e${i}')
            }
        }
        sleep(Duration.millisecond * 700)
        @Assert(true, cache.size <= 200)
        var alive = 0
        for (i in 0..100) {
            if (cache.contains('e${i}')) {
                alive++
            }
        }
        @Assert(100, alive)
    }

    /** 段锁改互斥后的并发正确性：多线程各写各键，值不得串、size 不得丢 */
    @TestCase
    public func testConcurrentAccessDistinctKeys(): Unit {
        let cache = HeapCache<Test>(concurrencyLevel: 16, maxLife: Duration.second * 30,
            checkDuration: Duration.second * 30)
        let threads = 4
        let per = 200
        let futures = ArrayList<Future<Int64>>()
        for (t in 0..threads) {
            let myT = t
            futures.add(spawn {
                var ok: Int64 = 0
                for (i in 0..per) {
                    let k = 'c${myT}_${i}'
                    let _ = cache.set(k, Test(myT * 1000 + i))
                    if (let Some(v) <- cache.get(k)) {
                        if (v.value == myT * 1000 + i) {
                            ok++
                        }
                    }
                }
                ok
            })
        }
        var total: Int64 = 0
        for (f in futures) {
            total += f.get()
        }
        @Assert(threads * per, total)
        @Assert(threads * per, cache.size)
        cache.close()
    }

    /**
     * 段清扫的谓词约定守护：removeIf 的语义是「谓词返回 true ⇒ 删除」，
     * sweepLocked 依赖它（曾把语义写反，导致删活留死）。
     */
    @TestCase
    public func testSegmentRemoveIfDeletesWhenTrue(): Unit {
        let m = SyncLinkedHashMap<Test>()
        m.add('a', Test(1))
        m.add('b', Test(2))
        m.removeIfLocked {k, _ => k == 'a'}
        @Assert(1, m.size)
        @Assert(false, m.contains('a'))
        @Assert(true, m.contains('b'))
    }

    @TestCase
    public func testWeakHeapCacheIsResource(): Unit {
        let cache = WeakHeapCache<Test>()
        @Assert(1, cache.threadHandles().size)
        let _ = cache.set('wk', Test(1))
        @Assert(false, cache.isClosed())
        cache.close()
        @Assert(true, cache.isClosed())
        cache.close()//close 可重复调用
        @Assert(true, cache.isClosed())
        //close 返回时清扫线程已经结束（最多等一个清扫周期），而不是“还要再等一轮”
        for (f in cache.threadHandles()) {
            try {
                f.get(Duration.millisecond * 1)
                @Assert(true)
            } catch (e: TimeoutException) {
                @Assert(false)
            }
        }
        //关闭后一切操作都抛异常（只有 isClosed/close 例外）
        expectClosed {let _ = cache.get('wk')}
        expectClosed {let _ = cache.getOrDefault('wk', Test(0))}
        expectClosed {let _ = cache.getOrStore('wk', Test(0))}
        expectClosed {let _ = cache.getOrCompute('wk') {None<Test>}}
        expectClosed {let _ = cache.set('wk', Test(2))}
        expectClosed {let _ = cache.remove('wk')}
        expectClosed {cache.removeIf {_, _ => true}}
        expectClosed {let _ = cache.size}
        expectClosed {cache.clear()}
    }
}

public class Test <: ToString {
    private static var serial = 0
    public let value: Int64
    public init() {
        serial++
        value = serial
    }
    public init(val: Int64) {
        this.value = val
    }
    public func toString(): String {
        "Test(${value})"
    }
}
