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
package fountain::f_egraph.base

import std.collection.*
import std.fs.{File, OpenMode}
import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_collection.*
import fountain::f_concurrent.*

/**
 * 优先级队列实现对比（N = 20000，确定性伪随机优先级）。
 *
 * 覆盖：有序 ArrayList、f_collection.PriorityQueue、f_concurrent.SyncPriorityQueue。
 * `LinkedNode` 未纳入：其公开接口只暴露 head/tail 插入，没有节点级 `next`，
 * 做有序插入只能每次从头遍历重建，不是等价比较（见回复说明）。
 */
@Test
class PriorityQueueBench_test {
    private static let N: Int64 = 20000

    private static func valueOf(i: Int64): Int64 {
        (i * 7919 + 13) % 100000
    }

    private static func millis(): Int64 {
        DateTime.now().toUnixTimeStamp().toMilliseconds()
    }

    private static func dump(name: String, ms: Int64): Unit {
        let file = File('/tmp/pq-bench-${name}.txt', OpenMode.Write)
        file.write(ms.toString().toArray())
        file.close()
        ()
    }

    @TestCase
    func testSortedArrayList(): Unit {
        let start = millis()
        let list = ArrayList<Int64>()
        for(i in 0..N){
            let value = valueOf(i)
            var low: Int64 = 0
            var high: Int64 = Int64(list.size)
            while(low < high){
                let mid = (low + high) / 2
                if(list[mid] < value){
                    low = mid + 1
                }else{
                    high = mid
                }
            }
            // ArrayList 没有 insert：先追加，再从尾部逐个后移，语义与插入一致
            list.add(value)
            var cursor = Int64(list.size) - 1
            while(cursor > low){
                list[cursor] = list[cursor - 1]
                cursor--
            }
            list[low] = value
        }
        while(!list.isEmpty()){
            list.remove(at: 0)
        }
        dump('arraylist', millis() - start)
        @Expect(list.size, 0)
    }

    @TestCase
    func testPriorityQueue(): Unit {
        let start = millis()
        let queue = PriorityQueue<Int64>({ a, b => a.compare(b) })
        for(i in 0..N){
            queue.add(valueOf(i))
        }
        while(!queue.isEmpty()){
            queue.remove()
        }
        dump('priorityqueue', millis() - start)
        @Expect(queue.size, 0)
    }

    @TestCase
    func testSyncPriorityQueue(): Unit {
        let start = millis()
        let queue = SyncPriorityQueue<Int64>({ a, b => a.compare(b) })
        for(i in 0..N){
            queue.add(valueOf(i))
        }
        while(!queue.isEmpty()){
            queue.remove()
        }
        dump('syncpriorityqueue', millis() - start)
        @Expect(queue.size, 0)
    }
}
