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

/**
 * 只用来提供真实的函数元数据（`getInstanceFunction` 需要函数真实存在）。
 */
public class CaptureTarget {
    public func n(v: Int64): Int64 {
        v
    }
}

/** 「切面改造实参」用例的目标函数。 */
public class RewriteTarget {
    public func p(v: Int64): Int64 {
        v
    }
}

/**
 * 记录切面每次调用实际拿到的 `InvocationFuncInfo`（值、实参、元数据）。
 * 切面自身不读 args 做判断，无状态、不加锁。
 */
@AspectRoute[FuncNameRouteRule("n")]
public class ArgsIdentityAspect <: Aspect {
    public static let seenInfo = ArrayList<InvocationFuncInfo>()
    public static let argsOnSeen = ArrayList<Int64>()

    public init() {}

    public func before(funcInfo: InvocationFuncInfo): Unit {
        seenInfo.add(funcInfo)
        argsOnSeen.add((funcInfo.args[0] as Int64).getOrThrow())
    }
}

/**
 * 切面把实参改成 100 再继续（验证实参逐调用传递后 `point(args)` 的语义仍然保留）。
 */
@AspectRoute[FuncNameRouteRule("p")]
public class ArgsRewriteAspect <: Aspect {
    public init() {}

    public func around(funcInfo: InvocationFuncInfo, point: (Array<Any>) -> Any): Any {
        point([100])
    }
}

/**
 * 验证 `Aspects.doProceed` 的实参传递语义：链只在切点函数首次调用时按「(类型, 函数)」构建一次、
 * 链尾固化首次调用传入的 callee（设计说明见 `Aspects` 声明处），但**每层用本次调用的 `args`
 * 新建一个 `InvocationFuncInfo`** 交给切面——它是 `struct`（值类型、不可变），所以：
 *   - 每个调用（每层）拿到的都是各自的值，一次调用的实参不会被另一次调用改写（不存在可共享的参数槽）；
 *   - 实参与元数据（类型、函数名）都正确。
 * 修复前的行为见 `.autocode/bugs/bug.md` §1.4：层闭包用 `setArgs` 改写首次调用的那个对象，
 * 并发下参数互串（复现在 `aspect_args_race_test.cj`）。
 */
@Test
public class AspectPerCallInfo_test {
    @TestCase
    public func testPerCallInvocationFuncInfo(): Unit {
        BeanFactory.instance.register<ArgsIdentityAspect>({=> ArgsIdentityAspect()})

        let info1 = InvocationFuncInfo(TypeInfo.of<CaptureTarget>(), 'n', [TypeInfo.of<Int64>()], [1])
        let info2 = InvocationFuncInfo(TypeInfo.of<CaptureTarget>(), 'n', [TypeInfo.of<Int64>()], [2])

        let r1 = Aspects.proceed<Int64>(info1, {args: Array<Any> => (args[0] as Int64).getOrThrow()})
        let r2 = Aspects.proceed<Int64>(info2, {args: Array<Any> => (args[0] as Int64).getOrThrow()})
        println("第 1/2 次调用返回 ${r1}/${r2}")
        println("切面在两次调用里看到的实参：${ArgsIdentityAspect.argsOnSeen[0]}/${ArgsIdentityAspect.argsOnSeen[1]}")
        println(
            "切面在两次调用里看到的函数元数据：${ArgsIdentityAspect.seenInfo[1].typeInfo.qualifiedName}.${ArgsIdentityAspect.seenInfo[1].funcInfo.name}")

        // 单线程下参数正确
        @Assert(r1, 1)
        @Assert(r2, 2)
        // 各自带的实参与元数据都正确（struct 为值语义，每次调用各一份，不存在跨调用共享）
        @Assert(ArgsIdentityAspect.argsOnSeen[0], 1)
        @Assert(ArgsIdentityAspect.argsOnSeen[1], 2)
        @Assert((ArgsIdentityAspect.seenInfo[0].args[0] as Int64).getOrThrow(), 1)
        @Assert((ArgsIdentityAspect.seenInfo[1].args[0] as Int64).getOrThrow(), 2)
        @Assert(ArgsIdentityAspect.seenInfo[1].typeInfo, TypeInfo.of<CaptureTarget>())
        @Assert(ArgsIdentityAspect.seenInfo[1].funcInfo.name, 'n')
    }

    /**
     * 切面把改造过的实参传给 `point(...)` 时，链尾（业务方法体）必须收到改造后的值——
     * 这条语义在实参改为逐调用传递后必须保持不变。
     */
    @TestCase
    public func testAspectCanRewriteArgsPassedToPoint(): Unit {
        BeanFactory.instance.register<ArgsRewriteAspect>({=> ArgsRewriteAspect()})

        let info = InvocationFuncInfo(TypeInfo.of<RewriteTarget>(), 'p', [TypeInfo.of<Int64>()], [7])
        let r = Aspects.proceed<Int64>(info, {args: Array<Any> => (args[0] as Int64).getOrThrow()})
        println("切面把实参 7 改成 100，业务方法实收 ${r}")
        @Assert(r, 100)
    }
}
