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
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.test.TCase
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.DiffOutcome
import fountain::f_jit.test.diff.InterpRunner

/**
 * M3 R3.10：JSON 内建码（16–19）**一等化**——形参 / 返回 / 局部 / 签名 / 可转集，
 * 全部零注册；含 JSON 形参的单元经「无注册表分发入口」加载**不拒**。
 */
@Test
public class JsonCode_test {

    /** 函数类型分量放开 16–19：`(JsonObject) -> Int64` 可作形参类型注解。 */
    @TestCase
    public func signatureComponentAcceptsJson(): Unit {
        let l = Parser('{ cb: (JsonObject) -> Int64 => 0 }').parseLambda()
        match (l.params[0].typeAnn) {
            case TypeRef.HostClosureT(ps, _, ret, _) =>
                @Assert(ps.size, 1)
                @Assert(ps[0], LocalType.JSON_OBJECT)
                @Assert(ret, LocalType.I64)
            case _ => @Fail('形参类型不是 HostClosureT')
        }
        // `JsonValue`（16）同样可作分量；非法分量仍是编译错误
        let l2 = Parser('{ cb: (JsonValue) -> JsonArray => 0 }').parseLambda()
        match (l2.params[0].typeAnn) {
            case TypeRef.HostClosureT(ps2, _, ret2, _) =>
                @Assert(ps2[0], LocalType.JSON_VALUE)
                @Assert(ret2, LocalType.JSON_ARRAY)
            case _ => @Fail('形参类型不是 HostClosureT')
        }
        @Assert(TCase.hit('T61/signature-json', true), true)
    }

    /** JSON 作形参 / 返回 / 局部：类型表逐槽落 17/18，单元可加载。 */
    @TestCase
    public func jsonCodeAppearsInTypeTable(): Unit {
        let src = '{ o: JsonObject => let a: JsonArray = `[]`\n 0 }'
        let unit = JsonCode_test.compileM3(src)
        @Assert(JsonCode_test.hasType(unit, 17u8), true)
        @Assert(JsonCode_test.hasType(unit, 18u8), true)
    }

    /** 无注册表分发入口：含 JSON 形参的单元**不拒**（对拍：含 14 的同类单元必拒）。 */
    @TestCase
    public func loadWithoutRegistryAcceptsJsonParams(): Unit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        let raw = sc.compile('{ o: JsonObject => 0 }').raw
        let unit = FbcReader.loadWithoutRegistry(raw)
        @Assert(unit.types[0].get(0), 17u8)
        @Assert(TCase.hit('T61/no-registry-json-ok', true), true)
    }

    /** `any_box(16–19, …)` 零注册：源级装箱后 `is` 命中，产物码就是 17。 */
    @TestCase
    public func anyBoxOverJsonNeedsNoRegistration(): Unit {
        let src = '{ => let x: Any = `{"a":1}`\n 0 }'
        let unit = JsonCode_test.compileM3(src)
        let d = CodeDump.dump(LowererM2_test.entryBytes(unit))
        @Assert(d.contains('CALL_HELPER 78,2'), true)
        @Assert(d.contains('PUSH_I64 17'), true)
        @Assert(JsonCode_test.resultOf('{ => let x: Any = `{"a":1}`\n x is JsonObject }'), '1')
        @Assert(TCase.hit('T61/any-box-json', true), true)
    }

    /** 可转集目标：`as JsonObject` / `as JsonArray` / `as JsonNull` 按码工作（码级继承 17 <: 16）。 */
    @TestCase
    public func jsonCodesAreCastTargets(): Unit {
        @Assert(JsonCode_test.resultOf('{ => let x: Any = `{"a":1}`\n (x as JsonObject)["a"] as Int64 }'),
            '1')
        @Assert(JsonCode_test.resultOf('{ => let x: Any = `[1]`\n x is JsonValue }'), '1')
        // 码级继承：数组不是对象 ⇒ 22
        let bad = JsonCode_test.run('{ => let x: Any = `[1]`\n (x as JsonObject)["a"] }')
        @Assert(bad.errCode, 22)
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private static func compileM3(src: String): LoadedUnit {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        FbcReader.load(sc.compile(src).raw)
    }

    private static func run(src: String): DiffOutcome {
        let sc = SourceCompiler(PredefinedSnapshot.empty(), DummyDiagnosticsSink(),
            verMajor: Version.M3_MAJOR)
        InterpRunner().run(DiffCase('T61/json-code', sc.compile(src).raw, Array<Any>()))
    }

    private static func resultOf(src: String): String {
        JsonCode_test.run(src).result
    }

    private static func hasType(unit: LoadedUnit, code: UInt8): Bool {
        for (t in unit.types) {
            for (i in 0..t.size) {
                if (t.get(i) == code) {
                    return true
                }
            }
        }
        false
    }
}
