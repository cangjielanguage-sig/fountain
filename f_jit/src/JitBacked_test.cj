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

/**
 * "单元是否真的被 JIT"（而非整单元静默退回解释器）的守卫。
 *
 * 背景：x86/aarch64 的发射审计会拒绝"未登记的内存基址"，一旦误判就会让**整单元**回退，
 * 而回退是透明的——功能测试仍然绿、只有性能下降。这里用 `JitFunction.isJitBacked()`
 * 把"必须 JIT"钉成断言，覆盖两条**宿主绝对地址**路径：
 *
 * - 常量镜像（`PUSH_KH`）：字符串字面量；
 * - 函数入口表（`CALL_FUNC`）：方言暂未提供源级触发（`recursive` 未实现），由
 *   `EmitAudit_test.absoluteAddressIsExempt` 以审计哨兵覆盖。
 */
@Test
public class JitBacked_test {

    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /** 纯算术：基线（无绝对地址访问）。 */
    @TestCase
    public func plainUnitStaysJitBacked(): Unit {
        let c = JitBacked_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ x: Int64 => x + 1 }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<Int64>([Int64(1)]), 2)
    }

    /** 含常量镜像（字符串字面量 ⇒ `PUSH_KH`）仍必须 JIT，且结果正确。 */
    @TestCase
    public func constMirrorUnitStaysJitBacked(): Unit {
        let c = JitBacked_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ x: Int64 => let s = "abc"\n s }')
        @Assert(f.isJitBacked(), true)
        @Assert(f.call<String>([Int64(7)]), 'abc')
    }
}
