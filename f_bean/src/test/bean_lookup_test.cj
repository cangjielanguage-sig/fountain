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
 * `lookup*` 集合/映射族的语义钉住用例。
 *
 * - §3.1 / `BEAN-L5`：`lookupHashSet` / `lookupTreeSet` 改为直接向目标集合填充后，
 *   元素集合、`TreeSet` 有序性、`cond` 透传与空结果必须与 `lookupList` 口径一致。
 * - §3.1 / `BEAN-L10`：`getList` / `getMap` 去掉 per-element `put` 闭包后，
 *   `lookupList` 的**元素集合与顺序**、`lookupHashMap` 的**名称键→bean 映射**、
 *   `cond` 透传、空结果必须一字不变。
 *
 * 本文件自带一组同类型 bean（12 个实现同一接口）：`HashSet`/`TreeSet` 版本分别要求
 * `T <: Hashable & Equatable<T>` 与 `T <: Comparable<T>`，故接口同时带上这三者。
 * `order` 取得与 `code` 相同 ⇒ 同类型 bean 的排序即 `code` 升序（顺序语义可断言）。
 */
public interface LookupSetItem <: Hashable & Comparable<LookupSetItem> {
    prop code: Int64
}

@Bean
@BeanMeta[order: 1]
public class LookupItem01 <: LookupSetItem {
    public prop code: Int64 {
        get() { 1 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 2]
public class LookupItem02 <: LookupSetItem {
    public prop code: Int64 {
        get() { 2 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 3]
public class LookupItem03 <: LookupSetItem {
    public prop code: Int64 {
        get() { 3 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 4]
public class LookupItem04 <: LookupSetItem {
    public prop code: Int64 {
        get() { 4 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 5]
public class LookupItem05 <: LookupSetItem {
    public prop code: Int64 {
        get() { 5 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 6]
public class LookupItem06 <: LookupSetItem {
    public prop code: Int64 {
        get() { 6 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 7]
public class LookupItem07 <: LookupSetItem {
    public prop code: Int64 {
        get() { 7 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 8]
public class LookupItem08 <: LookupSetItem {
    public prop code: Int64 {
        get() { 8 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 9]
public class LookupItem09 <: LookupSetItem {
    public prop code: Int64 {
        get() { 9 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 10]
public class LookupItem10 <: LookupSetItem {
    public prop code: Int64 {
        get() { 10 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 11]
public class LookupItem11 <: LookupSetItem {
    public prop code: Int64 {
        get() { 11 }
    }
    public func hashCode(): Int64 { code }
    public func compare(that: LookupSetItem): Ordering { code.compare(that.code) }
}

@Bean
@BeanMeta[order: 12]
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

/**
 * §3.1 / `BEAN-L10`：`getList`/`getMap` 的收集语义（去掉 `getAll` 的 `put` 闭包前后必须一致）。
 */
@Test
public class BeanCollectLookup_test {
    @TestCase
    public func testListElementsAndOrder(): Unit {
        let list = lookupList<LookupSetItem>()
        @Assert(list.size, 12)
        // 顺序 = 同类型 bean 的排序（primary 优先、再 order 升序）⇒ 本组样本 order == code ⇒ code 升序
        for (i in 0..list.size) {
            @Assert(list[i].code, i + 1)
        }
        // 稳定性：连续两次调用的顺序一致
        let again = lookupList<LookupSetItem>()
        @Assert(again.size, list.size)
        for (i in 0..list.size) {
            @Assert(again[i].code, list[i].code)
        }
    }

    @TestCase
    public func testMapNamesToBeans(): Unit {
        let map = lookupHashMap<LookupSetItem>()
        @Assert(map.size, 12)
        var seen: Int64 = 0
        for ((name, bean) in map) {
            // 键是 bean 名称：能按名字查回同一个 bean
            @Assert(name.size > 0, true)
            let found = lookupOption<LookupSetItem>(Exactly(name))
            if (let Some(f) <- found) {
                @Assert(f.code, bean.code)
            } else {
                @Assert(false, true)
            }
            seen += bean.code
        }
        // 12 个 code 各一次 ⇒ 和为 78
        @Assert(seen, 78)
    }

    @TestCase
    public func testCollectCondAndEmptySemantics(): Unit {
        let all = Wildcard('fountain::f_bean.test.*')
        @Assert(lookupList<LookupSetItem>(all).size, 12)
        @Assert(lookupHashMap<LookupSetItem>(all).size, 12)
        let none = Exactly('no.such.bean')
        @Assert(lookupList<LookupSetItem>(none).size, 0)
        @Assert(lookupHashMap<LookupSetItem>(none).size, 0)
    }
}
