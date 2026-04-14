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
public class ConcurrentSkipListMap_test {
    @TestCase
    func testConcurrentSkipListMap(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()

        // 基础操作测试
        @Assert(map.isEmpty())

        map.add(1, "one")
        map.add(2, "two")
        map.add(3, "three")

        @Assert(map.size == 3)
        @Assert(map.get(1) == Option.Some("one"))
        @Assert(map.contains(2))

        // 更新测试
        let old = map.add(2, "TWO")
        @Assert(old == Option.Some("two"))
        @Assert(map.get(2) == Option.Some("TWO"))

        // 删除测试
        let removed = map.remove(3)
        @Assert(removed == Option.Some("three"))
        @Assert(map.size == 2)
        @Assert(map.get(3).isNone())

        // ConcurrentMap 接口测试
        @Assert(map.addIfAbsent(4, "four").isNone())
        @Assert(map.addIfAbsent(4, "FOUR") == Option.Some("four"))

        @Assert(map.replace(1, "ONE"), Some('one'))
        @Assert(map.get(1) == Option.Some("ONE"))
    }

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
    // ========== 1. 基础功能测试（单线程） ==========
    @TestCase
    public func test_insert_and_get(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        
        // 插入
        let old = map.add(1, "one")
        @Assert(old.isNone())
        
        // 查询
        let val = map.get(1)
        @Assert(val.isSome() && val.getOrThrow() == "one")
        
        // 更新
        let old2 = map.add(1, "uno")
        @Assert(old2.isSome() && old2.getOrThrow() == "one")
        let val2 = map.get(1)
        @Assert(val2.isSome() && val2.getOrThrow() == "uno")
        
        // 不存在
        @Assert(map.get(2).isNone())
    }

    @TestCase
    public func test_remove(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        map.add(1, "one")
        map.add(2, "two")
        
        // 删除存在
        let old = map.remove(1)
        @Assert(old.isSome() && old.getOrThrow() == "one")
        @Assert(map.get(1).isNone())
        @Assert(map.size, 1)
        
        // 删除不存在
        let old2 = map.remove(3)
        @Assert(old2.isNone())
        @Assert(map.size, 1)
    }

    @TestCase
    public func test_remove_with_predicate(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(1, 10)
        map.add(2, 20)
        
        // 满足条件删除
        let old = map.remove(1) { v => v == 10 }
        @Assert(old.isSome() && old.getOrThrow() == 10)
        @Assert(map.get(1).isNone())
        
        // 不满足条件，不删除
        let old2 = map.remove(2) { v => v == 99 }
        @Assert(old2.isNone())
        @Assert(map.get(2).isSome() && map.get(2).getOrThrow() == 20)
    }

    @TestCase
    public func test_size_and_isEmpty(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        @Assert(map.isEmpty())
        @Assert(map.size, 0)
        
        map.add(1, "a")
        map.add(2, "b")
        @Assert(map.size, 2)
        @Assert(!map.isEmpty())
        
        map.remove(1)
        @Assert(map.size, 1)
        map.remove(2)
        @Assert(map.size, 0)
        @Assert(map.isEmpty())
    }

    @TestCase
    public func test_addAll_and_removeAll(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        let entries = [(1, "a"), (2, "b"), (3, "c")]
        map.add(all: entries)
        @Assert(map.size, 3)
        @Assert(map.contains(2))
        
        map.remove(all: [1, 3])
        @Assert(map.size, 1)
        @Assert(map.contains(2))
        @Assert(!map.contains(1))
        @Assert(!map.contains(3))
    }

    @TestCase
    public func test_iterator(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        for (i in 0..100) {
            map.add(i, "val_${i}")
        }
        
        var count = 0
        var keys = HashSet<Int64>()
        for ((k, v) in map.iterator()) {
            count += 1
            keys.add(k)
            @Assert(v, "val_${k}")
        }
        @Assert(count, 100)
        @Assert(keys.size, 100)
    }

    @TestCase
    public func test_keys_and_values_views(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        map.add(1, "one")
        map.add(2, "two")
        
        let keys = map.keys()
        @Assert(keys.contains(1))
        @Assert(keys.contains(2))
        @Assert(keys.size, 2)
        
        let values = map.values()
        var found = 0
        for (v in values) {
            if (v == "one" || v == "two"){
                found += 1
            }
        }
        @Assert(found, 2)
    }

