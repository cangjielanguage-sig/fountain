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

/**
 * 机制验证用切面：**不读 args 做业务判断**，只记录
 * ①本次调用收到的 `funcInfo` 是否与首次调用传入的 info 是同一实例（`refEq`）；
 * ②从这个（共享）对象上读到的实参值。
 */
@AspectRoute[FuncNameRouteRule("n")]
public class ArgsIdentityAspect <: Aspect {
    public static let firstCallInfo = ArrayList<InvocationFuncInfo>()
    public static let sameAsFirst = ArrayList<Bool>()
    public static let argsOnCapturedInfo = ArrayList<Int64>()

    public init() {}

    public func before(funcInfo: InvocationFuncInfo): Unit {
        sameAsFirst.add(refEq(funcInfo, firstCallInfo[0]))
        argsOnCapturedInfo.add((funcInfo.args[0] as Int64).getOrThrow())
    }
}

/**
 * 验证「`Aspects.doProceed` 在首次调用时构建闭包链，并把**首次调用的** `InvocationFuncInfo`
 * （含其可变的 `_args`）捕获进闭包」这一说法 —— 对应 `Aspects.cj:36-56` 的 `computeIfAbsent`
 * 闭包，闭包内 `setArgs`/`proceed` 用的 `funcInfo` 恒为首次调用捕获的那个（下称 info₀）。
 *
 * 证据链（全部单线程，不涉及并发交错）：
 *   - 第 1 次调用：切面收到的 funcInfo 与 `info1` refEq 相等；
 *   - 第 2 次调用：传入的是 `info2`（与 `info1` 不是同一对象），但切面收到的 funcInfo **仍与 info1 同一实例**
 *     ⇒ 链上复用的就是首次调用捕获的那个对象；
 *   - 同一对象上再读 `args` 得到 2 ⇒ 该对象的 `_args` 被后续调用改写。
 * 结论：串台的载体是"**被捕获进链的那个对象**"，而不是"缓存的参数值"；且单线程下参数始终正确
 * （写—读顺序发生）——串台只在并发交错时出现（另见 `aspect_args_race_test.cj`）。
 */
@Test
public class AspectChainCapture_test {
    @TestCase
    public func testChainCapturesFirstCallInfo(): Unit {
        BeanFactory.instance.register<ArgsIdentityAspect>({=> ArgsIdentityAspect()})

        let info1 = InvocationFuncInfo(TypeInfo.of<CaptureTarget>(), 'n', [TypeInfo.of<Int64>()], [1])
        let info2 = InvocationFuncInfo(TypeInfo.of<CaptureTarget>(), 'n', [TypeInfo.of<Int64>()], [2])
        @Assert(refEq(info1, info2), false) // 先确认两次调用的 info 是两个不同对象
        ArgsIdentityAspect.firstCallInfo.add(info1)

        let r1 = Aspects.proceed<Int64>(info1, {args: Array<Any> => (args[0] as Int64).getOrThrow()})
        let r2 = Aspects.proceed<Int64>(info2, {args: Array<Any> => (args[0] as Int64).getOrThrow()})
        println("第 1 次调用返回 ${r1}；第 2 次调用返回 ${r2}")
        println("切面收到的 funcInfo 与 info1（首次调用）同一实例：第1次=${ArgsIdentityAspect.sameAsFirst[0]}，第2次=${ArgsIdentityAspect.sameAsFirst[1]}")
        println("该对象上的 args 依次为 ${ArgsIdentityAspect.argsOnCapturedInfo[0]}/${ArgsIdentityAspect.argsOnCapturedInfo[1]}")

        // 单线程下参数正确：串台只在并发交错时出现
        @Assert(r1, 1)
        @Assert(r2, 2)
        // 第 1 次调用：切面收到的就是本次传入的 info1
        @Assert(ArgsIdentityAspect.sameAsFirst[0], true)
        @Assert(ArgsIdentityAspect.argsOnCapturedInfo[0], 1)
        // 第 2 次调用：切面收到的仍是 info1（不是 info2）⇒ 闭包固化的是首次调用那个对象
        @Assert(ArgsIdentityAspect.sameAsFirst[1], true)
        // 同一对象上的 _args 已被第 2 次调用改写成 2 ⇒ "可变槽"就是这个被捕获的对象
        @Assert(ArgsIdentityAspect.argsOnCapturedInfo[1], 2)
    }
}
