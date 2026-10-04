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
import std.time.DateTime

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
        @Assert(cache.contains("test2"))
        @Assert(cache.contains("test1"))
        @Assert(!cache.contains("test3"))
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
        cache.close()
        @Assert(0, cache.size)
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
    public func testHeapCacheIsResource(): Unit {
        let cache = HeapCache<Test>(maxLife: Duration.second * 30,
            checkDuration: Duration.millisecond * 200)
        cache.set('r1', Test(1))
        @Assert(false, cache.isClosed())
        cache.close()
        @Assert(true, cache.isClosed())
        cache.close()//close 可重复调用
        @Assert(true, cache.isClosed())
        //close 之后内部线程结束、定时器已取消、缓存已清空
        for (f in cache.threadHandles()) {
            try {
                f.get(Duration.second * 3)
                @Assert(true)
            } catch (e: TimeoutException) {
                @Assert(false)
            }
        }
        @Assert(0, cache.size)
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
        //清扫线程最多一个清扫周期（1s）后退出
        for (f in cache.threadHandles()) {
            try {
                f.get(Duration.second * 3)
                @Assert(true)
            } catch (e: TimeoutException) {
                @Assert(false)
            }
        }
        @Assert(0, cache.size)
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
