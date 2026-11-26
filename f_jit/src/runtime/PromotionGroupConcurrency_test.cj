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

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 提升组引用计数的**跨线程释放**验收（`feat-f-jit-parallel-call` P4.2）。
 *
 * 场景：同一包装的捕获被多个线程共享，释放动作也可能来自不同线程。计数 −1 必须在锁内
 * 完成，否则两个线程都读到 2、各自写回 1 ⇒ 槽永不释放（泄漏）。
 */
@Test
public class PromotionGroupConcurrency_test {

    /**
     * 单个热槽 × 8000 引用，4 线程各释放 2000 次：计数精确归零、槽被回收。
     *
     * 用「同一槽反复 −1」而不是「多槽各 −1 一次」：后者每次的竞态窗口只有一条指令，
     * 丢更新概率太低；前者把竞态窗口重复 8000 次，丢一次就会留下正计数。
     */
    @TestCase
    public func concurrentReleasesDropRefcountExactly(): Unit {
        HandleTable.resetForTest()
        let base = HandleTable.liveCount()
        let id = HandleTable.pin('pg-hot')
        let g = PromotionGroup()
        let per = 2000
        let threads = 4
        var i = 0
        while (i < per * threads) {
            g.add(id)
            i = i + 1
        }
        @Assert(g.size(), 1)
        let futures = ArrayList<Future<Int64>>()
        var t = 0
        while (t < threads) {
            futures.add(spawn {
                var k = 0
                while (k < per) {
                    g.release(id)
                    k = k + 1
                }
                0
            })
            t = t + 1
        }
        for (f in futures) {
            @Assert(f.get(), 0)
        }
        @Assert(g.size(), 0)
        @Assert(HandleTable.isLiveHandle(id), false)
        @Assert(HandleTable.liveCount(), base)
    }
}
