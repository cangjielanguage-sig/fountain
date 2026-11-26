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
package fountain::f_jit.runtime

import std.sync.AtomicInt64
import std.sync.*
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 空闲槽分片（`optimize-call-path-phase2`）的并发护栏。
 *
 * 4 线程各自开窗/分配/释放/收窗：分片后同一槽的分配与释放必须仍然互斥，
 * 不能出现「两个线程同时拿到同一个索引」或「释放误伤别人刚分配的槽」。
 */
@Test
public class HandleTableStripeConcurrency_test {
    @TestCase
    public func concurrentPinReleaseKeepsAccounting(): Unit {
        HandleTable.resetForTest()
        let baseLive = HandleTable.liveCount()
        let baseSlots = HandleTable.slotCount()
        let n = Int64(20000)
        let bad = AtomicInt64(0)
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < 4) {
            fs.add(spawn {
                var k = 0
                while (k < n) {
                    HandleTable.openWindow(4)
                    let id = HandleTable.pin('stripe-probe')
                    if (id <= 0 || !HandleTable.isLiveHandle(id) ||
                        HandleTable.getAny(id).isNone()) {
                        let _ = bad.fetchAdd(1)
                    }
                    HandleTable.release(id)
                    HandleTable.resetWindow(-1)
                    k = k + 1
                }
                n
            })
            t = t + 1
        }
        for (f in fs) {
            @Assert(f.get(), n)
        }
        @Assert(bad.load(), 0)
        @Assert(HandleTable.liveCount(), baseLive)
        // 高水位只应因世代号退休与分片尾部而小幅增长，不允许按线程数线性膨胀。
        @Assert(HandleTable.slotCount() - baseSlots <= 4 * 64, true)
    }
}
