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
package fountain::f_cache

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ConcHashMap_test {
    @TestCase
    public func testKeysContainsAllRequiresEveryElement(): Unit {
        let map = ConcHashMap<Int64>.create(concurrencyLevel: 4)
        map.add('a', 1)
        map.add('b', 2)
        let keys = ConcHashMapKeys<Int64>(map)
        //单键判断照旧
        @Assert(true, keys.contains('a'))
        @Assert(false, keys.contains('missing'))
        //std 语义：contains(all:) 要求「全部命中」才为 true（原实现是「任一命中」即 true）
        @Assert(true, keys.contains(all: ['a', 'b']))
        @Assert(false, keys.contains(all: ['a', 'missing']))
        @Assert(false, keys.contains(all: ['missing1', 'missing2']))
        //空集合按 std 的「全部命中」语义为 true（vacuous truth）
        @Assert(true, keys.contains(all: ArrayList<String>()))
        //size / isEmpty 透传 map
        @Assert(2, keys.size)
        @Assert(false, keys.isEmpty())
    }
}
