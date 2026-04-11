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

        @Assert(map.size() == 3)
        @Assert(map.get(1) == Option.Some("one"))
        @Assert(map.containsKey(2))

        // 更新测试
        let old = map.add(2, "TWO")
        @Assert(old == Option.Some("two"))
        @Assert(map.get(2) == Option.Some("TWO"))

        // 删除测试
        let removed = map.remove(3)
        @Assert(removed == Option.Some("three"))
        @Assert(map.size() == 2)
        @Assert(map.get(3).isNone())

        // ConcurrentMap 接口测试
        @Assert(map.addIfAbsent(4, "four").isNone())
        @Assert(map.addIfAbsent(4, "FOUR") == Option.Some("four"))

        @Assert(map.replace(1, "ONE"))
        @Assert(map.get(1) == Option.Some("ONE"))
    }

    @TestCase
    func testConcurrentSkipListMapConcurrent(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = ArrayList<Future<Unit>>()

        // 并发写入
        for (i in 0..100) {
            let fut = spawn {
                for (j in 0..100) {
                    map.add(i * 100 + j, j)
                }
            }
            threads.append(fut)
        }

        for (fut in threads) {
            fut.get()
        }

        @Assert(map.size() == 10000)
    }
}
