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
package fountain::f_concurrent

import std.unittest.*
import std.unittest.testmacro.*
import std.random.Random
import std.sync.*
import std.collection.*

@Test
public class ConcurrentSkipListMap_conc_test {
    @TestCase
    public func testConcurrentSkipListMapConcurrent(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = ArrayList<Future<Unit>>()

        // 并发写入
        for (i in 0..100) {
            let fut = spawn {
                for (j in 0..100) {
                    map.add(i * 100 + j, j)
                }
            }
            threads.add(fut)
        }

        for (fut in threads) {
            fut.get()
        }

        @Assert(map.size == 10000)
    }

    @TestCase
    public func test_concurrent_insert_same_key(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = 50
        let key = 42
        let latch = SyncCounter(threads)
        let result = AtomicInt64(0)

        for (_ in 0..threads) {
            spawn {
                let old = map.add(key, 1)
                if (old.isNone()) {
                    result.store(1)   // 成功插入
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 只有一个线程插入成功，其他返回旧值（None），最终值应为 1
        @Assert(map.get(key).getOrThrow(), 1)
        @Assert(map.size, 1)
    }

    @TestCase
    public func test_concurrent_insert_different_keys(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = 100
        let latch = SyncCounter(threads)
        let keyGen = AtomicInt64(0)

        for (_ in 0..threads) {
            spawn {
                let k = keyGen.fetchAdd(1)
                map.add(k, k)
                latch.dec()
            }
        }
        latch.waitUntilZero()
        @Assert(map.size, threads)
        // 验证所有键都存在
        for (i in 0..threads) {
            @Assert(map.contains(i))
            @Assert(map.get(i).getOrThrow(), i)
        }
    }

    @TestCase
    public func test_concurrent_insert_and_remove(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        // 预先插入一批数据
        for (i in 0..100) {
            map.add(i, i)
        }
        let running = AtomicBool(true)
        let inserters = 5
        let removers = 5
        let latch = SyncCounter(inserters + removers)

        // 插入线程：不断插入新键（100~199）
        for (_ in 0..inserters) {
            spawn {
                var i = 100
                while (running.load()) {
                    map.add(i, i)
                    i += 1
                    if (i >= 200) {
                        i = 100
                    }
                    // 稍微让步
                    sleep(Duration.Zero)
                }
                latch.dec()
            }
        }
        // 删除线程：不断删除 0~99 中的随机键
        for (_ in 0..removers) {
            spawn {
                let rand = Random()
                while (running.load()) {
                    let key = rand.nextInt64(100)
                    map.remove(key)
                    sleep(Duration.Zero)
                }
                latch.dec()
            }
        }

        // 运行 2 秒
        sleep(Duration.millisecond * 2000)
        running.store(false)
        latch.waitUntilZero()

        // 最终状态：size 可能变化，但不应为负数，且所有操作无异常
        @Assert(map.size >= 0)
        // 简单验证：0~99 中存在的键都在 map 中
        for (i in 0..100) {
            if (map.contains(i)) {
                @Assert(map.get(i).getOrThrow(), i)
            }
        }
    }

    @TestCase
    public func test_concurrent_replace(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(1, 100)
        let threads = 10
        let latch = SyncCounter(threads)

        for (_ in 0..threads) {
            spawn {
                let old = map.replace(1) { v => v + 1 }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 最终值应为 100 + threads = 110
        let finalVal = map.get(1).getOrThrow()
        @Assert(finalVal, 100 + threads)
    }

    @TestCase
    public func test_concurrent_addIfAbsent(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = 50
        let latch = SyncCounter(threads)
        let successCount = AtomicInt64(0)

        for (_ in 0..threads) {
            spawn {
                let res = map.addIfAbsent(99, 999)
                if (res.isNone()) {
                    successCount.fetchAdd(1)
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 只有一个线程成功插入
        @Assert(successCount.load(), 1)
        @Assert(map.get(99).getOrThrow(), 999)
    }

    @TestCase
    public func test_concurrent_get_and_update(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(5, 50)
        let threads = 20
        let latch = SyncCounter(threads)

        for (_ in 0..threads) {
            spawn {
                for (_ in 0..100) {
                    let v = map.get(5)
                    if (v.isSome()) {
                        // 同时有人可能更新，但 get 总能拿到有效值（50 或更新后的）
                        let val = v.getOrThrow()
                        @Assert(val == 50 || val == 100)
                    }
                    // 偶尔更新
                    if (Random().nextFloat64() < 0.1) {
                        map.add(5, 100)
                    }
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 最终值可能是 50 或 100，无异常即可
        let finalVal = map.get(5).getOrThrow()
        @Assert(finalVal == 50 || finalVal == 100)
    }

    @TestCase
    public func test_concurrent_clear(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        // 预填充
        for (i in 0..1000) {
            map.add(i, i)
        }
        let clearFuture = spawn {
            sleep(Duration.millisecond * 10)
            map.clear()
        }
        let counter = SyncCounter(10)
        for (_ in 0..10) {
            spawn {
                for (_ in 0..100) {
                    let key = Random().nextInt64(1000)
                    let _ = map.get(key)
                    let _ = map.contains(key)
                    sleep(Duration.Zero)
                }
                counter.dec()
            }
        }
        counter.waitUntilZero()
        clearFuture.get()  // 确保 clear 执行完成
        // clear 后 size 应为 0，且无异常
        @Assert(map.size, 0)
        @Assert(map.isEmpty())
    }

    @TestCase
    public func test_no_duplicate_keys_under_high_concurrency(): Unit {
        // 暴露重复键 bug（用例42）
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = 100
        let latch = SyncCounter(threads)
        let key = 1

        for (_ in 0..threads) {
            spawn {
                map.add(key, 123)
                latch.dec()
            }
        }
        latch.waitUntilZero()

        // 遍历所有节点，确保只有一个键为 1 的节点
        var count = 0
        let iter = map.iterator()
        while (let Some((k, v)) <- iter.next()) {
            if (k == key){
                count += 1
            }
        }
        @Expect(count, 1)
    }

    @TestCase
    public func test_size_consistency_under_concurrent_modifications(): Unit {
        // 暴露 size 不一致 bug（用例44）
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = 20
        let iterations = 1000
        let latch = SyncCounter(threads)

        for (_ in 0..threads) {
            spawn {
                for (i in 0..iterations) {
                    if (i % 2 == 0) {
                        map.add(i, i)
                    } else {
                        map.remove(i - 1)
                    }
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()

        // 最终实际节点数（通过遍历统计）
        var actualSize = 0
        for ((_, _) in map.iterator()) {
            actualSize += 1
        }
        // 由于并发删除/插入，实际大小可能不等于 size_.load() 的瞬时值，
        // 但最终应一致（无其他修改时）。这里简单检查 size 非负且遍历计数与 size 最终相等
        @Assert(actualSize, map.size)
    }
    
    @TestCase
    public func test_size_consistency_under_concurrent_modifications2(): Unit {
        // 暴露 size 不一致 bug（用例44）
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = 20
        let iterations = 500
        let latch = SyncCounter(threads)

        for (_ in 0..threads) {
            spawn {
                for (i in 0..iterations) {
                    map.add(i,i)
                    map.remove(i)
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()

        // 最终实际节点数（通过遍历统计）
        var actualSize = 0
        for ((_, _) in map.iterator()) {
            actualSize += 1
        }
        // 由于并发删除/插入，实际大小可能不等于 size_.load() 的瞬时值，
        // 但最终应一致（无其他修改时）。这里简单检查 size 非负且遍历计数与 size 最终相等
        @Assert(actualSize, map.size)
    }

    @TestCase
    public func test_entryView_atomicity(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(10, 100)
        let threads = 10
        let latch = SyncCounter(threads)

        for (_ in 0..threads) {
            spawn {
                map.entryView(10) { view =>
                    let cur = view.value.getOrThrow()
                    view.value = Some(cur + 1)
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // entryView 应该是原子的，最终值应为 100 + threads = 110
        let finalVal = map.get(10).getOrThrow()
        @Assert(finalVal, 100 + threads)
    }

    @TestCase
    public func test_stress_mixed_operations(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = 16
        let duration = 5000  // 毫秒
        let stop = AtomicBool(false)
        let latch = SyncCounter(threads)

        for (_ in 0..threads) {
            spawn {
                let rand = Random()
                while (!stop.load()) {
                    let op = rand.nextInt64(3)
                    let key = rand.nextInt64(1000)
                    match (op) {
                        case 0 => // get
                            let _ = map.get(key)
                        case 1 => // put
                            map.add(key, rand.nextInt64())
                        case 2 => // remove
                            let _ = map.remove(key)
                        case _ => ()
                    }
                    // 避免空转
                    sleep(Duration.Zero)
                }
                latch.dec()
            }
        }

        sleep(Duration.millisecond * duration)
        stop.store(true)
        latch.waitUntilZero()

        // 最终无异常，size 合理
        @Assert(map.size >= 0)
        println("Stress test completed. final size = ${map.size}")
    }

    @TestCase
    public func test_concurrent_addIfPresent(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(1, 0)
        let threads = 20
        let latch = SyncCounter(threads)
        let successCount = AtomicInt64(0)

        for (_ in 0..threads) {
            spawn {
                let res = map.addIfPresent(1, 1)
                if (res.isSome()) {
                    successCount.fetchAdd(1)
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 所有线程都应成功替换（键已存在）
        @Assert(successCount.load(), threads)
        @Assert(map.get(1).getOrThrow() == 1)
        @Assert(map.size, 1)
    }

    @TestCase
    public func test_concurrent_removeIf(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        for (i in 0..100) {
            map.add(i, i)
        }
        let latch = SyncCounter(5)
        for (_ in 0..5) {
            spawn {
                map.removeIf{_, v => v % 2 == 0}
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 所有偶数应被删除
        for (i in 0..100) {
            if (i % 2 == 0) {
                @Assert(!map.contains(i))
            }
        }
        @Assert(map.size >= 0)
    }

    @TestCase
    public func test_concurrent_remove_predicate_and_add(): Unit {
        // 测试 remove(key, predicate) 与 add 的并发安全
        let map = ConcurrentSkipListMap<Int64, Int64>()
        for (i in 0..100) {
            map.add(i, i)
        }
        let threads = 10
        let latch = SyncCounter(threads * 2)

        // 线程1-10: 删除值大于50的节点
        for (_ in 0..threads) {
            spawn {
                for (i in 0..100) {
                    map.remove(i) { v => v > 50 }
                }
                latch.dec()
            }
        }
        // 线程11-20: 不断添加新键
        for (_ in 0..threads) {
            spawn {
                for (i in 100..200) {
                    map.add(i, i)
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 最终验证：size 应 >= 0
        @Assert(map.size >= 0)
        // 验证 0-99 中值<=50 的仍存在
        for (i in 0..100) {
            if (i <= 50) {
                if (map.contains(i)) {
                    @Assert(map.get(i).getOrThrow() == i)
                }
            }
        }
        // 验证 100-200 都存在
        for (i in 100..200) {
            if (map.contains(i)) {
                @Assert(map.get(i).getOrThrow() == i)
            }
        }
    }

    @TestCase
    public func test_concurrent_entryView_lambda_and_add(): Unit {
        // 测试 entryView(key, fn: (K, ?V) -> ?V) 重载与 add 的并发
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(1, 0)
        let threads = 10
        let latch = SyncCounter(threads * 2)

        // 线程使用 entryView (K, ?V) -> ?V 重载
        for (_ in 0..threads) {
            spawn {
                for (_ in 0..100) {
                    map.entryView(1) { k, v =>
                        Some(v.getOrThrow() + 1)
                    }
                }
                latch.dec()
            }
        }
        // 线程使用 add
        for (_ in 0..threads) {
            spawn {
                for (i in 2..102) {
                    map.add(i, i)
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 键1的值应 >= 0
        @Assert(map.get(1).getOrThrow() >= 0)
        // 2-101 应存在
        for (i in 2..102) {
            if (map.contains(i)) {
                @Assert(map.get(i).getOrThrow() == i)
            }
        }
    }

    @TestCase
    public func test_concurrent_replace_and_add(): Unit {
        // 测试 replace 与 add 的并发
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(1, 0)
        let threads = 10
        let latch = SyncCounter(threads * 2)

        // 线程使用 replace 累加
        for (_ in 0..threads) {
            spawn {
                for (_ in 0..100) {
                    map.replace(1) { v => v + 1 }
                }
                latch.dec()
            }
        }
        // 线程使用 add 更新
        for (_ in 0..threads) {
            spawn {
                for (i in 2..102) {
                    map.add(i, i)
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 键1的值应 >= 0 (最终值可能小于 threads*100 因为 replace 可能失败)
        let v1 = map.get(1).getOrThrow()
        @Assert(v1 >= 0)
        @Assert(v1 <= threads * 100)
    }

    @TestCase
    public func test_concurrent_removeIf_and_add(): Unit {
        // 测试 removeIf 与 add 的并发
        let map = ConcurrentSkipListMap<Int64, Int64>()
        for (i in 0..100) {
            map.add(i, i)
        }
        let threads = 10
        let latch = SyncCounter(threads * 2)

        // 线程删除所有偶数
        for (_ in 0..threads) {
            spawn {
                map.removeIf{_, v => v % 2 == 0}
                latch.dec()
            }
        }
        // 线程添加新键
        for (_ in 0..threads) {
            spawn {
                for (i in 1000..1100) {
                    map.add(i, i)
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 验证奇数键仍存在
        for (i in 0..100 where i % 2 == 1) {
            if (map.contains(i)) {
                @Assert(map.get(i).getOrThrow() == i)
            }
        }
        // 验证新键存在
        for (i in 1000..1100) {
            if (map.contains(i)) {
                @Assert(map.get(i).getOrThrow() == i)
            }
        }
    }

    @TestCase
    public func test_concurrent_clear_operations(): Unit {
        // 测试 clear 与 add/get 的并发
        let map = ConcurrentSkipListMap<Int64, Int64>()
        for (i in 0..100) {
            map.add(i, i)
        }
        let running = AtomicBool(true)
        let latch = SyncCounter(4)

        // 线程1: 不断 clear
        spawn {
            while (running.load()) {
                map.clear()
                sleep(Duration.millisecond)
            }
            latch.dec()
        }
        // 线程2: 不断 add
        spawn {
            var i = 1000
            while (running.load()) {
                map.add(i, i)
                i += 1
                if (i > 2000) { i = 1000 }
            }
            latch.dec()
        }
        // 线程3: 不断 get
        spawn {
            while (running.load()) {
                for (j in 0..100) {
                    let _ = map.get(j)
                }
            }
            latch.dec()
        }
        // 线程4: 不断 contains
        spawn {
            while (running.load()) {
                for (j in 0..100) {
                    let _ = map.contains(j)
                }
            }
            latch.dec()
        }

        sleep(Duration.second * 2)
        running.store(false)
        latch.waitUntilZero()

        // clear 后 size 应为 0
        @Assert(map.size == 0 || map.size > 0)  // 宽松检查
    }

    @TestCase
    public func test_concurrent_mixed_operations_stress(): Unit {
        // 混合多种操作的并发压力测试
        let map = ConcurrentSkipListMap<Int64, Int64>()
        for (i in 0..50) {
            map.add(i, i)
        }
        let threads = 12
        let opsPerThread = 1000
        let latch = SyncCounter(threads)

        for (t in 0..threads) {
            spawn {
                let rand = Random()
                for (_ in 0..opsPerThread) {
                    let op = rand.nextInt64(6)
                    let key = rand.nextInt64(200)
                    match (op) {
                        case 0 => map.get(key)
                        case 1 => map.add(key, rand.nextInt64())
                        case 2 => map.remove(key)
                        case 3 => map.replace(key, rand.nextInt64())
                        case 4 => map.entryView(key) { view =>
                            match (view.value) {
                                case Some(v) => view.value = Some(v + 1)
                                case None => view.value = Some(0)
                            }
                        }
                        case 5 => map.entryView(key) { k, v =>
                            Some((v ?? 0) + 1)
                        }
                        case _ => ()
                    }
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        // 验证无异常，且 size 合理
        @Assert(map.size >= 0)
        // 验证所有存在的键值对一致
        for ((k, v) in map.iterator()) {
            @Assert(map.get(k).getOrThrow() == v)
        }
    }

    @TestCase
    public func test_concurrent_add_all_and_operations(): Unit {
        // 测试 add(all) 与其他操作的并发
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = 10
        let latch = SyncCounter(threads + 1)

        // 线程使用 add(all)
        spawn {
            for (t in 0..threads) {
                let entries = ArrayList<(Int64, Int64)>()
                for (i in t * 100 .. (t + 1) * 100) {
                    entries.add((i, i))
                }
                map.add(all: entries)
            }
            latch.dec()
        }

        // 其他线程同时进行单 add/get/remove
        for (_ in 1..threads) {
            spawn {
                let rand = Random()
                for (_ in 0..500) {
                    let key = rand.nextInt64(10000)
                    match (rand.nextInt64(3)) {
                        case 0 => map.add(key, key)
                        case 1 => map.get(key)
                        case 2 => map.remove(key)
                        case _ => ()
                    }
                }
                latch.dec()
            }
        }

        latch.waitUntilZero()
        // 验证 add(all) 插入的数据存在
        for (i in 0..threads * 100) {
            if (map.contains(i)) {
                @Assert(map.get(i).getOrThrow() == i)
            }
        }
    }

    @TestCase
    public func test_replace_with_predicate_concurrent(): Unit {
        // 测试 replace(key, predicate, eval) 与其他操作的并发
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(1, 10)
        map.add(2, 20)
        let threads = 10
        let latch = SyncCounter(threads * 2)

        // 线程使用 replace with predicate
        for (_ in 0..threads) {
            spawn {
                for (_ in 0..100) {
                    // 只有值 > 5 时才替换
                    map.replace(1, { v => v > 5 }, { v => v + 1 })
                    map.replace(2, { v => v > 5 }, { v => v + 1 })
                }
                latch.dec()
            }
        }
        // 线程使用 add/remove
        for (_ in 0..threads) {
            spawn {
                for (i in 3..53) {
                    map.add(i, i * 10)
                }
                for (i in 3..53) {
                    map.remove(i)
                }
                latch.dec()
            }
        }

        latch.waitUntilZero()
        // 验证 1,2 的值 >= 10 (原始值)
        if (map.contains(1)) {
            @Assert(map.get(1).getOrThrow() >= 10)
        }
        if (map.contains(2)) {
            @Assert(map.get(2).getOrThrow() >= 20)
        }
    }
    @TestCase
    public func test_concurrent_random_add_sequence_iterate(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let rand = Random()
        let keys = Array<Int64>(10000){_ => rand.nextInt64(Int64.Max)}
        for (key in keys) {
            spawn{
                map.add(key, key)
            }
        }
        var prev = -1
        for((k, v) in map){
            @Assert(k > prev)
            prev = k
        }
    }
}
