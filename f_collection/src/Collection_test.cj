/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package fountain.collection

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
            map.put(i, i)
        }
        map
    }
    private func createLinkedMap(): Map<Int64, Int64> {
        let map = LinkedMap<Int64, Int64>()
        createMap(map, array)
    }
    private func createHashMap(array: Array<Int64>): Map<Int64, Int64> {
        let map = HashMap<Int64, Int64>()
        for (i in array) {
            map.put(i, i)
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
    public func testLinkedMap1(): Unit {
        let map = createLinkedMap()
        testSeqMap(map)
        let rand = Random()
        let list = ArrayList<Int64>(array)
        for (i in array) {
            let r = rand.nextInt64(array.size)
            let v = list.remove(r)
            list.append(v)
            map.remove(v)
            map.put(v, v)
        }
        @Assert(map.size, list.size)
        var i = 0
        for ((k, v) in map) {
            @Assert(k, list[i])
            i++
        }
    }
    @TestCase
    public func testLinkedMap2(): Unit {
        let map = LinkedMap<Int64, Int64>()
        map.put(1, 1)
        map.put(2, 2)
        map.put(3, 3)
        map.put(2, 2)
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
    public func testLinkedMap3(): Unit {
        let map = LinkedMap<Int64, Int64>(3, true)
        map.put(1, 1)
        map.put(2, 2)
        map.put(3, 3)
        map.put(4, 4)
        let arr = [2, 3, 4]
        @Assert(arr.size, map.size)
        var i = 0
        for ((k, v) in map) {
            @Assert(k, arr[i])
            i++
        }
    }
    @TestCase
    public func testLinkedMap4(): Unit {
        let map = LinkedMap<Int64, Int64>(3, true)
        map.put(1, 1)
        map.put(2, 2)
        map.put(3, 3)
        map.put(2, 2)
        let arr = [1, 3, 2]
        @Assert(arr.size, map.size)
        var i = 0
        for ((k, v) in map) {
            @Assert(k, arr[i])
            i++
        }
    }
    @TestCase
    public func testPriorityQueueGrowable(): Unit {
        let array = createArray(32)
        let shuffled = shuffleArray(array)
        let queue = PriorityQueue<Int64>.create<Int64>()
        for (v in shuffled) {
            queue.offer(v)
        }
        @Assert(array.size, queue.size)
        println(queue.toArray())
        var i = 0
        while (!queue.isEmpty()) {
            let val = queue.poll().getOrThrow()
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
            queue.offer(v)
        }
        @Assert(array.size, queue.size)
        var i = 0
        while (!queue.isEmpty()) {
            @Assert(array[i], queue.poll().getOrThrow())
            i++
        }
    }
    @TestCase
    public func testPriorityQueueRemoveIf(): Unit {
        let array = createArray(10)
        let shuffled = shuffleArray(array)
        let queue = PriorityQueue<Int64>.create<Int64>()
        for (v in shuffled) {
            queue.offer(v)
        }
        queue.removeIf {v => v % 2 == 0}
        @Assert(queue.size, 5)
        var i = 0
        while (!queue.isEmpty()) {
            @Assert([1,3,5,7,9][i], queue.poll().getOrThrow())
            i++
        }
    }
}
