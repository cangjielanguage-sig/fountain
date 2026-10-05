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
import fountain::f_bean.BeanFactory

/** 观测用异常（用消息区分 A/B） */
public class L5ErrA <: BaseException {
    public init() {
        super('A')
    }
}

public class L5ErrB <: BaseException {
    public init() {
        super('B')
    }
}

/** 只用来提供真实的函数元数据（`getInstanceFunction` 需要函数真实存在） */
public class TemplateTarget {
    public func t(v: Int64): Int64 {
        v
    }
    public func u(v: Int64): Int64 {
        v
    }
}

/** `before` 抛 A、`final` 抛 B（都用默认 `Aspect.proceed` 模板） */
@AspectRoute[FuncNameRouteRule("t")]
public class SuppressBothAspect <: Aspect {
    public init() {}
    public func before(funcInfo: InvocationFuncInfo): Unit {
        throw L5ErrA()
    }
    public func final(funcInfo: InvocationFuncInfo): Unit {
        throw L5ErrB()
    }
}

/** 只有 `final` 抛 B */
@AspectRoute[FuncNameRouteRule("u")]
public class SuppressFinalAspect <: Aspect {
    public init() {}
    public func final(funcInfo: InvocationFuncInfo): Unit {
        throw L5ErrB()
    }
}

/**
 * `ASP-L5`（§3.1）默认模板的异常语义：**不丢弃任何一个异常** ——
 * `final` 抛异常时把它作为主异常、把之前的失败挂在 `suppressed` 上（见 `BaseException`）。
 * 修复前 `finally` 直接抛 `final` 的异常，前面的失败被覆盖（本用例 RED）。
 */
@Test
public class AspectTemplateSuppress_test {
    @TestCase
    public func testBothFailuresAreKept(): Unit {
        BeanFactory.instance.register<SuppressBothAspect>({=> SuppressBothAspect()})
        let info = InvocationFuncInfo(TypeInfo.of<TemplateTarget>(), 't', [TypeInfo.of<Int64>()], [1])
        var caught = None<Exception>
        try {
            Aspects.proceed<Int64>(info, {args: Array<Any> => (args[0] as Int64).getOrThrow()})
        } catch (e: Exception) {
            caught = e
        }
        @Assert(caught.isSome(), true)
        let e = caught.getOrThrow()
        let be = (e as BaseException).getOrThrow()
        println('主异常：${e}; 抑制异常数：${be.suppressed.size}')
        @Assert(be.suppressed.size, 1) // 两个异常都不丢
        @Assert(be.causedBy.getOrThrow().toString().contains('B'), true) // 主异常包裹的是 final 的 B（用户设计）
        @Assert(be.suppressed[0].toString().contains('A'), true)
    }

    @TestCase
    public func testOnlyFinalFailureIsThrown(): Unit {
        BeanFactory.instance.register<SuppressFinalAspect>({=> SuppressFinalAspect()})
        let info = InvocationFuncInfo(TypeInfo.of<TemplateTarget>(), 'u', [TypeInfo.of<Int64>()], [1])
        var caught = None<Exception>
        try {
            Aspects.proceed<Int64>(info, {args: Array<Any> => (args[0] as Int64).getOrThrow()})
        } catch (e: Exception) {
            caught = e
        }
        @Assert(caught.isSome(), true)
        let e = caught.getOrThrow()
        @Assert(e.toString().contains('B'), true)
        @Assert((e as BaseException).getOrThrow().suppressed.isEmpty(), true)
    }
}
