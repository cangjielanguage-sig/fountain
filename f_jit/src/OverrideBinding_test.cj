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
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.PredefinedFunction
import fountain::f_jit.base.PublicMethod
import fountain::f_jit.test.ReflectUser

/**
 * M2.1：`registerType<T>(overrides:)` —— 手工绑定覆盖反射生成的包装。
 *
 * 覆盖的动机是 GAP-13：反射注册的方法绑定走 `InstanceFunctionInfo.apply`，在 String
 * 参数/返回上必现 SIGSEGV。覆盖后同一方法改由**类型化闭包**执行（嵌套闭包调用），
 * 既绕开 MCC，也把 9.8 μs 降到百纳秒级。
 *
 * 语义（与 `ReflectRegistrar.applyOverrides` 对齐）：
 * - 按**方法名**匹配，命中则连签名带实现一起替换，未命中按新增登记；
 * - slot 名沿用反射生成的 `类名.方法名`，手工 bind 的名字只作宿主侧标识。
 */
@Test
public class OverrideBinding_test {
    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /** 与反射版 `greet` 同签名，但返回值可区分——命中与否一眼可见。 */
    private static func greetOverride(): PublicMethod {
        PublicMethod(name: 'greet', bind: PredefinedFunction('ReflectUser.greet',
            [LocalType.HOST_OBJECT, LocalType.STRING], LocalType.STRING,
            { args =>
                match (args[0]) {
                    case u: ReflectUser =>
                        match (args[1]) {
                            case s: String => 'override ' + s
                            case _ => 'override ?'
                        }
                    case _ => 'override ?'
                }
            }))
    }

    /** 反射里不存在的方法：应作为新增登记，可被 JIT 以 `u.jitOnly()` 调用。 */
    private static func jitOnlyOverride(): PublicMethod {
        PublicMethod(name: 'jitOnly', bind: PredefinedFunction('ReflectUser.jitOnly',
            [LocalType.HOST_OBJECT], LocalType.STRING,
            { _ => 'jit-only' }))
    }

    @TestCase
    public func overrideReplacesReflectiveBinding(): Unit {
        let c = OverrideBinding_test.compiler()
        c.registerType<ReflectUser>(overrides: [OverrideBinding_test.greetOverride()])
        CompileCache.reset()
        let greet = c.compile('{ u: ReflectUser => u.greet("z") }')
        let u = ReflectUser('bob', 0)
        @Assert(greet.call<String>([u]), 'override z')

        // 未被覆盖的方法仍走反射，行为不变
        let bump = c.compile('{ u: ReflectUser => u.bump(4)\n age(u) }')
        @Assert(bump.call<Int64>([ReflectUser('ann', 7)]), 4)
    }

    /** GAP-13 回归：覆盖后 300 次调用不再触发反射 MCC 路径。 */
    @TestCase
    public func overrideSurvivesRepeatedCalls(): Unit {
        let c = OverrideBinding_test.compiler()
        c.registerType<ReflectUser>(overrides: [OverrideBinding_test.greetOverride()])
        CompileCache.reset()
        let greet = c.compile('{ u: ReflectUser => u.greet("z") }')
        let u = ReflectUser('bob', 0)
        var i = 0
        var ok = true
        while (i < 300) {
            let r = greet.call<String>([u])
            if (r != 'override z') {
                ok = false
            }
            i = i + 1
        }
        @Assert(ok, true)
    }

    /** 未命中反射方法表的覆盖：按新增登记，slot 同时补齐。 */
    @TestCase
    public func unmatchedOverrideRegistersNewMethod(): Unit {
        let c = OverrideBinding_test.compiler()
        c.registerType<ReflectUser>(overrides: [OverrideBinding_test.jitOnlyOverride()])
        let f = c.compile('{ u: ReflectUser => u.jitOnly() }')
        @Assert(f.call<String>([ReflectUser('bob', 0)]), 'jit-only')
    }

    /** GAP-13 默认拒绝：没有 overrides 时，引用型签名的方法不生成反射绑定（宁可缺方法也不崩）。 */
    @TestCase
    public func reflectiveStringMethodIsRejectedByDefault(): Unit {
        let c = OverrideBinding_test.compiler()
        c.registerType<ReflectUser>()
        var failed = false
        try {
            // 缓存键只含源码指纹，且别的用例编译过同一段源码（带 overrides）⇒ 先清缓存
            CompileCache.reset()
            let _ = c.compile('{ u: ReflectUser => u.greet("z") }')
        } catch (_: Exception) {
            failed = true
        }
        // 失败也会进缓存（`failureOf`），不清理会污染后续用例
        CompileCache.reset()
        @Assert(failed, true)
        // 值型方法不受影响，仍走反射绑定
        let bump = c.compile('{ u: ReflectUser => u.bump(2)\n 0 }')
        @Assert(bump.call<Int64>([ReflectUser('bob', 0)]), 0)
    }

    /** 覆盖不改契约：签名取自手工 bind，编译期仍做逐参类型检查。 */
    @TestCase
    public func overrideKeepsStaticContract(): Unit {
        let c = OverrideBinding_test.compiler()
        c.registerType<ReflectUser>(overrides: [OverrideBinding_test.greetOverride()])
        var failed = false
        try {
            CompileCache.reset()
            let _ = c.compile('{ u: ReflectUser => u.greet(1) }')
        } catch (_: Exception) {
            failed = true
        }
        CompileCache.reset()
        @Assert(failed, true)
    }
}
