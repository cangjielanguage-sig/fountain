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
package fountain::f_data.test

import fountain::f_data.*
import fountain::f_data.macros.DataAssist
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 显式声明 `Comparable<X> & Equatable<X>`：SDK 1.3.0-alpha（nightly 20261110 起 std 合入 local mode）
 * 里 `Comparable<T> <: Equatable<T>`，两个父接口同时列出会让 `Equatable<X>` 出现两条路径，
 * 编译器随即要求实现带 `@local!` 模态的 `!=`（普通模式写不出来）。
 * `@DataAssist` 必须把冗余的 `Equatable<X>` 归一化掉，同时保证类仍然实现这两个接口。
 */
@DataAssist[hash equal props fields tostring compare]
public class OrderedItem <: Comparable<OrderedItem> & Equatable<OrderedItem> {
    private var weight: Int64 = 0
    private var name: String = ''
}

/**
 * 显式声明与宏生成重复的父接口（`Hashable` / `ToString` / `Equatable<X>`），
 * 展开后必须去重，否则报 `duplicate interface`。
 */
@DataAssist[hash equal props fields tostring]
public class DupDeclared <: Hashable & ToString & Equatable<DupDeclared> {
    private var id: Int64 = 0
}

@Test
public class DataAssistSuperTypesTest {
    @TestCase
    public func testExplicitComparableAndEquatable(): Unit {
        let a = OrderedItem()
        let b = OrderedItem()
        @Assert(a is Comparable<OrderedItem>)
        @Assert(a is Equatable<OrderedItem>)
        @Assert(a == b)
        @Assert(!(a != b))
        @Assert(a.compare(b) == Ordering.EQ)
        a.weight = 2
        @Assert(a.compare(b) == Ordering.GT)
        @Assert(b.compare(a) == Ordering.LT)
        // 首个字段相等时由后续字段决定（逐字段短路，而不是只看第一个字段）
        let c = OrderedItem()
        c.weight = 2
        c.name = 'a'
        a.name = 'z'
        @Assert(a.compare(c) == Ordering.GT)
        @Assert(c.compare(a) == Ordering.LT)
        @Assert(!(a == b))
        @Assert(a != b)
    }

    @TestCase
    public func testDuplicateExplicitDeclIsDeduped(): Unit {
        let a = DupDeclared()
        let b = DupDeclared()
        @Assert(a is Hashable)
        @Assert(a is ToString)
        @Assert(a is Equatable<DupDeclared>)
        @Assert(a.hashCode() == b.hashCode())
        @Assert(a.toString() == b.toString())
        a.id = 7
        @Assert(!(a == b))
    }
}
