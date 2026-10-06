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
import std.runtime.{gc, getThreadCount}
import std.ref.{CleanupPolicy, WeakRef}
import std.sync.{AtomicBool, AtomicInt64}
import fountain::f_exception.IllegalSizeException
import fountain::f_pool.diagnostics.PoolDiagnostics
import fountain::f_pool.exception.{ClearFailedException, UnknownKeyException}

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
     * `POOL-L6`（`.autocode/bugs/bug-pool.md` §3）防回归：`maxWaiting` 取 `Duration.Max` **附近的有限值**
     * （最容易被当成「几乎无限」的写法）时，等待里算剩余时间**不得**做 `MonoTime + Duration`。
     *
     * 基线 `waitChunk` 的 `waitStart + maxWaiting - MonoTime.now()` 在这里会抛
     * `ArithmeticException: Arithmetic overflow: result exceeds MonoTime range`
     * （`std.time::MonoTime::+`，探针 `pool_probe hugearn` 实测），而 `get` 没有 try ⇒ 异常直接抛给调用方。
     * 其余量已实测排除：巨值有限 `remain` 交给 `Condition.wait(timeout:)` 是**睡下去**而不是溢出
     * （探针 `condwait`）。所以本用例通过 = 「纯减法 + 无限档不做算术」这个写法还在。
     */
    @TestCase
    public func hugeFiniteMaxWaitingMustNotOverflow(): Unit {
        let created = AtomicInt64(0)
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
            checkInterval: Duration.Max,
            maxWaiting: Duration.Max - Duration.nanosecond,   // 有限但巨值：走 `limit - elapsed` 那条路
            creator: {_ =>
                created.fetchAdd(1)
                sleep(Duration.millisecond * 1500)
                Object()
            },
            checker: {_, _ => true},
            destroier: {_, _ => ()}
        )
        let t0 = MonoTime.now()
        let got = pool.get('k', timeout: Duration.Max)         // ⇒ limit = maxWaiting（巨值有限）
        let elapsed = MonoTime.now() - t0
        @Assert(got.isSome())                                  // 基线写法：这里会先抛 ArithmeticException
        @Assert(created.load() >= 1)
        @Assert(elapsed >= Duration.millisecond * 1400)        // 真的等到了慢创建，而不是早退/立即返回
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
    /**
     * `POOL-7`（`.autocode/bugs/bug-pool.md` §2.2）：`close()` 之后**内部维护线程必须退出**。
     * 建/关 20 个池（`checkInterval = Duration.Zero` ⇒ 每个池只有创建线程），线程数必须回落到基线附近；
     * 修前创建线程永久 park 在无超时出队上，`close()` 唤不醒（实测 7→27、关池后仍 27）。
     */
    @TestCase
    public func closeMustReclaimInternalThread(): Unit {
        let pools = ArrayList<Pool<Object>>()
        let before = getThreadCount()
        for (_ in 0 .. 20) {
            pools.add(Pool<Object>(
                mode: Fifo,
                initSize: 0,
                minSize: 0,
                maxSize: 1,
                idleTimeout: Duration.hour,
                checkInterval: Duration.Zero,
                maxWaiting: Duration.second,
                creator: {=> Object()},
                checker: {_ => true},
                destroier: {_ => ()}
            ))
        }
        sleep(Duration.millisecond * 300)
        for (p in pools) {
            p.close()
        }
        sleep(Duration.millisecond * 1600)           // 带超时出队最多 1s 才醒来 + 退出
        let after = getThreadCount()
        @Assert(after <= before + 5)                 // 修前：before + 20
    }
    /**
     * `POOL-8`（`.autocode/bugs/bug-pool.md` §2.3）：`ArrayPool` / `ArrayListPool` 的默认
     * `maxSize = Int64.Max` 不得让构造失败。修前任务队列按池容量预分配 ⇒ `ArrayPool<Int64>()`
     * 直接 `Out of memory`（整个测试进程挂掉），这里连构造都过不去。
     */
    @TestCase
    public func arrayPoolDefaultsMustConstruct(): Unit {
        let bytes = ArrayPool<Int64>()
        let list = ArrayListPool<Int64>()
        if (let Some(x) <- bytes.get(timeout: Duration.second)) {
            bytes.giveBack(x)
        } else {
            @Assert(false)
        }
        if (let Some(x) <- list.get(timeout: Duration.second)) {
            list.giveBack(x)
        } else {
            @Assert(false)
        }
    }
    /** 从 `PoolDiagnostics.snapshot()` 里取 `key=数字` 计数值（找不到返回 -1）。 */
    private func diagCounter(key: String): Int64 {
        for (token in PoolDiagnostics.snapshot().split(' ')) {
            if (token.startsWith(key)) {
                return Int64.parse(token[key.size ..])
            }
        }
        -1
    }
    /**
     * `POOL-L7`（`.autocode/bugs/bug-pool.md` §3）：`ArrayPool.giveBack` 收到**尺寸不符**的数组必须抛
     * `IllegalSizeException` —— 抛出即表示**这次没有归还**：数组仍在调用方手里（池无权销毁它），
     * 借出它的那个池的那份额度也不会结清（口径同 §2.5 `POOL-10`、§2.7 `POOL-12`）。
     * 修前是静默 `return false`：`DefaultCodec` / `BytesCopier` 两个调用点都在 `finally` 里忽略了返回值
     * ⇒ 漏判返回值就等于无声无息地漏容量。
     */
    @TestCase
    public func arrayPoolWrongSizeReturnMustThrow(): Unit {
        let pool = ArrayPool<Int64>(initSize: 1, minSize: 1, maxSize: 1, arraySize: 128, maxWaiting: Duration.second)
        var borrowed = None<Array<Int64>>
        for (_ in 0 .. 300) {
            if (let Some(a) <- pool.get(timeout: Duration.Zero)) {
                borrowed = Some(a)
                break
            }
            sleep(Duration.millisecond * 2)
        }
        @Assert(borrowed.isSome())
        let before = diagCounter('returnRejected=')
        @Assert(before >= 0, true)                            // 快照里必须有这个计数（修前：没有 ⇒ 到这里就失败）
        var threw = false
        try {
            pool.giveBack(Array<Int64>(64, repeat: 0))        // 外来数组：尺寸不符
        } catch (_: IllegalSizeException) {
            threw = true
        }
        @Assert(threw)                                        // 修前：静默返回 false，不抛
        @Assert(diagCounter('returnRejected='), before + 1)   // 异常必留痕（应用层吞掉异常也看得见）
        // 残量（已知、登记在 §3 POOL-L7）：借出的那一项没回来 ⇒ `maxSize = 1` 的池那份额度被永久占住
        @Assert(pool.get(timeout: Duration.Zero).isNone())
        // 尺寸正确的归还照常工作（同一个池）
        pool.giveBack(borrowed.getOrThrow())
        if (let Some(a) <- pool.get(timeout: Duration.Zero)) {
            pool.giveBack(a)
        } else {
            @Assert(false)
        }
    }
    /**
     * `POOL-10`（`.autocode/bugs/bug-pool.md` §2.5）端到端：把从 `k1` 借出的对象还到 `k2`（没有池的键）
     * ⇒ `giveBack` 抛 `UnknownKeyException`，且**什么都不做**（不归还、不销毁）。
     * 修前这里静默跳过：对象被丢掉、`k1` 那份额度留在 `out` 上再也回不来（见用例末尾的残量断言）。
     */
    @TestCase
    public func giveBackToUnknownKeyMustThrow(): Unit {
        let destroyed = AtomicInt64(0)
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['k1'].iterator().next,
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
            if (let Some(v) <- pool.get('k1', timeout: Duration.Zero)) {
                held = Some(v)
                break
            }
            sleep(Duration.millisecond * 2)
        }
        @Assert(held.isSome())
        let obj = held.getOrThrow()
        var thrown = false
        try {
            pool.giveBack('k2', obj)                     // 还错键
        } catch (e: UnknownKeyException) {
            thrown = true
            match (e.key) {                              // key 是 Any：键类型只有 Hashable & Equatable 约束
                case k: String => @Assert(k, 'k2')
                case _ => @Assert(false)
            }
        }
        @Assert(thrown)                                  // 修前：不抛，对象静默消失（只剩 GC 终结器那条路）
        @Assert(destroyed.load(), 0)                     // 池不替应用层销毁：所有权仍在调用方
        // 残量（已知、非期望）：来源键 `k1` 的这份额度记在 `out` 上永远回不来 ⇒ 唯一一项借不回来，
        // 也不补建（`keyedSize(k1) == maxSize`）。自检不变量 s ≡ 节点数 + out 仍成立，所以不会告警、不会自愈。
        @Assert(pool.get('k1', timeout: Duration.Zero).isNone())
        pool.close()                                     // 关池后 remaining 的项由 close 销毁
    }
    /**
     * `POOL-11`（`.autocode/bugs/bug-pool.md` §2.6）：`remove(key)` 先关闭 + 销毁该键的池，再把键从键表里摘掉
     * （`keyCount` 归位、`size` 只减去该键名下的）。修前**没有这个入口**：键表只增不减，空池条目、
     * 队列对象与巡检每轮 O(#keys) 的遍历都是永久成本。
     */
    @TestCase
    public func removeMustDestroyKeyPoolAndForgetKey(): Unit {
        let destroyed = AtomicInt64(0)
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['k1', 'k1', 'k2'].iterator().next,    // k1 建两项、k2 建一项（maxSize 限住 k1 的第三项）
            minSize: 0,
            maxSize: 2,
            totalSize: 3,
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
        for (_ in 0 .. 500) {
            if (pool.size >= 3) {
                break
            }
            sleep(Duration.millisecond * 2)
        }
        @Assert(pool.size, 3)
        @Assert(pool.keyCount(), 2)
        // 借走 k1 的一项：它会留在调用方手里 —— remove 只销毁池里的，不碰借出的
        let held = pool.get('k1', timeout: Duration.second)
        @Assert(held.isSome())
        pool.remove('k1')
        @Assert(destroyed.load(), 1)                         // k1 池里那 1 项被销毁（借出的那项不动）
        @Assert(pool.keyCount(), 1)                          // k1 从键表里消失
        @Assert(pool.size, 1)                                // 账本只剩 k2 的那一项
        // 摘掉之后，借出的那一项回不来了：`giveBack` 抛 `UnknownKeyException`（见 §2.5 POOL-10），
        // 需要应用层自己销毁 —— 这里断言抛，且**不**销毁（销毁计数不变）
        var thrown = false
        try {
            pool.giveBack('k1', held.getOrThrow())
        } catch (e: UnknownKeyException) {
            thrown = true
        }
        @Assert(thrown)
        @Assert(destroyed.load(), 1)
        // 键可以重新用起来：get 会按需重建它的池，之后借还正常（不是「废键」）
        let again = pool.get('k1', timeout: Duration.second)
        @Assert(again.isSome())
        @Assert(pool.keyCount(), 2)
        pool.giveBack('k1', again.getOrThrow())              // 重建后的池认得这个键：不抛
        @Assert(destroyed.load(), 1)
        pool.close()
        @Assert(pool.keyCount(), 0)
    }
    /**
     * `POOL-11`（§2.6）第二面：`close()` 返回前必须销毁所有键的池并清空键表；关停之后 `get` 直接 `None`、
     * `giveBack` 直接销毁、都不许把键表长回来。修前：键表留着（`BaseKeyPool.destroy` 只清池项、不删 map 项），
     * 而且 `giveBack` 要靠「取回来再销毁」的兜底 —— 那条兜底会重新建池，把「清空键表」破坏掉。
     */
    @TestCase
    public func closeMustDestroyAllKeysAndClearKeyTable(): Unit {
        let destroyed = AtomicInt64(0)
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['k1', 'k2'].iterator().next,
            minSize: 0,
            maxSize: 2,
            totalSize: 4,
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
        for (_ in 0 .. 500) {
            if (pool.size >= 2) {
                break
            }
            sleep(Duration.millisecond * 2)
        }
        @Assert(pool.size, 2)
        @Assert(pool.keyCount(), 2)
        pool.close()
        @Assert(destroyed.load(), 2)                         // 两个键的池项都被销毁
        @Assert(pool.keyCount(), 0)                          // 键表清空
        @Assert(pool.size, 0)
        @Assert(pool.get('k1', timeout: Duration.Zero).isNone())
        @Assert(pool.keyCount(), 0)                          // get 不许把键表长回来
        pool.giveBack('k1', Object())                        // 关停后归还：直接销毁，不抛
        @Assert(destroyed.load(), 3)
        @Assert(pool.keyCount(), 0)
        pool.close()                                         // 幂等：不再销毁、不再计数
        @Assert(destroyed.load(), 3)
    }
    /**
     * `POOL-12`（`.autocode/bugs/bug-pool.md` §2.7）：归还前的 `clear` 回调抛异常 = 应用层 BUG ⇒
     * `giveBack` 抛 `ClearFailedException`（原始回调异常挂在 `suppressed` 上），并且**这次归还没有发生**：
     * 不销毁、不结清记账、不进池 —— 对象所有权仍在调用方，修好之后可以**重试** `giveBack`。
     * 修前：抛的是回调自己的裸异常（不是 `ClearFailedException`）⇒ 本用例的 catch 接不住。
     */
    @TestCase
    public func clearFailureMustNotCountAsReturned(): Unit {
        let destroyed = AtomicInt64(0)
        let failFirst = AtomicBool(true)                     // 第一次 clear 抛，之后成功（模拟「修好了再来还」）
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
            clearOnReturning: true,
            checkInterval: Duration.Zero,
            maxWaiting: Duration.second,
            creator: {_ => Object()},
            checker: {_, _ => true},
            destroier: {_, _ => destroyed.fetchAdd(1)},
            clear: {_, _ =>
                if (failFirst.compareAndSwap(true, false)) {
                    throw Exception('clear failed')
                }
            }
        )
        let obj = pool.get('k', timeout: Duration.second).getOrThrow()
        @Assert(pool.size, 1)
        var caught = None<ClearFailedException>
        try {
            pool.giveBack('k', obj)
        } catch (e: ClearFailedException) {
            caught = Some(e)
        } catch (_: Exception) {
            // 修前（裸照抛）：回调异常直接溜到调用方 ⇒ 这里接住，让下面的断言干净地失败
        }
        @Assert(caught.isSome(), true)                       // 修前：抛的是裸 Exception ⇒ 这里不是它
        @Assert(destroyed.load(), 0)                         // 没归还 ⇒ 不销毁（所有权仍归调用方）
        @Assert(pool.size, 1)                                // 记账也没结清（这一项仍记在「借出」上，不是丢了）
        @Assert(caught.getOrThrow().suppressed.size, 1)      // 被顶掉的那个回调异常挂着，现场没丢
        // 修好之后重试归还：成功 ⇒ 项回到池里、额度照常结清
        pool.giveBack('k', obj)
        @Assert(destroyed.load(), 0)
        @Assert(pool.get('k', timeout: Duration.Zero).isSome())
        @Assert(pool.size, 1)
        pool.close()
    }
    /**
     * `POOL-13`（`.autocode/bugs/bug-pool.md` §2.8）**残量守卫**。
     *
     * 本次修复：`ExitCallbacks.atExit` 注册的回调**只持有弱引用**（`WeakRef`），不再把 `KeyPool` 实例钉在
     * `atExit` 注册表里 —— 修前它是绑定 `this` 的 `close` 方法引用（强引用），每建一个池就多一条永不注销的回调。
     *
     * 但池 `close()` 之后**仍然回收不掉**，原因换成了另一个：探针 `threadhold`（`.autocode/tmp/pool_fix13_probe4.log`）
     * 证明这套运行时**保留已结束线程的闭包** —— 一个对象只要 `spawn` 过引用自己的线程，就永远回收不掉
     * （线程退出不 join、join 之后都一样）；而 `KeyPool` 的两个维护线程正是这种形状。
     *
     * 所以这条用例现在钉的是「**还活着**」这个已知残量：等它不再成立（运行时释放已结束线程的闭包，
     * 或把两个维护线程改成只捕获「可清空的上下文」），应把这条断言反过来（改成断言可回收）。
     */
    @TestCase
    public func closedPoolStillPinnedByWorkerThreadClosure(): Unit {
        let weak = makeClosedPoolWeak()
        for (_ in 0 .. 4) {
            gc()
            sleep(Duration.millisecond * 200)
        }
        @Assert(weak.value.isSome(), true)           // 残量：线程闭包（运行时保留）仍持有池
    }
    /** 建一个池、关掉它，只把弱引用返回（池的强引用随本栈帧消失）。 */
    private func makeClosedPoolWeak(): WeakRef<KeyPool<String, Object>> {
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
        let weak = WeakRef<KeyPool<String, Object>>(pool, CleanupPolicy.EAGER)
        pool.close()
        weak
    }
    /**
     * `POOL-L2`（`.autocode/bugs/bug-pool.md` §3）正面一：`checkInterval = Duration.Max` = **不启用巡检** ——
     * 不许再起巡检线程。修前它会起一个 `sleep(Duration.Max)`（实测不抛异常、永不醒来、关池也叫不醒）的线程：
     * 建/关 20 个池后线程数停在基线 +20。`BytesListOutputStream.builder` 的默认值就是 `Duration.Max`，
     * 所以这条直接决定那些编码缓冲池的线程开销。
     */
    @TestCase
    public func maxIntervalMustNotStartCheckingThread(): Unit {
        let before = getThreadCount()
        let pools = ArrayList<Pool<Object>>()
        for (_ in 0 .. 20) {
            pools.add(Pool<Object>(
                mode: Fifo,
                initSize: 0,
                minSize: 0,
                maxSize: 1,
                idleTimeout: Duration.hour,
                checkInterval: Duration.Max,
                maxWaiting: Duration.second,
                creator: {=> Object()},
                checker: {_ => true},
                destroier: {_ => ()}
            ))
        }
        sleep(Duration.millisecond * 300)
        for (p in pools) {
            p.close()
        }
        sleep(Duration.millisecond * 1600)               // 创建线程带超时出队最多 1s 后才醒 + 退出
        @Assert(getThreadCount() <= before + 5, true)    // 修前：+20（巡检线程停在 sleep(Duration.Max)）
    }
    /**
     * `POOL-L2`（§3）正面二，同时补上 `POOL-7` 的漏网（那条用例用 `checkInterval = Duration.Zero`，
     * 只覆盖了创建线程）：`close()` 之后**巡检线程也必须及时退出**，不能 park 满一个巡检周期。
     * 修前：`sleep(Duration.hour)` 叫不醒 ⇒ 20 个池的巡检线程要睡满一小时（关池后仍停在基线 +20）。
     */
    @TestCase
    public func closeMustInterruptCheckingSleep(): Unit {
        let before = getThreadCount()
        let pools = ArrayList<Pool<Object>>()
        for (_ in 0 .. 20) {
            pools.add(Pool<Object>(
                mode: Fifo,
                initSize: 0,
                minSize: 0,
                maxSize: 1,
                idleTimeout: Duration.hour,
                checkInterval: Duration.hour,            // 很长但有限：语义上仍然要巡检
                maxWaiting: Duration.second,
                creator: {=> Object()},
                checker: {_ => true},
                destroier: {_ => ()}
            ))
        }
        sleep(Duration.millisecond * 300)
        for (p in pools) {
            p.close()
        }
        sleep(Duration.millisecond * 1600)
        @Assert(getThreadCount() <= before + 5, true)    // 修前：+20（巡检线程睡在 1 小时上）
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