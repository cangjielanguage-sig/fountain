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
import fountain::f_jit.macros.*

/**
 * M2.1：`@JitBind` 修饰类，一次生成全部公共实例方法的 overrides。
 *
 * 宏展开出顶层函数 `jitOverrides_JitBindUser()`，注册处直接交给 `overrides:`。
 */
@JitBind
public class JitBindUser {
    public var name: String

    public init(name: String) {
        this.name = name
    }

    public func greet(s: String): String {
        'macro hi ${s}'
    }

    public func bump(n: Int64): Unit {
        this.name = '${this.name}!'
    }

    private func hidden(): Int64 {
        0
    }
}

@Test
public class JitBind_test {
    private static func methodOf(name: String): PublicMethod {
        for (m in jitOverrides_JitBindUser()) {
            if (m.name == name) {
                return m
            }
        }
        throw Exception('未生成方法「${name}」的绑定')
    }

    @TestCase
    public func macroGeneratedBindingIsEndToEnd(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<JitBindUser>(overrides: jitOverrides_JitBindUser())
        CompileCache.reset()
        let f = c.compile('{ u: JitBindUser => u.greet("z") }')
        let u = JitBindUser('bob')
        @Assert(f.call<String>([u]), 'macro hi z')

        // GAP-13 回归：宏生成的绑定走嵌套闭包，300 次不崩
        var i = 0
        var ok = true
        while (i < 300) {
            if (f.call<String>([u]) != 'macro hi z') {
                ok = false
            }
            i = i + 1
        }
        @Assert(ok, true)
    }

    /** 类级展开只收公共实例方法：私有方法不入表，值型/引用型签名都要对。 */
    @TestCase
    public func generatedSignatureMatchesReflectiveShape(): Unit {
        let ms = jitOverrides_JitBindUser()
        @Assert(ms.size, 2)

        let g = JitBind_test.methodOf('greet')
        @Assert(g.bind.paramTypes, [LocalType.HOST_OBJECT, LocalType.STRING])
        @Assert(g.bind.retType, LocalType.STRING)

        let b = JitBind_test.methodOf('bump')
        @Assert(b.bind.paramTypes, [LocalType.HOST_OBJECT, LocalType.I64])
        @Assert(b.bind.retType, LocalType.UNIT)

        var hasHidden = false
        for (m in ms) {
            if (m.name == 'hidden') {
                hasHidden = true
            }
        }
        @Assert(hasHidden, false)
    }
}