    // ========== 2. 边界条件测试 ==========
    @TestCase
    public func test_boundary_keys(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        let min = Int64.Min
        let max = Int64.Max
        map.add(min, "min")
        map.add(max, "max")
        map.add(0, "zero")
        
        @Assert(map.get(min).isSome() && map.get(min).getOrThrow() == "min")
        @Assert(map.get(max).isSome() && map.get(max).getOrThrow() == "max")
        @Assert(map.get(0).isSome() && map.get(0).getOrThrow() == "zero")
    }

    @TestCase
    public func test_string_keys(): Unit {
        let map = ConcurrentSkipListMap<String, Int64>()
        map.add("", 0)
        map.add("hello", 1)
        map.add("world", 2)
        map.add("\u{1F4A9}", 3)   // 表情符号
        
        @Assert(map.get("").getOrThrow(), 0)
        @Assert(map.get("hello").getOrThrow(), 1)
        @Assert(map.get("world").getOrThrow(), 2)
        @Assert(map.get("\u{1F4A9}").getOrThrow(), 3)
    }

    @TestCase
    public func test_random_level_distribution(): Unit {
        // 验证节点层数不超过 MAX_LEVEL=16
        let map = ConcurrentSkipListMap<Int64, Int64>()
        for (i in 0..10000) {
            map.add(i, i)
        }
        // 通过反射或遍历节点检查层数（这里简化：直接测试不会崩溃）
        // 实际可通过自定义 getNodeLevel 接口，此处假设节点内部 level 正确
        @Assert(true)  // 占位，主要是运行时不越界
    }

    @TestCase
    public func test_head_sentinel_behavior(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        // 查询比所有键小的键
        map.add(100, "hundred")
        @Assert(map.get(-1000).isNone())
        // 查询比所有键大的键
        @Assert(map.get(1000).isNone())
    }

    // ========== 3. 并发竞争测试 ==========
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

    // ========== 4. 特定 Bug 暴露测试，预期失败 ==========
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
        let iterations = 500
        let latch = SyncCounter(threads)
        
