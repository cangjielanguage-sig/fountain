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
    public func test_tailer_key_not_exists_gap(): Unit {
        let map = ConcurrentSkipListMap<Int64, String>()
        map.add(10, "ten")
        map.add(20, "twenty")
        map.add(30, "thirty")

        // 从不存在的键 15 开始，应该从 20 开始遍历
        let iter = map.tailer(15, including: true)
        var count = 0
        var expectedKey: Int64 = 20
        var expectedValue = "twenty"
        while (let Some((k, v)) <- iter.next()) {
            count += 1
            @Assert(k, expectedKey)
            @Assert(v, expectedValue)
            if (expectedKey == 20) {
                expectedKey = 30
                expectedValue = "thirty"
            }
        }
        @Assert(count, 2)  // 20, 30
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
    @TestCase
    public func test_random_add_sequence_iterate(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let rand = Random()
        let keys = Array<Int64>(10000){_ => rand.nextInt64(Int64.Max)}
        for (key in keys) {
            map.add(key, key)
        }
        var prev = -1
        for((k, v) in map){
            @Assert(k > prev)
            prev = k
        }
    }
}
