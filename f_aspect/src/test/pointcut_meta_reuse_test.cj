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
import fountain::f_base.*
import fountain::f_aspect.*
import fountain::f_aspect.macros.*
import fountain::f_bean.BeanFactory

/** ASP-3 用：被织入的目标类（类级 `@WeavedBean` ⇒ 走 `pointcut(ClassDecl)` 路径） */
@WeavedBean
public class MetaReuseTarget {
    public func m(v: Int64): Int64 {
        v
    }
}

/** 记录每次调用实际拿到的函数元数据（不读 args、无状态、不加锁） */
@AspectRoute[FuncNameRouteRule("m")]
public class MetaIdentityAspect <: Aspect {
    public static let metas = ArrayList<QualifiedFuncInfo>()
    public init() {}
    public func before(funcInfo: InvocationFuncInfo): Unit {
        metas.add(funcInfo.qualifiedFuncInfo)
    }
}

/**
 * `ASP-3`（§1.14）观测：函数元信息（`QualifiedFuncInfo`，含反射解析与哈希）应**只实例化一次并被复用**，
 * 而不是每次调用重建（现状是宏在每个函数体里 `InvocationFuncInfo(TypeInfo.of(this), name, argTypes, args)`）。
 * 判定方式：切面每次调用拿到的 `qualifiedFuncInfo` 必须是**同一个对象**（`refEq`）。
 */
@Test
public class PointcutMetaReuse_test {
    @TestCase
    public func testMetadataInstantiatedOnce(): Unit {
        BeanFactory.instance.register<MetaIdentityAspect>({=> MetaIdentityAspect()})
        let bean = MetaReuseTarget()
        let r1 = bean.m(1)
        let r2 = bean.m(2)
        @Assert(r1, 1)
        @Assert(r2, 2)
        @Assert(MetaIdentityAspect.metas.size >= 2, true)
        @Assert(refEq(MetaIdentityAspect.metas[0], MetaIdentityAspect.metas[1]), true)
    }
}