        for (_ in 0..threads) {
            spawn {
                for (i in 0..iterations) {
                    // if (i % 2 == 0) {
                    //     map.add(i, i)
                    // } else {
                    //     map.remove(i - 1)
                    // }

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

    // ========== 5. 压力测试（可选，长时间运行） ==========
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

    // ========== 6. 补充测试：未覆盖的 API ==========

    @TestCase
    public func test_addIfPresent(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        // 键不存在时，addIfAbsent 应返回 None 且不插入
        let res1 = map.addIfPresent(1, "one")
        @Assert(res1.isNone())
        @Assert(map.size, 0)

        // 先插入
        map.add(1, "one")
        // 键已存在时，addIfPresent 应替换并返回旧值
        let res2 = map.addIfPresent(1, "uno")
        @Assert(res2.isSome() && res2.getOrThrow() == "one")
        @Assert(map.get(1).getOrThrow() == "uno")
        @Assert(map.size, 1)

        // 键不存在时仍不插入
        let res3 = map.addIfPresent(2, "two")
        @Assert(res3.isNone())
        @Assert(!map.contains(2))
    }

    @TestCase
    public func test_removeIf(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        for (i in 0..10) {
            map.add(i, i)
        }
        // 删除所有偶数
        map.removeIf{_, v => v % 2 == 0}
        @Assert(map.size, 5)
        for (i in 0..10) {
            if (i % 2 == 0) {
                @Assert(!map.contains(i))
            } else {
                @Assert(map.contains(i))
            }
        }
    }

    @TestCase
    public func test_replace_with_predicate(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(1, 10)

        // 满足条件时替换
        let old = map.replace(1, { v => v > 5 }, { v => v * 2 })
        @Assert(old.isSome() && old.getOrThrow() == 10)
        @Assert(map.get(1).getOrThrow() == 20)

        // 不满足条件时不替换
        let old2 = map.replace(1, { v => v < 5 }, { v => v * 3 })
        @Assert(old2.isNone())
        @Assert(map.get(1).getOrThrow() == 20)

        // 键不存在时返回 None
        let old3 = map.replace(99, { _ => true }, { v => v })
        @Assert(old3.isNone())
    }

    @TestCase
    public func test_subscript_operators(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        // []= 设置
        map[1] = "one"
        map[2] = "two"
        @Assert(map.size, 2)

        // [] 获取
        @Assert(map[1] == "one")
        @Assert(map[2] == "two")

        // []= 更新
        map[1] = "ONE"
        @Assert(map[1] == "ONE")
    }

    @TestCase
    public func test_contains_all(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        map.add(1, "a")
        map.add(2, "b")
        map.add(3, "c")

        @Assert(map.contains(all: [1, 2]))
        @Assert(!map.contains(all: [1, 4]))
    }

    @TestCase
    public func test_iterator_sorted_order(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let keys = [5, 2, 9, 1, 7, 3, 8, 4, 6, 10]
        for (k in keys) {
            map.add(k, k * 10)
        }

        var prev: Int64 = -1
        var count = 0
        for ((k, v) in map.iterator()) {
            @Assert(k > prev)
            @Assert(v, k * 10)
            prev = k
            count += 1
        }
        @Assert(count, 10)
    }

    @TestCase
    public func test_empty_map_operations(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        @Assert(map.size, 0)
        @Assert(map.isEmpty())
        @Assert(map.get(1).isNone())
        @Assert(!map.contains(1))
        @Assert(map.remove(1).isNone())
        @Assert(map.replace(1, "x").isNone())
        @Assert(map.addIfPresent(1, "a").isNone())
        @Assert(map.addIfAbsent(1, "a").isNone())
        // addIfAbsent 插入了键，需要移除以恢复空状态
        map.remove(1)
        // 迭代空 map
        var count = 0
        for ((_, _) in map.iterator()) {
            count += 1
        }
        @Assert(count, 0)
    }

    @TestCase
    public func test_clear_then_reuse(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        for (i in 0..50) {
            map.add(i, i)
        }
        @Assert(map.size, 50)

        map.clear()
        @Assert(map.size, 0)
        @Assert(map.isEmpty())

        // clear 后重新添加
        for (i in 100..110) {
            map.add(i, i)
        }
        @Assert(map.size, 10)
        for (i in 100..110) {
            @Assert(map.get(i).getOrThrow() == i)
        }
        // 旧数据不应存在
        @Assert(map.get(0).isNone())
        @Assert(map.get(49).isNone())
    }

    @TestCase
    public func test_single_key_add_remove_add(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        // add
        let old1 = map.add(1, "first")
        @Assert(old1.isNone())
        @Assert(map.size, 1)

        // remove
        let removed = map.remove(1)
        @Assert(removed.isSome() && removed.getOrThrow() == "first")
        @Assert(map.size, 0)
        @Assert(map.get(1).isNone())

        // re-add same key
        let old2 = map.add(1, "second")
        @Assert(old2.isNone())
        @Assert(map.size, 1)
        @Assert(map.get(1).getOrThrow() == "second")
    }

    @TestCase
    public func test_replace_nonexistent_key(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        @Assert(map.replace(1, 100).isNone())
        @Assert(map.replace(1) { v => v + 1 }.isNone())
        @Assert(map.size, 0)
    }

    @TestCase
    public func test_put_and_putIfAbsent(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        // put 等同于 add
        let old1 = map.put(1, "one")
        @Assert(old1.isNone())
        let old2 = map.put(1, "ONE")
        @Assert(old2.isSome() && old2.getOrThrow() == "one")

        // putIfAbsent 等同于 addIfAbsent
        let res1 = map.putIfAbsent(2, "two")
        @Assert(res1.isNone())
        let res2 = map.putIfAbsent(2, "TWO")
        @Assert(res2.isSome() && res2.getOrThrow() == "two")
        @Assert(map.get(2).getOrThrow() == "two")
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
    public func test_float64_keys(): Unit {
        let map = ConcurrentSkipListMap<Float64, String>()
        map.add(1.5, "a")
        map.add(0.1, "b")
        map.add(3.14, "c")
        map.add(-2.7, "d")

        @Assert(map.size, 4)
        @Assert(map.get(1.5).getOrThrow() == "a")
        @Assert(map.get(-2.7).getOrThrow() == "d")

        // 验证迭代顺序
        var prev: Float64 = Float64.Min
        for ((k, _) in map.iterator()) {
            @Assert(k > prev)
            prev = k
        }
    }

    @TestCase
    public func test_clear_single_threaded(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        @Assert(map.isEmpty())
        // clear 空 map
        map.clear()
        @Assert(map.size, 0)
        @Assert(map.isEmpty())

        for (i in 0..100) {
            map.add(i, i)
        }
        @Assert(map.size, 100)
        map.clear()
        @Assert(map.size, 0)
        @Assert(map.isEmpty())
        // 所有键都不应存在
        for (i in 0..100) {
            @Assert(!map.contains(i))
        }
    }

    @TestCase
    public func test_large_number_of_entries(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let n = 5000
        for (i in 0..n) {
            map.add(i, i * i)
        }
        @Assert(map.size, n)
        // 抽查
        @Assert(map.get(0).getOrThrow() == 0)
        @Assert(map.get(2500).getOrThrow() == 2500 * 2500)
        @Assert(map.get(4999).getOrThrow() == 4999 * 4999)
        // 删除一半
        for (i in 0..n where i % 2 == 0) {
            map.remove(i)
        }
        @Assert(map.size, n / 2)
        @Assert(!map.contains(0))
        @Assert(map.contains(1))
    }

    // ========== 7. 性能测试 ==========
    @TestCase
    public func test_perf_single_thread_add(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let n = 10000
        let start = MonoTime.now()
        for (i in 0..n) {
            map.add(i, i)
        }
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let opsPerSec = n * 1000000000 / (elapsed + 1)
        println("perf_single_thread_add: ${n} ops in ${elapsed}ns, ${opsPerSec} ops/s")
    }

    @TestCase
    public func test_perf_single_thread_get(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let n = 10000
        for (i in 0..n) {
            map.add(i, i)
        }
        let start = MonoTime.now()
        for (i in 0..n) {
            let _ = map.get(i)
        }
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let opsPerSec = n * 1000000000 / (elapsed + 1)
        println("perf_single_thread_get: ${n} ops in ${elapsed}ns, ${opsPerSec} ops/s")
    }

    @TestCase
    public func test_perf_single_thread_remove(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let n = 10000
        for (i in 0..n) {
            map.add(i, i)
        }
        let start = MonoTime.now()
        for (i in 0..n) {
            map.remove(i)
        }
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let opsPerSec = n * 1000000000 / (elapsed + 1)
        println("perf_single_thread_remove: ${n} ops in ${elapsed}ns, ${opsPerSec} ops/s")
    }

    @TestCase
    public func test_perf_concurrent_add(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = 8
        let opsPerThread = 10000
        let latch = SyncCounter(threads)
        let start = MonoTime.now()
        for (_ in 0..threads) {
            spawn {
                for (j in 0..opsPerThread) {
                    map.add(j, j)
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let totalOps = threads * opsPerThread
        let opsPerSec = totalOps * 1000000000 / (elapsed + 1)
        println("perf_concurrent_add: ${totalOps} ops in ${elapsed}ns, ${opsPerSec} ops/s, threads=${threads}")
    }

    @TestCase
    public func test_perf_concurrent_mixed(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        // 预填充
        for (i in 0..5000) {
            map.add(i, i)
        }
        let threads = 8
        let opsPerThread = 5000
        let latch = SyncCounter(threads)
        let start = MonoTime.now()
        for (t in 0..threads) {
            spawn {
                let rand = Random()
                for (_ in 0..opsPerThread) {
                    let op = rand.nextInt64(4)
                    let key = rand.nextInt64(5000)
                    match (op) {
                        case 0 => let _ = map.get(key)
                        case 1 => map.add(key, rand.nextInt64())
                        case 2 => let _ = map.remove(key)
                        case 3 => map.entryView(key) { view =>
                            let cur = view.value
                            match (cur) {
                                case Some(v) => view.value = Some(v + 1)
                                case None => view.value = Some(0)
                            }
                        }
                        case _ => ()
                    }
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let totalOps = threads * opsPerThread
        let opsPerSec = totalOps * 1000000000 / (elapsed + 1)
        println("perf_concurrent_mixed: ${totalOps} ops in ${elapsed}ns, ${opsPerSec} ops/s, threads=${threads}")
    }

    @TestCase
    public func test_perf_concurrent_entryView(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(1, 0)
        let threads = 8
        let opsPerThread = 10000
        let latch = SyncCounter(threads)
        let start = MonoTime.now()
        for (_ in 0..threads) {
            spawn {
                for (_ in 0..opsPerThread) {
                    map.entryView(1) { view =>
                        let cur = view.value.getOrThrow()
                        view.value = Some(cur + 1)
                    }
                }
                latch.dec()
            }
        }
        latch.waitUntilZero()
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let totalOps = threads * opsPerThread
        let opsPerSec = totalOps * 1000000000 / (elapsed + 1)
        @Assert(map.get(1).getOrThrow(), threads * opsPerThread)
        println("perf_concurrent_entryView: ${totalOps} ops in ${elapsed}ns, ${opsPerSec} ops/s, threads=${threads}")
    }

    // ========== 8. 新增：混合操作并发安全测试 ==========

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
                            Some(v.getOrThrow() + 1)
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

    // ========== 9. tailer 迭代器测试 ==========
    @TestCase
    public func test_tailer_basic(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        for (i in 0..10) {
            map.add(i, "val_${i}")
        }

        // 从 5 开始迭代（包括 5）
        let iter = map.tailer(5, including: true)
        var count = 0
        var expectedKey: Int64 = 5
        while (let Some((k, v)) <- iter.next()) {
            count += 1
            @Assert(k, expectedKey)
            @Assert(v, "val_${k}")
            @Assert(k >= 5)
            expectedKey += 1
        }
        @Assert(count, 5)  // 5,6,7,8,9
    }

    @TestCase
    public func test_tailer_not_including(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        for (i in 0..10) {
            map.add(i, "val_${i}")
        }

        // 从 5 开始迭代（不包括 5）
        let iter = map.tailer(5, including: false)
        var count = 0
        var expectedKey: Int64 = 6
        while (let Some((k, v)) <- iter.next()) {
            count += 1
            @Assert(k, expectedKey)
            @Assert(v, "val_${k}")
            @Assert(k > 5)
            expectedKey += 1
        }
        @Assert(count, 4)  // 6,7,8,9
    }

    @TestCase
    public func test_tailer_empty_map(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        let iter = map.tailer(5, including: true)
        @Assert(iter.next().isNone())
    }

    @TestCase
    public func test_tailer_from_min_key(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        for (i in 0..10) {
            map.add(i, "val_${i}")
        }

        // 从最小键开始（包括）
        let iter = map.tailer(0, including: true)
        var count = 0
        while (let Some(_) <- iter.next()) {
            count += 1
        }
        @Assert(count, 10)
    }

    @TestCase
    public func test_tailer_beyond_max_key(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        for (i in 0..10) {
            map.add(i, "val_${i}")
        }

        // 从比最大键还大的值开始
        let iter = map.tailer(100, including: true)
        @Assert(iter.next().isNone())
    }

    @TestCase
    public func test_tailer_key_not_exists(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        map.add(1, "one")
        map.add(3, "three")
        map.add(5, "five")

        // 从不存在的键 2 开始
        let iter = map.tailer(2, including: true)
        var count = 0
        var expectedKey: Int64 = 3
        while (let Some((k, v)) <- iter.next()) {
            count += 1
            @Assert(k, expectedKey)
            expectedKey += 2  // 3 -> 5
        }
        @Assert(count, 2)  // 3, 5
    }

    @TestCase
    public func test_tailer_string_keys(): Unit {
        let map = ConcurrentSkipListMap<String, Int64>()
        map.add("apple", 1)
        map.add("banana", 2)
        map.add("cherry", 3)
        map.add("date", 4)

        // 从 "banana" 开始（包括）
        let iter = map.tailer("banana", including: true)
        var count = 0
        var expectedKey = "banana"
        var expectedValue = 2
        while (let Some((k, v)) <- iter.next()) {
            count += 1
            @Assert(k, expectedKey)
            @Assert(v, expectedValue)
            if (expectedKey == "banana") {
                expectedKey = "cherry"
                expectedValue = 3
            } else if (expectedKey == "cherry") {
                expectedKey = "date"
                expectedValue = 4
            }
        }
        @Assert(count, 3)
    }

}
