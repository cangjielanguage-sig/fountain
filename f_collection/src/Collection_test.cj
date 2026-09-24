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
package fountain::f_collection

import std.unittest.*
import std.unittest.testmacro.*
import std.random.Random
import std.collection.*

@Test
public class Collection_test {
    private let array = createArray(10)

    private static func createArray(size: Int64): Array<Int64> {
        Array<Int64>(size) {i => i + 1}
    }
    private func createMap(map: Map<Int64, Int64>, array: Array<Int64>): Map<Int64, Int64> {
        for (i in array) {
            map.add(i, i)
        }
        map
    }
    private func createLinkedHashMap(): Map<Int64, Int64> {
        let map = LinkedHashMap<Int64, Int64>()
        createMap(map, array)
    }
    private func createHashMap(array: Array<Int64>): Map<Int64, Int64> {
        let map = HashMap<Int64, Int64>()
        for (i in array) {
            map.add(i, i)
        }
        map
    }
    private func testSeqMap(map: Map<Int64, Int64>): Unit {
        var i = 0
        for ((k, v) in map) {
            let a = array[i]
            @Assert(k == a)
            i++
        }
    }

    private func shuffleArray(): Array<Int64> {
        shuffleArray(this.array)
    }
    private func shuffleArray(src: Array<Int64>): Array<Int64> {
        let rand = Random()
        let array = Array<Int64>(src.size) {i => src[i]}
        for (i in 0..array.size) {
            let idx = rand.nextInt64(array.size)
            let tmp = array[i]
            array[i] = array[idx]
            array[idx] = tmp
        }
        array
    }

    @TestCase
    public func testLinkedHashMap1(): Unit {
        let map = createLinkedHashMap()
        testSeqMap(map)
        let rand = Random()
        let list = ArrayList<Int64>(array)
        for (i in array) {
            let r = rand.nextInt64(array.size)
            let v = list.remove(at: r)
            list.add(v)
            map.remove(v)
            map.add(v, v)
        }
        @Assert(map.size, list.size)
        var i = 0
        for ((k, v) in map) {
            @Assert(k, list[i])
            i++
        }
    }
    @TestCase
    public func testLinkedHashMap2(): Unit {
        let map = LinkedHashMap<Int64, Int64>()
        map.add(1, 1)
        map.add(2, 2)
        map.add(3, 3)
        map.add(2, 2)
        map.get(1)
        let arr = [3, 2, 1]
        @Assert(arr.size, map.size)
        var i = 0
        for ((k, v) in map) {
            @Assert(k, arr[i])
            i++
        }
    }
    @TestCase
    public func testLinkedHashMap3(): Unit {
        let map = LinkedHashMap<Int64, Int64>(3, true)
        map.add(1, 1)
        map.add(2, 2)
        map.add(3, 3)
        map.add(4, 4)
        let arr = [2, 3, 4]
        @Assert(arr.size, map.size)
        var i = 0
        for ((k, v) in map) {
            @Assert(k, arr[i])
            i++
        }
    }
    @TestCase
    public func testLinkedHashMap4(): Unit {
        let map = LinkedHashMap<Int64, Int64>(3, true)
        map.add(1, 1)
        map.add(2, 2)
        map.add(3, 3)
        map.add(2, 2)
        let arr = [1, 3, 2]
        @Assert(arr.size, map.size)
        var i = 0
        for ((k, v) in map) {
            @Assert(k, arr[i])
            i++
        }
    }
    @TestCase
    public func testPriorityQueue(): Unit {
        let array = createArray(16)
        let shuffled = shuffleArray(array)
        let queue = PriorityQueue<Int64>.create<Int64>()
        for (v in shuffled) {
            queue.add(v)
        }
        @Assert(array.size, queue.size)
        println(queue.toArray())
        var i = 0
        while (!queue.isEmpty()) {
            let val = queue.remove().getOrThrow()
            @Assert(array[i], val)
            i++
        }
    }
    @TestCase
    public func testPriorityQueueDiscard(): Unit {
        let array = createArray(32)
        let shuffled = shuffleArray(array)
        let queue = PriorityQueue<Int64>.create<Int64>(growOnFull: false)
        for (v in shuffled) {
            queue.add(v)
        }
        @Assert(16, queue.size)
        println(queue.toArray())
    }
    @TestCase
    public func testPriorityQueueGrowable(): Unit {
        let array = createArray(32)
        let shuffled = shuffleArray(array)
        let queue = PriorityQueue<Int64>.create<Int64>()
        for (v in shuffled) {
            queue.add(v)
        }
        @Assert(array.size, queue.size)
        println(queue.toArray())
        var i = 0
        while (!queue.isEmpty()) {
            let val = queue.remove().getOrThrow()
            @Assert(array[i], val)
            i++
        }
    }

