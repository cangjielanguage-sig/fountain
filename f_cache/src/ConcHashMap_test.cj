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

    @TestCase
    public func testSizeAccountingIterationAndRemoval(): Unit {
        let map = ConcHashMap<Int64>.create(concurrencyLevel: 4)
        //新增：记账 size；覆盖同键：返回旧值、size 不重复计
        @Assert(true, map.add('a', 1).isNone())
        @Assert(1, map.size)
        if (let Some(old) <- map.add('a', 2)) {
            @Assert(1, old)
        } else {
            @Assert(false)
        }
        @Assert(1, map.size)
        //computeIfAbsent：缺失才计算并记账，命中直接返回旧值
        @Assert(3, map.computeIfAbsent('b') {3})
        @Assert(3, map.computeIfAbsent('b') {99})
        @Assert(2, map.size)
        //get / contains / containsAll（后者要求全部命中）
        @Assert(2, map.get('a') ?? -1)
        @Assert(true, map.contains('b'))
        @Assert(true, map.containsAll(['a', 'b']))
        @Assert(false, map.containsAll(['a', 'missing']))
        //迭代能取到全部条目
        var seen = 0
        for (_ in map) {
            seen++
        }
        @Assert(2, seen)
        //remove 记账、removeIf 批量删、clear 归零
        @Assert(2, map.remove('a') ?? -1)
        @Assert(1, map.size)
        map.removeIf {_, v => v == 3}
        @Assert(0, map.size)
        @Assert(true, map.isEmpty())
        @Assert(false, map.contains('b'))
    }
}
