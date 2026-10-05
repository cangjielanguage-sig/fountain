/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_pool

import std.collection.ArrayList
import std.convert.*
import std.fs.File
import std.runtime.gc
import std.sync.AtomicInt64
import fountain::f_pool.diagnostics.PoolDiagnostics

/**
 * 读 `/proc/self/stat` 的 utime+stime（时钟 tick，USER_HZ=100 ⇒ 1 tick ≈ 10ms）。
 * 非 Linux / 读不到时返回 None，调用方据此跳过 CPU 断言（`POOL-2` 的测量用，见 `.autocode/bugs/bug-pool.md` §1.2）。
 */
func procCpuTicks(): ?Int64 {
    try {
        let content = String.fromUtf8(File.readFrom("/proc/self/stat"))
        // 字段 2 是 (comm)，可能含空格与括号 ⇒ 从最后一个 ')' 之后开始切
        let close = content.lastIndexOf(")").getOrThrow()
        let parts = content[close + 1 .. content.size].trimAscii().split(" ")
        // 切完 parts[0] 是字段 3（state）⇒ utime（字段 14）= parts[11]，stime（字段 15）= parts[12]
        Int64.parse(parts[11]) + Int64.parse(parts[12])
    } catch (e: Exception) {
        None<Int64>
    }
}

