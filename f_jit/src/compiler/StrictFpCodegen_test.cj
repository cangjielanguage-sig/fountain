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
package fountain::f_jit.compiler

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader

/**
 * X3：`strictFp` 的**产物级**证据（逐助记符断言）。
 *
 * 行为用例证明「÷0 报不报错」，本用例证明「靠换 opcode 实现，而不是靠运行期开关」——
 * `FDIV_CHK` 必须真的被前端发射，否则它仍是不可达指令。
 */
@Test
public class StrictFpCodegen_test {

    private static const DIV_SRC: String = '{ x: Float64 => 1.0f64 / x }'

    private static func ops(src: String, strict: Bool): String {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR, strictFp: strict)
        CodeDump.ops(LowererM2_test.entryBytes(FbcReader.load(sc.compile(src).raw)))
    }

    /** 严格：`/` 发 `FDIV_CHK`，且不发 `FDIV`（同一条除法只有一个形态）。 */
    @TestCase
    public func strictEmitsFdivChk(): Unit {
        let o = StrictFpCodegen_test.ops(StrictFpCodegen_test.DIV_SRC, true)
        @Assert(StrictFpCodegen_test.countOf(o, 'FDIV_CHK'), 1)
        @Assert(StrictFpCodegen_test.countOf(o, 'FDIV'), 0)
    }

    /** 缺省（不传 `strictFp`）：产物就是 `FDIV_CHK`——严格是产品缺省。 */
    @TestCase
    public func defaultEmitsFdivChk(): Unit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        let o = CodeDump.ops(LowererM2_test.entryBytes(
            FbcReader.load(sc.compile(StrictFpCodegen_test.DIV_SRC).raw)))
        @Assert(StrictFpCodegen_test.countOf(o, 'FDIV_CHK'), 1)
        @Assert(StrictFpCodegen_test.countOf(o, 'FDIV'), 0)
    }

    /** 显式关闭：只有 `FDIV`，`FDIV_CHK` 零出现。 */
    @TestCase
    public func looseKeepsFdiv(): Unit {
        let o = StrictFpCodegen_test.ops(StrictFpCodegen_test.DIV_SRC, false)
        @Assert(o.contains('FDIV_CHK'), false)
        @Assert(StrictFpCodegen_test.countOf(o, 'FDIV'), 1)
    }

    /** 其他算术不受影响（`+ - *` 仍发各自 opcode）。 */
    @TestCase
    public func otherArithmeticUnaffected(): Unit {
        let o = StrictFpCodegen_test.ops('{ x: Float64 => (x + 1.0f64) * 2.0f64 - 3.0f64 }', true)
        @Assert(o.contains('FADD'), true)
        @Assert(o.contains('FMUL'), true)
        @Assert(o.contains('FSUB'), true)
        @Assert(o.contains('FDIV_CHK'), false)
    }

    /** 子串出现次数（助记符按空格分隔，前后补空格避免 `FDIV` 命中 `FDIV_CHK`）。 */
    private static func countOf(ops: String, name: String): Int64 {
        let hay = ' ' + ops + ' '
        let needle = ' ' + name + ' '
        var n = 0
        var i = hay.indexOf(needle)
        while (i.isSome()) {
            n = n + 1
            match (i) {
                case Some(p) => i = hay.indexOf(needle, p + needle.size)
                case None => ()
            }
        }
        n
    }
}
