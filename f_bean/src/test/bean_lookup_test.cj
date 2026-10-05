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
package fountain::f_bean.test

import std.unittest.*
import std.unittest.testmacro.*
public import fountain::f_bean.*
import fountain::f_bean.macros.*

/**
 * §3.1 / `BEAN-L5` 的用例：`lookupHashSet` / `lookupTreeSet` 改为**直接向目标集合填充**
 * （不再先物化中间 `ArrayList`）后，元素集合、`TreeSet` 的有序性、`cond` 透传与空结果语义
 * 必须与 `lookupList` 口径一致。
 *
 * 本文件自带一组同类型 bean（12 个实现同一接口）——`HashSet`/`TreeSet` 版本分别要求
 * `T <: Hashable & Equatable<T>` 与 `T <: Comparable<T>`，故接口同时带上这三者。
 */
public interface LookupSetItem <: Hashable & Comparable<LookupSetItem> {
    prop code: Int64
}

@Bean
public class LookupItem01 <: LookupSetItem {
    public prop code: Int64 {
        get() { 1 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem02 <: LookupSetItem {
    public prop code: Int64 {
        get() { 2 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem03 <: LookupSetItem {
    public prop code: Int64 {
        get() { 3 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem04 <: LookupSetItem {
    public prop code: Int64 {
        get() { 4 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem05 <: LookupSetItem {
    public prop code: Int64 {
        get() { 5 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem06 <: LookupSetItem {
    public prop code: Int64 {
        get() { 6 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem07 <: LookupSetItem {
    public prop code: Int64 {
        get() { 7 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem08 <: LookupSetItem {
    public prop code: Int64 {
        get() { 8 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem09 <: LookupSetItem {
    public prop code: Int64 {
        get() { 9 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem10 <: LookupSetItem {
    public prop code: Int64 {
        get() { 10 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem11 <: LookupSetItem {
    public prop code: Int64 {
        get() { 11 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
public class LookupItem12 <: LookupSetItem {
    public prop code: Int64 {
        get() { 12 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Test
public class BeanSetLookup_test {
    @TestCase
    public func testHashSetAndTreeSetEquivalence(): Unit {
        let list = lookupList<LookupSetItem>()
        @Assert(list.size, 12)
        // HashSet：个数一致，且列表里每个元素都在集合中
        let set = lookupHashSet<LookupSetItem>()
        @Assert(set.size, 12)
        for (item in list) {
            @Assert(set.contains(item), true)
        }
        // TreeSet：个数一致 + 按 Comparable 严格升序
        let tree = lookupTreeSet<LookupSetItem>()
        @Assert(tree.size, 12)
        var prev: Int64 = 0
        var cnt: Int64 = 0
        for (item in tree) {
            @Assert(item.code > prev, true)
            prev = item.code
            cnt += 1
        }
        @Assert(cnt, 12)
    }

    @TestCase
    public func testCondAndEmptySemantics(): Unit {
        let all = Wildcard('fountain::f_bean.test.*')
        @Assert(lookupHashSet<LookupSetItem>(all).size, 12)
        @Assert(lookupTreeSet<LookupSetItem>(all).size, 12)
        let none = Exactly('no.such.bean')
        @Assert(lookupHashSet<LookupSetItem>(none).size, 0)
        @Assert(lookupTreeSet<LookupSetItem>(none).size, 0)
        @Assert(lookupList<LookupSetItem>(none).size, 0)
    }
}
