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
import fountain::f_jit.base.ClassDescriptor
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit

/**
 * A2.4（D1）：14 目标的 `aux` = `$as$<C>` 的 16 位 helper id。
 *
 * 前端不再为 14 恒发 `0xFFFF`：H79/H80 靠这个 id 找到注册期合成的 `(14) -> Bool`
 * 判定体，类界才成立。`0xFFFF` 只保留给「拿不到类名」与其余类型码。
 *
 * 用快照里手工登记的 `$as$Foo` 槽（slot 0 ⇒ hid 256）断言产物；真实注册类的端到端
 * 一致性由根包 `AnyHostCast_test` 覆盖。
 */
@Test
public class AnyCastAux_test {

    /** `as Foo` / `is Foo`（左值 15）的 aux = 256，而不是 65535。 */
    @TestCase
    public func p1_4_auxCarriesAsHelperId(): Unit {
        let snap = AnyCastAux_test.snapAs('$as$Foo')
        let dAs = AnyCastAux_test.dumpOf('{ a: Any => a as Foo }', snap)
        @Assert(dAs.contains('CALL_HELPER 80,3'), true)
        @Assert(dAs.contains('PUSH_I64 256'), true)
        @Assert(dAs.contains('PUSH_I64 65535'), false)
        let dIs = AnyCastAux_test.dumpOf('{ a: Any => a is Foo }', snap)
        @Assert(dIs.contains('CALL_HELPER 79,3'), true)
        @Assert(dIs.contains('PUSH_I64 256'), true)
        @Assert(dIs.contains('PUSH_I64 65535'), false)
    }

    /** 非 14 目标（值型 / JSON）的 aux 编码不变。 */
    @TestCase
    public func p1_4_nonHostTargetsKeepMaxAux(): Unit {
        let snap = AnyCastAux_test.snapAs('$as$Foo')
        let dVal = AnyCastAux_test.dumpOf('{ a: Any => a as Int64 }', snap)
        @Assert(dVal.contains('PUSH_I64 65535'), true)
        let dJson = AnyCastAux_test.dumpOf('{ a: Any => a as JsonObject }', snap)
        @Assert(dJson.contains('PUSH_I64 65535'), true)
    }

    /** `$as$<C>` 槽缺失 ⇒ 编译错误（不拖到运行期变成 8/22）。 */
    @TestCase
    public func p1_4_missingAsHelperIsCompileError(): Unit {
        @Assert(AnyCastAux_test.errKind('{ a: Any => a as Foo }', PredefinedSnapshot.empty()),
            DiagKind.TYPE_MISMATCH)
        @Assert(AnyCastAux_test.errKind('{ a: Any => a is Foo }', PredefinedSnapshot.empty()),
            DiagKind.TYPE_MISMATCH)
        @Assert(AnyCastAux_test.errText('{ a: Any => a as Foo }', PredefinedSnapshot.empty())
            .contains('Foo'), true)
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private static func snapAs(name: String): PredefinedSnapshot {
        PredefinedSnapshot([name], [[LocalType.HOST_OBJECT]], [LocalType.BOOL])
    }

    /**
     * `Foo` 必须同时出现在**类快照**（Parser 的类型名白名单）与预定义快照（`$as$Foo` 槽）。
     * 类表只放一个空描述符：本用例不碰成员解析。
     */
    private static func compile(src: String, snap: PredefinedSnapshot): LoadedUnit {
        let classes = ClassRegistrySnapshot([ClassDescriptor(name: 'Foo', fields: [],
            methods: [], ctors: [])])
        let sc = SourceCompiler(snap, DummyDiagnosticsSink(), verMajor: Version.M3_MAJOR,
            classes: classes)
        FbcReader.load(sc.compile(src).raw)
    }

    private static func dumpOf(src: String, snap: PredefinedSnapshot): String {
        CodeDump.dump(LowererM2_test.entryBytes(AnyCastAux_test.compile(src, snap)))
    }

    private static func errKind(src: String, snap: PredefinedSnapshot): String {
        var got = ''
        try {
            let _ = AnyCastAux_test.compile(src, snap)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    private static func errText(src: String, snap: PredefinedSnapshot): String {
        var got = ''
        try {
            let _ = AnyCastAux_test.compile(src, snap)
        } catch (e: SourceCompileException) {
            got = e.message
        }
        got
    }
}
