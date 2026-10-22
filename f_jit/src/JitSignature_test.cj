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
import fountain::f_jit.base.SignatureRegistry
import fountain::f_jit.macros.*

/**
 * `@JitSignatures`（M2.3）：闭包形参的类型化 adapter，由宏在宿主编译期生成。
 *
 * 这里刻意**不复用** `HostClosureAdapter_test` 的两个签名（`(Int64) -> Int64` /
 * `(Int64, Int64) -> Int64`）——`SignatureRegistry` 是进程级单例，签名撞车会让两个用例互相决定命运。
 */
@JitSignatures[(String) -> Int64, (Int64, Int64) -> Bool]
public func jitSignatures(): Unit {}

@Test
public class JitSignature_test {

    /** 宏在包初始化/显式调用时把两条签名登记进表（结构逐位正确）。 */
    @TestCase
    public func macroRegistersDeclaredSignatures(): Unit {
        SignatureRegistry.resetForTest()
        __jitSigRegister_jitSignatures()
        let one = JitHost.findSignature([LocalType.STRING], [''], LocalType.I64, '')
        @Assert(one.isSome(), true)
        let two = JitHost.findSignature([LocalType.I64, LocalType.I64], ['', ''], LocalType.BOOL, '')
        @Assert(two.isSome(), true)
        // 元数/类型不同的签名不应被顺手登记
        @Assert(JitHost.findSignature([LocalType.I64], [''], LocalType.I64, '').isNone(), true)
    }

    /** 登记后，JIT 里对闭包形参的调用走 adapter（结果正确，且不经反射）。 */
    @TestCase
    public func typedAdapterDrivesHostClosureCall(): Unit {
        SignatureRegistry.resetForTest()
        __jitSigRegister_jitSignatures()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        CompileCache.reset()
        let f = c.compile('{ g: (String) -> Int64, s: String => g(s) }')
        let cb: (String) -> Int64 = { s => s.size }
        @Assert(f.call<Int64>([cb, 'abcd']), 4)
    }

    /** 未登记时退回反射路径，行为不变（adapter 是加速手段，不是语义前提）。 */
    @TestCase
    public func reflectionStillWorksWhenUnregistered(): Unit {
        SignatureRegistry.resetForTest()
        let c = Compiler(CompileOptions(DummyDiagnosticsSink()))
        CompileCache.reset()
        let f = c.compile('{ g: (String) -> Int64, s: String => g(s) }')
        let cb: (String) -> Int64 = { s => s.size }
        @Assert(f.call<Int64>([cb, 'abcd']), 4)
        // 复原，避免影响同包其他用例
        __jitSigRegister_jitSignatures()
    }
}
