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
package fountain::f_jit.backend

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * `NativeAssets` 计数在并发下的精确性（H2）。
 *
 * 旧实现的 `allocs` / `frees` 是普通 `Int64` 自增：4 线程并发分配时增量会互相覆盖，
 * `liveCount()` 低于真实值。本用例用「4×100 次分配，逐个保留」把增量差异放大到
 * 必现（断言精确等于 400）；旧实现上必须**红**。
 */
@Test
public class NativeAssetsConcurrency_test {
    @TestCase
    public func concurrentAllocCountIsExact(): Unit {
        NativeAssets.resetCounters()
        let per = Int64(100)
        let threads = Int64(4)
        let tables = ArrayList<FnTable>()
        let mtx = Mutex()
        let fs = ArrayList<Future<Int64>>()
        var t = 0
        while (t < threads) {
            fs.add(spawn {
                var k = 0
                while (k < per) {
                    match (FnTable.alloc(1)) {
                        case Some(x) =>
                            synchronized(mtx) {
                                tables.add(x)
                            }
                        case None => ()
                    }
                    k = k + 1
                }
                per
            })
            t = t + 1
        }
        var ok = 0
        for (x in fs) {
            ok = ok + x.get()
        }
        @Assert(ok, threads * per)
        @Assert(tables.size, threads * per)
        // 精确值断言：非原子实现在这里会低于 400。
        @Assert(NativeAssets.liveCount(), threads * per)
        for (x in tables) {
            x.free()
        }
        @Assert(NativeAssets.liveCount(), 0)
    }
}
