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
package fountain::f_jit

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.test.ReflectUser

/**
 * GAP-13 最小复现：反射注册的「String 参数 + String 返回」实例方法，反复调用必崩。
 *
 * 现象：`greet.call<String>([u])` 循环 300 次，进程 SIGSEGV；75 次仍通过、100 次起崩，
 * 300 次稳定崩溃。崩溃栈恒定：
 *   StringBuilder.append ← ReflectUser.greet ← ApplyCangjieMethodStub
 *   ← ApplyCJMethodImpl ← ApplyCJMethod ← InstanceFunctionInfo.apply
 *
 * 边界：
 * - 值型方法不触发（把 `u.greet("z")` 换成 `u.bump(1)` 后 300 次不崩）；
 * - 手工绑定同一方法（`ManualUser.greet`，自定义 `PredefinedFunction` impl）不触发；
 * - `--parallel 1` 同样复现，与测试并发无关。
 *
 * 归因：失效点在 `InstanceFunctionInfo.apply` 的 MCC / `ArgValue` 转换——值型参数不经 GC，
 * 只有引用型参数/返回暴露，属 `std.reflect` 实现缺陷，应用层无法修复。根治方向是
 * 类型化包装闭包（`{ Array<Any> => Any }` 的静态绑定），绕开 MCC。
 *
 * **本用例预期崩溃**，只用于复现与回归验证，不得合入主干。
 */
@Test
public class SigsegvRepro_test {
    @TestCase
    public func repeatedStringMethodCallCrashes(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<ReflectUser>()
        let greet = c.compile('{ u: ReflectUser => u.greet("z") }')
        let u = ReflectUser('bob', 0)
        var i = 0
        while (i < 300) {
            let _ = greet.call<String>([u])
            i = i + 1
        }
        // 走到这里说明崩溃未复现（预期不可达）
        @Assert(true, true)
    }
}