    @TestCase
    public func testPriorityQueueGrowSizePolicy(): Unit {
        let array = createArray(6)
        let shuffled = shuffleArray(array)
        let queue = PriorityQueue<Int64>.create<Int64>(
            capacity: 3,
            overSizePolicy: GrowSizePolicy<Int64, PriorityQueue<Int64>>()
        )
        for (v in shuffled) {
            queue.add(v)
        }
        @Assert(array.size, queue.size)
        var i = 0
        while (!queue.isEmpty()) {
            @Assert(array[i], queue.remove().getOrThrow())
            i++
        }
    }
    @TestCase
    public func testPriorityQueueRemoveIf(): Unit {
        let array = createArray(10)
        let shuffled = shuffleArray(array)
        let queue = PriorityQueue<Int64>.create<Int64>()
        for (v in shuffled) {
            queue.add(v)
        }
        queue.removeIf {v => v % 2 == 0}
        @Assert(queue.size, 5)
        var i = 0
        while (!queue.isEmpty()) {
            @Assert([1,3,5,7,9][i], queue.remove().getOrThrow())
            i++
        }
    }
    @TestCase
    public func testBitSet(): Unit {
        let bs = BitSet()
        bs[21324] = true
        @Assert(true, bs[21324])
        bs[21324] = false
        @Assert(false, bs[21324])
        var r = bs | 21324
        @Assert(true, bs[21324])
        @Assert(false, r)
        r = bs ^ 21324
        @Assert(true, r)
        @Assert(false, bs[21324])
        r = bs & 21324
        @Assert(false, r)
        @Assert(false, bs[21324])
    }
    @TestCase
    public func testContainsValue(): Unit {
        let map = HashMap<Int64, Int64>([(1, 1), (2, 2), (3, 3)])
        @Assert(true, map.containsValue(3))
    }

    // ================================================================
    // PriorityQueue 补充测试（PERF-1 二叉堆改造验证）
    // ================================================================

    @TestCase
    public func testPriorityQueueEmpty(): Unit {
        let queue = PriorityQueue<Int64>.create<Int64>()
        @Assert(queue.isEmpty())
        @Assert(queue.size == 0)
        @Assert(queue.peek().isNone())
        @Assert(queue.remove().isNone())
    }

    @TestCase
    public func testPriorityQueueSingleElement(): Unit {
        let queue = PriorityQueue<Int64>.create<Int64>()
        queue.add(42)
        @Assert(queue.size == 1)
        @Assert(!queue.isEmpty())
        @Assert(queue.peek().getOrThrow() == 42)
        @Assert(queue.size == 1)  // peek 不删除
        @Assert(queue.remove().getOrThrow() == 42)
        @Assert(queue.isEmpty())
        @Assert(queue.remove().isNone())
    }

    @TestCase
    public func testPriorityQueueCustomComparator(): Unit {
        // 逆序比较器（大根堆）
        let cmp = { a: Int64, b: Int64 =>
            if (a > b) { LT }
            else if (a < b) { GT }
            else { EQ }
        }
        let queue = PriorityQueue<Int64>(cmp)
        queue.add(3)
        queue.add(1)
        queue.add(2)
        @Assert(queue.remove().getOrThrow() == 3)
        @Assert(queue.remove().getOrThrow() == 2)
        @Assert(queue.remove().getOrThrow() == 1)
    }

    @TestCase
    public func testPriorityQueueDuplicates(): Unit {
        let queue = PriorityQueue<Int64>.create<Int64>()
        queue.add(5)
        queue.add(3)
        queue.add(5)
        queue.add(3)
        @Assert(queue.size == 4)
        // 两次 3 先出，两次 5 后出
        @Assert(queue.remove().getOrThrow() == 3)
        @Assert(queue.remove().getOrThrow() == 3)
        @Assert(queue.remove().getOrThrow() == 5)
        @Assert(queue.remove().getOrThrow() == 5)
    }

    @TestCase
    public func testPriorityQueuePeekNonDestructive(): Unit {
        let queue = PriorityQueue<Int64>.create<Int64>()
        queue.add(7)
        queue.add(3)
        queue.add(9)
        // peek 不应影响后续 remove 顺序
        @Assert(queue.peek().getOrThrow() == 3)
        @Assert(queue.peek().getOrThrow() == 3)
        @Assert(queue.remove().getOrThrow() == 3)
        @Assert(queue.peek().getOrThrow() == 7)
        @Assert(queue.remove().getOrThrow() == 7)
        @Assert(queue.peek().getOrThrow() == 9)
        @Assert(queue.remove().getOrThrow() == 9)
        @Assert(queue.peek().isNone())
    }

    @TestCase
    public func testPriorityQueueSequentialInsert(): Unit {
        // 顺序插入（不 shuffle），仍应保持正确顺序
        let queue = PriorityQueue<Int64>.create<Int64>()
        for (i in 1..=100) {
            queue.add(i)
        }
        @Assert(queue.size == 100)
        for (i in 1..=100) {
            @Assert(queue.remove().getOrThrow() == i)
        }
    }

    @TestCase
    public func testPriorityQueueStringComparator(): Unit {
        // 字符串比较器（用于 ByteArray 类似场景验证）
        let cmp = { a: String, b: String =>
            if (a < b) { LT }
            else if (a > b) { GT }
            else { EQ }
        }
        let queue = PriorityQueue<String>(cmp)
        queue.add("banana")
        queue.add("apple")
        queue.add("cherry")
        @Assert(queue.remove().getOrThrow() == "apple")
        @Assert(queue.remove().getOrThrow() == "banana")
        @Assert(queue.remove().getOrThrow() == "cherry")
    }
}
