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
package fountain::f_data.path

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.base.*

/**
 * 覆盖 2026-10-15 修复的切片归一化与集合 null 判定（详见 doc/REVIEW_2026-10-15.md）：
 * - 负值越界切片此前被归一化两次，`$[-7:]`（len=5）只返回后 2 个元素
 * - `containsNull` 此前用子串判断，`in ['nullable']` 会被当作含 null
 */
@Test
public class DataPath_slice_test {
    private func collect(itr: Iterator<Data>): ArrayList<Data> {
        let list = ArrayList<Data>()
        for (d in itr) {
            list.add(d)
        }
        list
    }

    private func makeList(): DataList {
        let list = DataList()
        for (i in 0..5) {
            list.add(DataReal(i))
        }
        list
    }

    @TestCase
    public func testNegativeStartBeyondLengthClampsToZero(): Unit {
        // RFC 9535 §2.3.4.2.2：len=5 时 [-7:] 等价于 [0:5]，应为全部 5 个元素
        let d: Data = makeList()
        @Assert(5, collect(DataPath.cache("$[-7:]").get(d)).size)
    }

    @TestCase
    public func testNegativeEndBeyondLengthIsEmpty(): Unit {
        // len=5 时 [:-7] 等价于 [0:0]，应为空（修复前返回前 3 个元素）
        let d: Data = makeList()
        @Assert(0, collect(DataPath.cache("$[:-7]").get(d)).size)
    }

    @TestCase
    public func testInRangeSlicesUnchanged(): Unit {
        let d: Data = makeList()
        @Assert(2, collect(DataPath.cache("$[-2:]").get(d)).size)
        @Assert(3, collect(DataPath.cache("$[:3]").get(d)).size)
        @Assert(5, collect(DataPath.cache("$[::-1]").get(d)).size)
        @Assert(0, collect(DataPath.cache("$[7:]").get(d)).size)
        @Assert(2, collect(DataPath.cache("$[3:1:-1]").get(d)).size)
    }

    @TestCase
    public func testContainsNullIsLexical(): Unit {
        let list = DataList()
        list.add(DataNone.INSTANCE)
        list.add(DataString('x'))
        let d: Data = list
        // 集合里含 `nullable` 这类词时，修复前的子串判断会把整个集合当成含 null，DataNone 被误命中
        @Assert(0, collect(DataPath.cache("$[?(@ in ['nullable', 'y'])]").get(d)).size)
        // `[null]` 仍然命中 null 元素
        @Assert(1, collect(DataPath.cache("$[?(@ in [null])]").get(d)).size)
    }

    @TestCase
    public func testSetStartingWithQuotedString(): Unit {
        let list = DataList()
        list.add(DataString('nullable'))
        list.add(DataString('y'))
        let d: Data = list
        // 修复前：集合文本以引号开头时，arg() 会剥掉它的外层引号（`'nullable', 'y'` → `nullable', 'y`），
        // 编译期直接抛 `illegal token for set filter`；单元素集合 `['nullable']` 更是完全不可用
        @Assert(2, collect(DataPath.cache("$[?(@ in ['nullable', 'y'])]").get(d)).size)
        @Assert(1, collect(DataPath.cache("$[?(@ in ['nullable'])]").get(d)).size)
        @Assert(1, collect(DataPath.cache("$[?(@ nin ['nullable'])]").get(d)).size)
    }
}
