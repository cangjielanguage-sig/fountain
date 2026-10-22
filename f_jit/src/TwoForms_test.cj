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
import fountain::f_jit.base.JitMode
import fountain::f_jit.base.JitException
import fountain::f_jit.test.TCase

/** T52：同源同参的**机器码形态**与**纯字节码形态**同接口、同结果。 */
@Test
public class TwoForms_test {
    @TestCase
    public func t52TwoFormsSameBehavior(): Unit {
        // 机器码形态 × 纯字节码形态：同接口、同结果、同错误码
        let src = '{ n: Int64 => n * 3 + 1 }'
        var o = CompileOptions(DummyDiagnosticsSink())
        o.jit = JitMode.Force
        let jit = Compiler(o).compile(src)
        @Assert(jit.isJitBacked(), true)
        var b = CompileOptions(DummyDiagnosticsSink())
        b.jit = JitMode.Off
        let bc = Compiler(b).compile(src)
        @Assert(bc.isJitBacked(), false)
        for (n in [0, 1, 7, 21, 1000]) {
            @Assert(TCase.hit('T52/two-forms-same-result',
                jit.call<Int64>([n]) == bc.call<Int64>([n])), true)
        }
        // 失败语义同样一致：越界/除零
        let src2 = '{ a: Int64 => a / (a - a) }'
        var o2 = CompileOptions(DummyDiagnosticsSink())
        o2.jit = JitMode.Force
        var b2 = CompileOptions(DummyDiagnosticsSink())
        b2.jit = JitMode.Off
        let jf = Compiler(o2).compile(src2)
        let bf = Compiler(b2).compile(src2)
        var jc: Int64 = 0
        var bcc: Int64 = 0
        try {
            let _ = jf.call<Int64>([1])
        } catch (e: JitException) {
            jc = e.code
        }
        try {
            let _ = bf.call<Int64>([1])
        } catch (e: JitException) {
            bcc = e.code
        }
        @Assert(jc, 1)
        @Assert(bcc, 1)
    }
}
