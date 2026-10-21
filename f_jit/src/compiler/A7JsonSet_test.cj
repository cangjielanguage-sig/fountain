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
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.InterpRunner

/**
 * A7.3（P3-3）：`json_set` 的值域在**规格 / 前端 / 运行期**三处一致。
 *
 * 裁定：收窄为 `Int64 / Bool / String / JSON 节点`，**Float64 编译期拒绝**（JSON 无二进制浮点）。
 * 旧实现前端放行 Float64、运行期 `jsonValueOf` 无分支 ⇒ 运行期 8，是规格外的第三态。
 */
@Test
public class A7JsonSet_test {

    @TestCase
    public func p3_3_jsonSetFloat64RejectedAtCompileTime(): Unit {
        let msg = A7JsonSet_test.errText(
            '{ => let o: JsonObject = `{}`\n let x = 1.5f64\n o["k"] = x }')
        @Assert(msg.contains('Float64'), true)
        @Assert(msg.contains('不在值域内'), true)
        @Assert(msg.contains('JSON 无二进制浮点'), true)
        // Decimal 字面量同样不在值域（旧实现同样在运行期以 8 失败）
        @Assert(A7JsonSet_test.errKind('{ => let o: JsonObject = `{}`\n o["k"] = 2.5 }'),
            DiagKind.TYPE_MISMATCH)
    }

    /** 值域内三种值可写可读：Int64 / Bool / String。 */
    @TestCase
    public func p3_3_jsonSetAcceptsValueDomain(): Unit {
        @Assert(A7JsonSet_test.resultOf(
            '{ => let o: JsonObject = `{}`\n o["k"] = 7\n (o["k"] as Int64) }'), '7')
        @Assert(A7JsonSet_test.resultOf(
            '{ => let o: JsonObject = `{}`\n o["k"] = true\n (o["k"] as Bool) }'), '1')
        @Assert(A7JsonSet_test.resultOf(
            '{ => let o: JsonObject = `{}`\n o["k"] = "s"\n (o["k"] as String) }'), 's')
    }

    private static func compile(src: String): Unit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        let _ = FbcReader.load(sc.compile(src).raw)
    }

    private static func errKind(src: String): String {
        var got = ''
        try {
            A7JsonSet_test.compile(src)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    private static func errText(src: String): String {
        var got = ''
        try {
            A7JsonSet_test.compile(src)
        } catch (e: SourceCompileException) {
            got = e.message
        }
        got
    }

    private static func resultOf(src: String): String {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        InterpRunner().run(DiffCase('A7/json-set', sc.compile(src).raw, Array<Any>())).result
    }
}
