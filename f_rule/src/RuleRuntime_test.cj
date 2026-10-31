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
package fountain::f_rule

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.Compiler

/**
 * `RuleRuntime` 的共享编译器契约（`specs/f-rule-engine-core`：初始化与共享编译器）。
 *
 * 三条不变量：
 * 1. 注入的编译器被原样复用（引用相等），构建期 `JitExpression` 与 `f_egraph` 命中同一份缓存；
 * 2. 未注入时惰性创建默认编译器，且反复取用仍是同一实例；
 * 3. 惰性路径的 WARN 每次进程只发一次，不随取用次数增长。
 */
@Test
class RuleRuntime_test {
    /** 每个用例从"未初始化"开始，避免全局状态串用例。 */
    private func fresh(): Unit {
        RuleRuntime.resetForTest()
    }

    /** 注入后原样返回同一实例，不新建 `Compiler`。 */
    @TestCase
    public func injectedCompilerIsReused(): Unit {
        fresh()
        let injected = Compiler()
        RuleRuntime.initCompiler(injected)
        @Expect(refEq(RuleRuntime.compiler(), injected), true)
        @Expect(refEq(RuleRuntime.compiler(), injected), true)
        // 注入路径不算惰性初始化，不产生告警
        @Assert(RuleRuntime.lazyWarningCount(), 0)
    }

    /** 未注入时惰性创建，后续取用复用同一实例。 */
    @TestCase
    public func lazyCompilerIsStable(): Unit {
        fresh()
        let first = RuleRuntime.compiler()
        @Expect(refEq(RuleRuntime.compiler(), first), true)
        @Assert(RuleRuntime.lazyWarningCount(), 1)
    }

    /** WARN 只发一次：多次取用不会刷屏。 */
    @TestCase
    public func lazyWarningIsPrintedOnce(): Unit {
        fresh()
        for (_ in 0..5) {
            RuleRuntime.compiler()
        }
        @Assert(RuleRuntime.lazyWarningCount(), 1)
    }

    /** 惰性创建之后再注入：切换为注入实例，且不重复告警。 */
    @TestCase
    public func injectionAfterLazyWins(): Unit {
        fresh()
        let lazyOne = RuleRuntime.compiler()
        @Expect(refEq(RuleRuntime.compiler(), lazyOne), true)

        let injected = Compiler()
        RuleRuntime.initCompiler(injected)
        @Expect(refEq(RuleRuntime.compiler(), injected), true)
        @Assert(RuleRuntime.lazyWarningCount(), 1)
    }
}
