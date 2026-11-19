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
import fountain::f_jit.base.{DummyDiagnosticsSink, JitException, LocalType}
import fountain::f_jit.runtime.{HandleTable, NativeMem}
import fountain::f_jit.test.ReflectUser

/**
 * 对象生命周期加固（OpenSpec change `harden-f-jit-object-lifetime`）。
 *
 * - **G1**：返回值解包抛异常时也必须归还逃逸句柄（否则每次契约失败泄漏 1 槽）；
 * - **G4**：`isReturnedHandle` 由 `LocalType.isHandle` 单点派生（0–19 完备性）；
 * - **G6**：成功 / 运行期错误 / 契约失败三类出口各 20 次后资源归零；
 * - **G3**：容器元素是宿主引用（写入即 `cellToAny`），闭包捕获容器不依赖级联提升。
 */
@Test
public class Lifetime_test {

    private static func compiler(): Compiler {
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        c.registerType<ReflectUser>()
        c
    }

    /** G1 + G6：契约失败（返回 14 而 `call<String>`）不泄漏句柄。 */
    @TestCase
    public func contractFailDoesNotLeakHandle(): Unit {
        let c = Lifetime_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ u: ReflectUser => u }')
        let base = HandleTable.liveCount()
        var i = 0
        while (i < 20) {
            try {
                let _ = f.call<String>([ReflectUser('a', 1)])
                @Fail('应当契约失败')
            } catch (_: JitException) {
                ()
            }
            i = i + 1
        }
        @Assert(HandleTable.liveCount(), base)
        @Assert(HandleTable.windowUsed(), 0)
    }

    /** G6：成功调用 20 次后句柄/窗口/非托管内存均不增长。 */
    @TestCase
    public func successfulCallsKeepResourcesFlat(): Unit {
        let c = Lifetime_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ x: Int64 => x + 1 }')
        let baseLive = HandleTable.liveCount()
        let baseMem = NativeMem.outstanding()
        var i = 0
        while (i < 20) {
            @Assert(f.call<Int64>([Int64(i)]), Int64(i) + 1)
            i = i + 1
        }
        @Assert(HandleTable.liveCount(), baseLive)
        @Assert(HandleTable.windowUsed(), 0)
        @Assert(NativeMem.outstanding(), baseMem)
    }

    /** G6：运行期错误（÷0）20 次后资源同样归零。 */
    @TestCase
    public func runtimeErrorCallsKeepResourcesFlat(): Unit {
        let c = Lifetime_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ x: Int64 => 1 / x }')
        let baseLive = HandleTable.liveCount()
        var i = 0
        while (i < 20) {
            try {
                let _ = f.call<Int64>([0])
                @Fail('应当 DIV_ZERO')
            } catch (_: JitException) {
                ()
            }
            i = i + 1
        }
        @Assert(HandleTable.liveCount(), baseLive)
        @Assert(HandleTable.windowUsed(), 0)
    }

    /** G4：句柄返回码集合 = `4–11,13–19`，闭包 12 恒假（0–19 完备性）。 */
    @TestCase
    public func returnedHandleCodesAreDerived(): Unit {
        var code: UInt16 = 0
        while (code <= 19) {
            let expect = code >= 4u16 && code <= 19u16 && code != LocalType.CLOSURE
            @Assert(JitFunction.isReturnedHandle(code), expect)
            code = code + UInt16(1)
        }
    }

    /** G3：闭包捕获容器（元素是宿主引用），跨作用域读元素仍正确。 */
    @TestCase
    public func closureCaptureKeepsContainerElements(): Unit {
        let c = Lifetime_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ n: Int64 => let xs = [n, n + 1]\n let g = { i: Int64 => xs[i] }\n g(1) }')
        @Assert(f.call<Int64>([7]), 8)
        @Assert(HandleTable.windowUsed(), 0)
    }
}