@Test
public class KeyPoolTest {
    @TestCase
    public func test0(): Unit{
        println('~~~~~~~~~~~~~~~~~~')
        let start = MonoTime.now()
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','b','c','a','b','c'].iterator().next,
            minSize: 2,
            maxSize: 5,
            totalSize: 10,
            checkOnCreation: true,
            checkOnReturning: true,
            checkOnBorrowing: true,
            creator: {_=>Object()},
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        sleep(Duration.second * 2)
        @Assert(pool.size, 6)
        @Assert(pool.checkSize())
        let a1 = pool.get('a', timeout: Duration.second)
        @Assert(a1.isSome())
        let a2 = pool.get('a')
        @Assert(a2.isSome())
        let a3 = pool.get('a')
        @Assert(a3.isSome())
        let a4 = pool.get('a')
        @Assert(a4.isSome())
        let a5 = pool.get('a')
        @Assert(a5.isSome())
        @Assert(pool.size, 9)
        @Assert(pool.checkSize())
        let a6 = pool.get('a', timeout: Duration.second)
        @Assert(a6.isNone())
        let b1 = pool.get('b')
        let b2 = pool.get('b')
        let b3 = pool.get('b')
        @Assert(b3.isSome())
        let b4 = pool.get('b', timeout: Duration.second)
        @Assert(b4.isNone())
        let c1 = pool.get('c')
        @Assert(c1.isSome())
        let c2 = pool.get('c')
        @Assert(c2.isSome())
        pool.giveBack('a', a1.getOrThrow())
        @Assert(pool.get('a').isSome())
    }
    @TestCase
    public func testInvalidOnBorrowing(){
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: 3,
            totalSize: 3,
            checkOnCreation: false,
            checkOnReturning: false,
            checkOnBorrowing: true,
            creator: {_=>Object()},
            checker:{_,_=>false},
            destroier:{_,_=>}
        )
        sleep(Duration.second * 2)
        @Assert(pool.checkSize())
        @Assert(pool.size, 3)
        let a = pool.get('a', timeout: Duration.Zero)
        @Assert(a.isNone())
        @Assert(pool.checkSize())
        @Assert(pool.size, 0)
    }
    @TestCase
    public func testInvalidOnReturning(){
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: 3,
            totalSize: 3,
            checkOnCreation: false,
            checkOnReturning: true,
            checkOnBorrowing: false,
            creator: {_=>Object()},
            checker:{_,_=>false},
            destroier:{_,_=>}
        )
        let a1 = pool.get('a')
        pool.giveBack('a', a1.getOrThrow())
        let a2 = pool.get('a')
        pool.giveBack('a', a2.getOrThrow())
        let a3 = pool.get('a')
        pool.giveBack('a', a3.getOrThrow())
        sleep(Duration.second * 2)
        @Assert(pool.checkSize())
        @Assert(pool.size, 0)
    }
    @TestCase
    public func testFifo(){
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: 3,
            totalSize: 3,
            checkOnCreation: false,
            checkOnReturning: false,
            checkOnBorrowing: false,
            creator: {_=>Object()},
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        let a1 = pool.get('a').getOrThrow()
        let a2 = pool.get('a').getOrThrow()
        let a3 = pool.get('a').getOrThrow()
        pool.giveBack('a', a1)
        pool.giveBack('a', a2)
        pool.giveBack('a', a3)
        @Assert(refEq(pool.get('a').getOrThrow(), a1))
        @Assert(refEq(pool.get('a').getOrThrow(), a2))
        @Assert(refEq(pool.get('a').getOrThrow(), a3))
    }
    @TestCase
    public func testLifo(){
        let pool = KeyPool<String, Object>(
            mode: Lifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: 3,
            totalSize: 3,
            checkOnCreation: false,
            checkOnReturning: false,
            checkOnBorrowing: false,
            creator: {_=>Object()},
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        let a1 = pool.get('a').getOrThrow()
        let a2 = pool.get('a').getOrThrow()
        let a3 = pool.get('a').getOrThrow()
        pool.giveBack('a', a1)
        pool.giveBack('a', a2)
        pool.giveBack('a', a3)
        @Assert(refEq(pool.get('a').getOrThrow(), a3))
        @Assert(refEq(pool.get('a').getOrThrow(), a2))
        @Assert(refEq(pool.get('a').getOrThrow(), a1))
    }
    @TestCase
    public func testConcurrency(){
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: 3,
            totalSize: 10,
            checkOnCreation: false,
            checkOnReturning: false,
            checkOnBorrowing: false,
            creator: {_=>Object()},
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        let array = Array<Future<Unit>>(10, repeat: unsafe{zeroValue<Future<Unit>>()})
        for(i in 0 .. 10){
            array[i] = spawn{
                for(_ in 0 .. 1000){
                    let a = pool.get('a', timeout: Duration.Max).getOrThrow()
                    pool.giveBack('a', a)
                }
            }
        }
        for(f in array){
            f.get()
        }
    }
    /**
     * `maxWaiting` 是**池初始化参数**：池取空后 `get(timeout: Duration.Max)` 只在 maxWaiting 内等待，
     * 超过就记 WARN 并返回 None（.autocode/bugs/bug-archived-on-20261004.md 7.6）。这里用 200ms 而不是默认 30s，顺带证明它不是写死的常量。
     */
    @TestCase
    public func maxWaitingBoundsInfiniteWait(): Unit {
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: {=> None},
            maxSize: 1,
            totalSize: 1,
            checkInterval: Duration.Zero,
            maxWaiting: Duration.millisecond * 200,
            creator: {_=>Object()},
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        let held = pool.get('a', timeout: Duration.second).getOrThrow()   // 先占满（maxSize = 1）
        let start = MonoTime.now()
        let got = pool.get('a', timeout: Duration.Max)                    // 无限等待也必须受 maxWaiting 约束
        let elapsed = MonoTime.now() - start
        @Assert(got.isNone())
        @Assert(elapsed >= Duration.millisecond * 150)
        @Assert(elapsed < Duration.second * 5)                            // 不能退化成默认的 30s
        pool.giveBack('a', held)
        pool.close()
    }
    /**
     * 后台维护线程的"看护"：creator 连续抛异常后，创建线程必须还活着、能把池项补起来
     * （创建/巡检线程一旦静默退出，池就再也补不回项、也不会回收空闲项，见 .autocode/bugs/bug-archived-on-20261004.md 7.12）。
     */
    @TestCase
    public func scheduleSurvivesCallbackErrors(): Unit {
        let attempts = AtomicInt64(0)
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 2,
            maxSize: 3,
            totalSize: 10,
            checkInterval: Duration.minute,
            creator: {_ =>
                if (attempts.fetchAdd(1) < 2) {
                    throw Exception('creator boom')
                }
                Object()
            },
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        sleep(Duration.second * 2)
        @Assert(pool.size > 0)                                  // 两次异常之后仍自动创建成功 ⇒ 创建线程活着
        @Assert(pool.get('a', timeout: Duration.second).isSome())
        pool.close()
    }
    /** 巡检里带的审计自愈：至少跑过一轮后，全局 size 与各 key 队列之和必须一致（见 .autocode/bugs/bug-archived-on-20261004.md 7.2/7.12）。 */
    @TestCase
    public func auditRunsFromSchedule(): Unit {
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a'].iterator().next,
            minSize: 1,
            maxSize: 3,
            totalSize: 10,
            checkInterval: Duration.millisecond * 50,
            creator: {_=>Object()},
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        sleep(Duration.millisecond * 300)
        @Assert(pool.checkSize())
        PoolDiagnostics.dump(reason: 'after-schedule-audit')
        pool.close()
    }
    /**
     * `POOL-1`（`.autocode/bugs/bug-pool.md` §1.1）：**借出期间池项不得被销毁**。
     *
     * 借出时 `Ref<V>` 被解包后立即不可达，若不把它的值 `take()` 空，GC 终结器就会在借用方手里调
     * `destroier`（对连接/句柄类池项就是「借用中被关掉」）；显式销毁路径同理，`Ref.value` 仍在 ⇒
     * 同一个池项会被终结器销毁第二次。
     *
     * 用例覆盖两段：① 借出后强制 GC，销毁计数必须仍为 0，且归还后还能再借出；
     * ② `close()` 显式销毁空闲项一次后，再强制 GC 不得出现第二次销毁。
     */
    @TestCase
    public func borrowedItemMustNotBeDestroyedByFinalizer(): Unit {
        let destroyed = AtomicInt64(0)
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['k'].iterator().next,
            minSize: 0,
            maxSize: 1,
            totalSize: 1,
            idleTimeout: Duration.hour,
            checkOnCreation: false,
            checkOnBorrowing: false,
            checkOnReturning: false,
            checkInterval: Duration.Zero,
            maxWaiting: Duration.second,
            creator: {_ => Object()},
            checker: {_, _ => true},
            destroier: {_, _ => destroyed.fetchAdd(1)}
        )
        // 初始池项由创建线程异步创建
        var borrowed = None<Object>
        for (_ in 0 .. 300) {
            if (let Some(v) <- pool.get('k', timeout: Duration.Zero)) {
                borrowed = Some(v)
                break
            }
            sleep(Duration.millisecond * 10)
        }
        @Assert(borrowed.isSome())
        let o = borrowed.getOrThrow()
        @Assert(destroyed.load(), 0)
        gc()
        sleep(Duration.millisecond * 200)
        gc()
        sleep(Duration.millisecond * 200)
        // ① 借出期间被终结器销毁 ⇒ 这里失败
        @Assert(destroyed.load(), 0)
        pool.giveBack('k', o)
        let again = pool.get('k', timeout: Duration.second)
        @Assert(again.isSome())
        if (let Some(v) <- again) {
            pool.giveBack('k', v)
        }
        // ② close 销毁空闲项一次；再 gc 不得二次销毁
        pool.close()
        @Assert(destroyed.load(), 1)
        gc()
        sleep(Duration.millisecond * 200)
        gc()
        sleep(Duration.millisecond * 200)
        @Assert(destroyed.load(), 1)
    }
    /**
     * `POOL-2`（`.autocode/bugs/bug-pool.md` §1.2）：池耗尽时「有限超时」的等待**不得烧 CPU**。
     * 用 `/proc/self/stat` 的 utime+stime 差值判定（1 tick ≈ 10ms）：忙等 300ms ≈ 30 tick，park 等通知应 ≈ 0 tick。
     * 非 Linux 平台拿不到该文件 ⇒ 只验语义（仍返回 None）。
     */
    @TestCase
    public func finiteTimeoutWaitMustNotBurnCpu(): Unit {
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['k'].iterator().next,
            minSize: 0,
            maxSize: 1,
            totalSize: 1,
            idleTimeout: Duration.hour,
            checkOnCreation: false,
            checkOnBorrowing: false,
            checkOnReturning: false,
            checkInterval: Duration.Zero,
            maxWaiting: Duration.second,
            creator: {_ => Object()},
            checker: {_, _ => true},
            destroier: {_, _ => ()}
        )
        var held = None<Object>
        for (_ in 0 .. 300) {
            if (let Some(v) <- pool.get('k', timeout: Duration.Zero)) {
                held = Some(v)
                break
            }
            sleep(Duration.millisecond * 10)
        }
        @Assert(held.isSome())                       // 先占满（maxSize = 1）
        let before = procCpuTicks()
        let got = pool.get('k', timeout: Duration.millisecond * 300)
        let after = procCpuTicks()
        @Assert(got.isNone())
        if (let Some(b) <- before && let Some(a) <- after) {
            @Assert(a - b < 10)                      // 忙等会到 ~30 tick（修前实测 2s 等待烧 2.25s 用户态）
        }
        pool.close()
    }
    /**
     * `POOL-6`（§2.1）第一面：`close()` 必须**唤醒**正等池项的 `get`。
     * `maxWaiting = Duration.Max` + 池被借空 ⇒ 等待者只能靠 close 的通知回来；
     * 修前它要等内部 1s 分片到期（close 之后 ~0.9s），修后应当立刻返回。
     */
    @TestCase
    public func closeMustWakeWaitingGetter(): Unit {
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['k'].iterator().next,
            minSize: 0,
            maxSize: 1,
            totalSize: 1,
            idleTimeout: Duration.hour,
            checkOnCreation: false,
            checkOnBorrowing: false,
            checkOnReturning: false,
            checkInterval: Duration.Zero,
            maxWaiting: Duration.Max,
            creator: {_ => Object()},
            checker: {_, _ => true},
            destroier: {_, _ => ()}
        )
        var holder = None<Object>
        for (_ in 0 .. 300) {
            if (let Some(v) <- pool.get('k', timeout: Duration.Zero)) {
                holder = Some(v)
                break
            }
            sleep(Duration.millisecond * 10)
        }
        @Assert(holder.isSome())
        let waiter = spawn {
            pool.get('k')
        }
        sleep(Duration.millisecond * 100)            // 让等待者 park
        let t0 = MonoTime.now()
        pool.close()
        let got = waiter.get()
        let afterClose = MonoTime.now() - t0
        @Assert(got.isNone())
        @Assert(afterClose < Duration.millisecond * 700)
    }
    /**
     * `POOL-6`（§2.1）第二面：`giveBack` 与 `close` 交错时，池项**不得留在已关闭的池里**
     * （留下去既没人取也没人销毁）。每轮：借出唯一一项 ⇒ 并发「归还 ‖ 关池」⇒ 断言恰好销毁 1 次。
     */
    @TestCase
    public func giveBackRacingCloseMustNotStrandItem(): Unit {
        let rounds = 100
        let destroyed = AtomicInt64(0)
        for (i in 0 .. rounds) {
            let pool = KeyPool<String, Object>(
                mode: Fifo,
                initKeys: ['k'].iterator().next,
                minSize: 0,
                maxSize: 1,
                totalSize: 1,
                idleTimeout: Duration.hour,
                checkOnCreation: false,
                checkOnBorrowing: false,
                checkOnReturning: false,
                checkInterval: Duration.Zero,
                maxWaiting: Duration.second,
                creator: {_ => Object()},
                checker: {_, _ => true},
                destroier: {_, _ => destroyed.fetchAdd(1)}
            )
            var held = None<Object>
            for (_ in 0 .. 300) {
                if (let Some(v) <- pool.get('k', timeout: Duration.Zero)) {
                    held = Some(v)
                    break
                }
                sleep(Duration.millisecond * 2)
            }
            @Assert(held.isSome())
            let obj = held.getOrThrow()
            let returning = spawn {
                pool.giveBack('k', obj)
            }
            pool.close()
            returning.get()
            @Assert(destroyed.load() == i + 1)       // 这一项必须被销毁（不能滞留在已关闭的池里）
        }
    }
    /**
     * `POOL-5`（§1.5）：`maxWaiting = Duration.Max` 是**真无限等待** —— creator 慢 2s 也必须等到，
     * 不能因为内部等待分片到期就静默放弃（修前 1008ms 就返回 `None`）。
     */
    @TestCase
    public func infiniteWaitMustWaitForSlowCreation(): Unit {
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: {=> None},
            minSize: 0,
            maxSize: 1,
            totalSize: 1,
            idleTimeout: Duration.hour,
            checkOnCreation: false,
            checkOnBorrowing: false,
            checkOnReturning: false,
            checkInterval: Duration.Zero,
            maxWaiting: Duration.Max,
            creator: {_ =>
                sleep(Duration.second * 2)
                Object()
            },
            checker: {_, _ => true},
            destroier: {_, _ => ()}
        )
        let t0 = MonoTime.now()
        let got = pool.get('k')
        let elapsed = MonoTime.now() - t0
        @Assert(got.isSome())
        @Assert(elapsed >= Duration.millisecond * 1800)
        if (let Some(v) <- got) {
            pool.giveBack('k', v)
        }
        pool.close()
    }
    /**
     * `POOL-3`（`.autocode/bugs/bug-pool.md` §1.3）：满载（= 稳态）时巡检**不得**摘掉空闲项、也不得反复补建。
     * 修前 `BaseKeyPool.check` 把 `p.size < max` 写成了 checker 的与条件，而 checker 返回 false 表示
     * 「这一项失效 ⇒ 摘节点」⇒ 每轮巡检丢一个空闲项（探针实测 idle 2→1），补建还和计数更新赛跑。
     */
    @TestCase
    public func checkMustNotDropIdleItemWhenAtCap(): Unit {
        let created = AtomicInt64(0)
        let destroyed = AtomicInt64(0)
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['k', 'k'].iterator().next,
            minSize: 0,
            maxSize: 2,
            totalSize: 2,
            idleTimeout: Duration.hour,
            checkOnCreation: false,
            checkOnBorrowing: false,
            checkOnReturning: false,
            checkInterval: Duration.millisecond * 50,
            maxWaiting: Duration.second,
            creator: {_ =>
                created.fetchAdd(1)
                Object()
            },
            checker: {_, _ => true},
            destroier: {_, _ => destroyed.fetchAdd(1)}
        )
        sleep(Duration.millisecond * 300)            // 等两件都建好
        @Assert(created.load() == 2)
        sleep(Duration.millisecond * 500)            // 满载空闲跑 ~10 轮巡检
        let held = ArrayList<Object>()
        while (let Some(v) <- pool.get('k', timeout: Duration.Zero)) {
            held.add(v)
        }
        @Assert(held.size == 2)                      // 修前：掉到 1
        @Assert(created.load() == 2)                 // 修前：可能是 3（掉落 + 补建）
        @Assert(destroyed.load() == 0)               // 巡检不该销毁任何有效项
        for (v in held) {
            pool.giveBack('k', v)
        }
        pool.close()
    }
    /**
     * `POOL-3`（§1.3）第二面：满载时巡检必须**照常调用用户 checker**（否则 `idleTimeout` / `connectionLife`
     * 这类「按时间判失效」的业务判定会被整轮绕过）。这里 checker 恒判失效 ⇒ 该项必须被摘掉并销毁。
     */
    @TestCase
    public func checkerMustRunWhenAtCap(): Unit {
        let calls = AtomicInt64(0)
        let destroyed = AtomicInt64(0)
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['k'].iterator().next,
            minSize: 0,
            maxSize: 1,
            totalSize: 1,
            idleTimeout: Duration.hour,
            checkOnCreation: false,
            checkOnBorrowing: false,
            checkOnReturning: false,
            checkInterval: Duration.millisecond * 50,
            maxWaiting: Duration.second,
            creator: {_ => Object()},
            checker: {_, _ =>
                calls.fetchAdd(1)
                false
            },
            destroier: {_, _ => destroyed.fetchAdd(1)}
        )
        sleep(Duration.millisecond * 400)            // 建好 + 跑几轮巡检
        @Assert(calls.load() > 0)                    // 修前：checker 一次都没跑（恒 0）
        @Assert(destroyed.load() >= 1)               // 判失效的项必须被销毁
        pool.close()
    }
}

@Test
public class KeyPoolBench{
    private let pool = KeyPool<String, Object>(
        mode: Fifo,
        initKeys: ['a','a','a'].iterator().next,
        minSize: 0,
        maxSize: 3,
        totalSize: 10,
        checkOnCreation: false,
        checkOnReturning: false,
        checkOnBorrowing: false,
        creator: {_=>Object()},
        checker:{_,_=>true},
        destroier:{_,_=>}
    )
    @Bench
    public func bench(){
        let a = pool.get('a', timeout: Duration.Max).getOrThrow()
        pool.giveBack('a', a)
    }
}