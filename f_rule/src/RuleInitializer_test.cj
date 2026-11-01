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
import fountain::f_app.Initializer
import fountain::f_jit.Compiler

/**
 * `RuleInitializer` 的注册元数据与初始化行为（`specs/f-rule-engine-core`：初始化与共享编译器）。
 *
 * `f_app` 按 `name` 去重、按 `dependencies` 排序执行初始化，所以这两项是**契约**而非装饰：
 * 改名字会让依赖它的自定义 Initializer 永远等不到；漏依赖会让 `f_rule` 早于 `f_egraph` 启动。
 */
@Test
class RuleInitializer_test {
    /** 名称与依赖与 `design.md` D11 一致。 */
    @TestCase
    public func nameAndDependencies(): Unit {
        let initializer: Initializer = RuleInitializer()
        @Assert(initializer.name, "fountain::f_rule")
        @Assert(initializer.dependencies.size, 1)
        @Assert(initializer.dependencies[0], "fountain::f_egraph")
    }

    /** `initialize()` 只准备共享编译器，不主动加载规则（规则由应用注入）。 */
    @TestCase
    public func initializeEnsuresCompiler(): Unit {
        RuleRuntime.resetForTest()
        let injected = Compiler()
        RuleInitializer().initialize()
        // 未注入时应已有默认编译器可用，且不抛错
        let first = RuleRuntime.compiler()
        @Expect(refEq(RuleRuntime.compiler(), first), true)

        RuleRuntime.initCompiler(injected)
        @Expect(refEq(RuleRuntime.compiler(), injected), true)
    }
}
