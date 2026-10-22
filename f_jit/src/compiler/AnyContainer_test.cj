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
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.test.TCase
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.DiffOutcome
import fountain::f_jit.test.diff.InterpRunner

/**
 * M3 R4.4/R4.5：H79/H80 的类型描述符（`typecode` + `aux`）与容器转型。
 *
 * `aux` 编码（m3 §5）：`List` → 元素码、`Map` → `(键码 << 8) | 值码`、其余 → `0xFFFF`。
 * 容器命中按**不变语义**：`List<Any>` 命中、`List<Int64>` 不命中（22 / 0）。
 */
@Test
public class AnyContainer_test {

    // ------------------------------------------------------------------
    // aux 编码（编译产物）
    // ------------------------------------------------------------------

    /** `List` 的 aux = 元素码：`List<Any>` ⇒ 15、`List<Int64>` ⇒ 0。 */
    @TestCase
    public func listAuxEncodesElementCode(): Unit {
        let d1 = AnyContainer_test.dumpOf(
            '{ => let l: List<Any> = [1]\n let a: Any = l\n let m = a as List<Any>\n 0 }')
        @Assert(d1.contains('CALL_HELPER 80,3'), true)
        @Assert(AnyContainer_test.hasOperand(d1, 'PUSH_I64 15'), true)
        let d2 = AnyContainer_test.dumpOf(
            '{ => let l: List<Any> = [1]\n let a: Any = l\n let m = a as List<Int64>\n 0 }')
        @Assert(AnyContainer_test.hasOperand(d2, 'PUSH_I64 0'), true)
        @Assert(TCase.hit('T39/aux-list', true), true)
    }

    /** `Map` 的 aux = `(键码 << 8) | 值码`：`Map<String,Any>` ⇒ 1039、`Map<String,Int64>` ⇒ 1024。 */
    @TestCase
    public func mapAuxEncodesKeyAndValue(): Unit {
        let d1 = AnyContainer_test.dumpOf(
            '{ => let m: Map<String, Any> = {}\n let a: Any = m\n let n = a as Map<String, Any>\n 0 }')
        @Assert(AnyContainer_test.hasOperand(d1, 'PUSH_I64 1039'), true)
        let d2 = AnyContainer_test.dumpOf(
            '{ => let m: Map<String, Any> = {}\n let a: Any = m\n let n = a as Map<String, Int64>\n 0 }')
        @Assert(AnyContainer_test.hasOperand(d2, 'PUSH_I64 1024'), true)
        @Assert(TCase.hit('T39/aux-map', true), true)
    }

    /** 非容器目标的 aux 恒为 `0xFFFF`（JSON 码亦然）。 */
    @TestCase
    public func plainTargetsUseMaxAux(): Unit {
        let d = AnyContainer_test.dumpOf('{ => let a: Any = 1\n let m = a as Int64\n 0 }')
        @Assert(AnyContainer_test.hasOperand(d, 'PUSH_I64 65535'), true)
        let j = AnyContainer_test.dumpOf(
            '{ => let a: Any = `{"k":1}`\n let m = a as JsonObject\n 0 }')
        @Assert(AnyContainer_test.hasOperand(j, 'PUSH_I64 65535'), true)
    }

    // ------------------------------------------------------------------
    // 容器转型（不变语义）
    // ------------------------------------------------------------------

    /** `as List<Any>` 命中；`as List<Int64>` → 22。 */
    @TestCase
    public func listCastHonoursElementType(): Unit {
        let ok = AnyContainer_test.run(
            '{ => let l: List<Any> = [1]\n let a: Any = l\n let m = a as List<Any>\n 0 }')
        @Assert(ok.errCode, 0)
        let bad = AnyContainer_test.run(
            '{ => let l: List<Any> = [1]\n let a: Any = l\n let m = a as List<Int64>\n 0 }')
        @Assert(bad.errCode, Int64(ErrCode.ANY_CAST))
        @Assert(TCase.hit('T39/list-cast-22', bad.errCode == Int64(ErrCode.ANY_CAST)), true)
    }

    /** `is List<Any>` 答 1、`is List<Int64>` 答 0（集合外类型不报错）。 */
    @TestCase
    public func listIsHonoursElementType(): Unit {
        @Assert(AnyContainer_test.resultOf(
            '{ => let l: List<Any> = [1]\n let a: Any = l\n a is List<Any> }'), '1')
        @Assert(AnyContainer_test.resultOf(
            '{ => let l: List<Any> = [1]\n let a: Any = l\n a is List<Int64> }'), '0')
    }

    /** `as Map<String,Any>` 命中；值类型不是 Any ⇒ 22。 */
    @TestCase
    public func mapCastHonoursValueType(): Unit {
        let ok = AnyContainer_test.run(
            '{ => let m: Map<String, Any> = {}\n let a: Any = m\n let n = a as Map<String, Any>\n 0 }')
        @Assert(ok.errCode, 0)
        let bad = AnyContainer_test.run(
            '{ => let m: Map<String, Any> = {}\n let a: Any = m\n let n = a as Map<String, Int64>\n 0 }')
        @Assert(bad.errCode, Int64(ErrCode.ANY_CAST))
        @Assert(AnyContainer_test.resultOf(
            '{ => let m: Map<String, Any> = {}\n let a: Any = m\n a is Map<String, Int64> }'), '0')
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private static func compileM3(src: String): LoadedUnit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        FbcReader.load(sc.compile(src).raw)
    }

    private static func dumpOf(src: String): String {
        CodeDump.dump(LowererM2_test.entryBytes(AnyContainer_test.compileM3(src)))
    }

    private static func run(src: String): DiffOutcome {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        InterpRunner().run(DiffCase('T39/any-container', sc.compile(src).raw, Array<Any>()))
    }

    private static func resultOf(src: String): String {
        AnyContainer_test.run(src).result
    }

    private static func hasOperand(dump: String, needle: String): Bool {
        dump.contains(needle)
    }
}
