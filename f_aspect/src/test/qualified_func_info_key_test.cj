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
package fountain::f_aspect.test

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.reflect.*
import fountain::f_base.*
import fountain::f_aspect.*

/** 键稳定性用例的探针类型 */
public class KeyProbeBean {
    public func probe(x: Int64): Int64 {
        x
    }
}

/**
 * ASP-L8（`bug-aspect.md` §3.2）前提验证：切面链缓存的键 `QualifiedFuncInfo` 是否**按值稳定**。
 * 键 = (`TypeInfo`, `InstanceFunctionInfo`)，且每次构造都会经
 * `typeInfo.getInstanceFunction(funcName, argTypes)` **重新解析**成员（`QualifiedFuncInfo.cj:68-74`）。
 * 只有「每次都是新对象 **且** `hashCode` 是对象身份哈希」才会让缓存永不命中、`aspects` 无界增长。
 */
@Test
public class QualifiedFuncInfoKey_test {
    @TestCase
    public func testTypeInfoStableAcrossLookups(): Unit {
        let t1 = TypeInfo.of<KeyProbeBean>()
        let t2 = TypeInfo.of<KeyProbeBean>()
        @Assert(t1 == t2, true)
        @Assert(t1.hashCode() == t2.hashCode(), true)
    }

    @TestCase
    public func testMemberInfoStableAcrossResolutions(): Unit {
        let t1 = TypeInfo.of<KeyProbeBean>()
        let t2 = TypeInfo.of<KeyProbeBean>()
        let f1 = t1.getInstanceFunction('probe', [TypeInfo.of<Int64>()])
        let f2 = t2.getInstanceFunction('probe', [TypeInfo.of<Int64>()])
        @Assert(f1 == f2, true)
        @Assert(f1.hashCode() == f2.hashCode(), true)
    }

    @TestCase
    public func testQualifiedFuncInfoKeyHashStable(): Unit {
        // 复现宏生成的键构造（PointCut.cj:115 → InvocationFuncInfo.init → QualifiedFuncInfo.init）
        let k1 = QualifiedFuncInfo(TypeInfo.of<KeyProbeBean>(), 'probe', [TypeInfo.of<Int64>()])
        let k2 = QualifiedFuncInfo(TypeInfo.of<KeyProbeBean>(), 'probe', [TypeInfo.of<Int64>()])
        @Assert(k1 == k2, true)
        @Assert(k1.hashCode() == k2.hashCode(), true)
    }

    @TestCase
    public func testKeyUsedAsMapKeyHitsAcrossCalls(): Unit {
        // 直接复现 Aspects 的用法：分别构造的键要能命中同一个条目
        let m = HashMap<QualifiedFuncInfo, Int64>()
        m.add(QualifiedFuncInfo(TypeInfo.of<KeyProbeBean>(), 'probe', [TypeInfo.of<Int64>()]), 1)
        let hit = m.get(QualifiedFuncInfo(TypeInfo.of<KeyProbeBean>(), 'probe', [TypeInfo.of<Int64>()]))
        @Assert(hit.isSome(), true)
        @Assert(m.size, 1)
    }
}
