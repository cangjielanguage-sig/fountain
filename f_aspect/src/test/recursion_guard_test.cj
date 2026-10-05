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

/** 自递归的织入目标 */
@WeavedBean
public class RecursionTarget {
    public func r(n: Int64): Int64 {
        if (n <= 0) {
            0
        } else {
            n + r(n - 1)
        }
    }
}

/** 记录切面进入次数（不读 args 做判断，无状态、不加锁） */
@AspectRoute[FuncNameRouteRule("r")]
public class RecursionCountAspect <: Aspect {
    public static let entries = ArrayList<Int64>()
    public init() {}
    public func before(funcInfo: InvocationFuncInfo): Unit {
        entries.add((funcInfo.args[0] as Int64).getOrThrow())
    }
}

/**
 * `ASP-L4`（§3.1）语义守卫：同一线程内的嵌套调用（含自递归）不再织入 —— 切面只进入最外层那一次，
 * 与 README「嵌套调用与递归（设计）」一致。把 `ThreadLocal<Bool>` 换成按线程的可变状态对象后，
 * 这条语义必须仍然成立（本用例在改动前后都应通过）。
 */
@Test
public class RecursionGuard_test {
    @TestCase
    public func testRecursiveCallWeavesOnce(): Unit {
        BeanFactory.instance.register<RecursionCountAspect>({=> RecursionCountAspect()})
        let bean = RecursionTarget()
        let r = bean.r(3) // 3 + 2 + 1 + 0
        @Assert(r, 6)
        @Assert(RecursionCountAspect.entries.size, 1) // 只织入最外层一次
        @Assert(RecursionCountAspect.entries[0], 3)
    }
}
