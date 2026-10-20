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
 * M2.1：`@JitBind` 把 overrides 从「手写 PredefinedFunction + 逐参 as」降到一行标注。
 *
 * 生成的 `jitBind_greet()` 与手写版等价：签名码由 `JitBindSupport.code<T>()` 在注册期算出，
 * 绑定体是类型化嵌套调用（不再经过 `InstanceFunctionInfo.apply` 的 MCC 路径）。
 */
public class JitBindUser {
    public var name: String

    public init(name: String) {
        this.name = name
    }

    @JitBind[JitBindUser]
    public func greet(s: String): String {
        'macro hi ${s}'
    }

    /** 值型方法也要能生成（用于混合签名场景）。 */
    @JitBind[JitBindUser]
    public func bump(n: Int64): Unit {
        this.name = '${this.name}!'
    }
}

@Test
public class JitBind_test {
    @TestCase
    public func macroGeneratedBindingIsEndToEnd(): Unit {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<JitBindUser>(overrides: [JitBindUser.jitBind_greet(), JitBindUser.jitBind_bump()])
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

    /** 签名码来自宏展开，必须与反射注册的口径逐位一致（含首参 14）。 */
    @TestCase
    public func generatedSignatureMatchesReflectiveShape(): Unit {
        let m = JitBindUser.jitBind_greet()
        @Assert(m.name, 'greet')
        @Assert(m.bind.paramTypes, [LocalType.HOST_OBJECT, LocalType.STRING])
        @Assert(m.bind.retType, LocalType.STRING)

        let b = JitBindUser.jitBind_bump()
        @Assert(b.bind.paramTypes, [LocalType.HOST_OBJECT, LocalType.I64])
        @Assert(b.bind.retType, LocalType.UNIT)
    }
}
