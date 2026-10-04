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

import std.runtime.gc
import std.sync.AtomicInt64
import fountain::f_pool.diagnostics.PoolDiagnostics

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