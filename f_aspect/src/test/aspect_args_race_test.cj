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
import std.sync.*
import fountain::f_base.*
import fountain::f_aspect.*
import fountain::f_bean.BeanFactory

/**
 * 只用来提供真实的函数元数据（`getInstanceFunction` 需要函数真实存在）。
 */
public class RaceTarget {
    public func m(v: Int64): Int64 {
        v
    }
}

/**
 * 回归用例用切面：**自身完全线程安全** —— 无实例状态、不缓存 `funcInfo`、不做任何同步，
 * 并且**完全不读 `funcInfo.args`**（`before` 只按调用序号区分 T1/T2，用于制造确定性交错）。
 */
@AspectRoute[FuncNameRouteRule("m")]
public class ArgsRaceAspect <: Aspect {
    public static let t1InBefore = AtomicBool(false)
    public static let t2Done = AtomicBool(false)
    private static let enterCount = AtomicInt64(0)

    public init() {}

    public func before(funcInfo: InvocationFuncInfo): Unit {
        if (enterCount.fetchAdd(1) == 0) { // 第一次进入 before 的是 T1 的调用（时序由本用例的握手保证）
            t1InBefore.store(true)
            var i = 0
            while (!t2Done.load() && i < 500) {
                sleep(Duration.millisecond * 10)
                i++
            }
        }
    }
}

/**
 * ASP-2 回归：同一「(类型, 函数)」被并发调用时，**每次调用都必须用回自己的实参**。
 *
 * 修复前（`.autocode/bugs/bug.md` §1.4）：链的层闭包把本次调用的实参写进 `computeIfAbsent`
 * 闭包捕获的、首次调用的那个 `InvocationFuncInfo`，默认模板 `Aspect.around` 再从该共享对象上
 * 读 `point(funcInfo.args)` 交给链尾，于是 T1 的调用会拿到 T2 的实参（实测 T1 传入 1、业务方法实收 2）。
 * 修复后：每层用本次调用的 `args` 新建 `InvocationFuncInfo`（`Aspects.cj` doProceed 的层闭包），
 * 实参逐调用传递，并发调用之间不再共享可变状态。
 *
 * 本用例不经过宏织入，直接按宏生成代码的形状（`macros/PointCut.cj:86-88,115`）构造每次调用
 * 一个 `InvocationFuncInfo` 并调 `Aspects.proceed`；切面无状态、不加锁、不读 args，
 * 用 AtomicBool 制造确定性交错（T1 进 before 后等 T2 整轮跑完）。
 */
@Test
public class AspectArgsRace_test {
    @TestCase
    public func testConcurrentCallsCrossArgs(): Unit {
        BeanFactory.instance.register<ArgsRaceAspect>({=> ArgsRaceAspect()})

        let info1 = InvocationFuncInfo(TypeInfo.of<RaceTarget>(), 'm', [TypeInfo.of<Int64>()], [1])
        let info2 = InvocationFuncInfo(TypeInfo.of<RaceTarget>(), 'm', [TypeInfo.of<Int64>()], [2])

        // T1：进入 before 后被卡住（此时 info₀ 的实参已被写成 1）
        let fut1 = spawn {
            Aspects.proceed<Int64>(info1, {args: Array<Any> => (args[0] as Int64).getOrThrow()})
        }
        var i = 0
        while (!ArgsRaceAspect.t1InBefore.load() && i < 1000) {
            sleep(Duration.millisecond * 5)
            i++
        }

        // T2：完整跑完一次调用（进入链时把 info₀ 的实参改写成 2）
        let fut2 = spawn {
            Aspects.proceed<Int64>(info2, {args: Array<Any> => (args[0] as Int64).getOrThrow()})
        }
        let r2 = fut2.get()
        ArgsRaceAspect.t2Done.store(true)

        let r1 = fut1.get()
        println("T1 传入实参 1，业务方法实收 ${r1}；T2 传入实参 2，业务方法实收 ${r2}")
        @Assert(r2, 2) // 第二次调用自身正确：说明场景本身没坏
        @Assert(r1, 1) // T1 必须用回自己的实参；修前这里拿到的是 2
    }
}
