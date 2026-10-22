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
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.runtime.UserHelperEntry
import fountain::f_jit.runtime.UserHelperTable
import fountain::f_jit.test.TCase
import fountain::f_jit.test.diff.DiffCase
import fountain::f_jit.test.diff.DiffOutcome
import fountain::f_jit.test.diff.InterpRunner

/**
 * M3 R3.9：JSON 访问语法糖与自动收窄（m3 §11）。
 *
 * 口径：
 * - 读 = `json_get`（H81），结果**恒为 15 盒**；写 = `json_set`（H82），值域编译期断言；
 * - 点号 = **成员优先 → 键兜底**，未命中成员时与 `o['k']` 逐位等价；
 * - 链式自动收窄：15 盒走 H80、16（`JsonValue`）先装箱再 H80，中间值不符一律 **22**；
 * - 静态已知具体类（18 / 19 / 标量）上取键 = 编译错误。
 */
@Test
public class JsonAccess_test {

    // ------------------------------------------------------------------
    // 下标读（按接收者静态类型分派）
    // ------------------------------------------------------------------

    /** `o["a"]`：JsonObject 收 String 键，结果 15 盒，`as Int64` 取值。 */
    @TestCase
    public func readsObjectKeyByIndex(): Unit {
        let src = '{ => let o: JsonObject = `{"a":1}`\n o["a"] as Int64 }'
        @Assert(JsonAccess_test.resultOf(src), '1')
        @Assert(TCase.hit('T61/json-get-object', JsonAccess_test.resultOf(src) == '1'), true)
    }

    /** `a[1]`：JsonArray 收 Int64 下标。 */
    @TestCase
    public func readsArrayElementByIndex(): Unit {
        let src = '{ => let a: JsonArray = `[1,2]`\n a[1] as Int64 }'
        @Assert(JsonAccess_test.resultOf(src), '2')
    }

    /** 缺键 → 5 KEY_MISSING；越界 → 4 IDX_OOB。 */
    @TestCase
    public func readFailuresUseJsonCodes(): Unit {
        let miss = JsonAccess_test.run('{ => let o: JsonObject = `{"a":1}`\n o["b"] }')
        @Assert(miss.errCode, Int64(ErrCode.KEY_MISSING))
        let oob = JsonAccess_test.run('{ => let a: JsonArray = `[1]`\n a[3] }')
        @Assert(oob.errCode, Int64(ErrCode.IDX_OOB))
    }

    // ------------------------------------------------------------------
    // 点号读：成员优先 → 键兜底
    // ------------------------------------------------------------------

    /** `o.a` 与 `o["a"]` 读到同一个值。 */
    @TestCase
    public func dotReadEqualsIndexRead(): Unit {
        let dot = '{ => let o: JsonObject = `{"a":7}`\n o.a as Int64 }'
        let idx = '{ => let o: JsonObject = `{"a":7}`\n o["a"] as Int64 }'
        @Assert(JsonAccess_test.resultOf(dot), '7')
        @Assert(JsonAccess_test.resultOf(idx), '7')
        @Assert(TCase.hit('T61/dot-eq-index', true), true)
    }

    /** 点号写 `o.k = v` 与下标写 `o['k'] = v` 逐位等价（写后读回一致）。 */
    @TestCase
    public func dotWriteEqualsIndexWrite(): Unit {
        let dot = '{ => let o: JsonObject = `{}`\n o.k = 5\n o["k"] as Int64 }'
        let idx = '{ => let o: JsonObject = `{}`\n o["k"] = 5\n o.k as Int64 }'
        @Assert(JsonAccess_test.resultOf(dot), '5')
        @Assert(JsonAccess_test.resultOf(idx), '5')
    }

    /** 写入 JSON 节点（码 16–19）合法：`o.n = `{...}`` 后仍可按链读。 */
    @TestCase
    public func writesJsonNodeValue(): Unit {
        let src = '{ => let o: JsonObject = `{}`\n o.n = `{"x":1}`\n o.n.x as Int64 }'
        @Assert(JsonAccess_test.resultOf(src), '1')
    }

    /** 值域之外（List）→ 编译错误（m3 §11 值域断言）。 */
    @TestCase
    public func writeRejectsNonJsonValue(): Unit {
        @Assert(JsonAccess_test.errKind('{ => let o: JsonObject = `{}`\n o.k = [1] }'),
            DiagKind.TYPE_MISMATCH)
        // Any 盒也不在值域内：先 `as` 成具体类型
        @Assert(JsonAccess_test.errKind(
            '{ => let o: JsonObject = `{}`\n let a: Any = 1\n o.k = a }'), DiagKind.TYPE_MISMATCH)
        @Assert(TCase.hit('T61/write-value-domain', true), true)
    }

    // ------------------------------------------------------------------
    // 链式自动收窄
    // ------------------------------------------------------------------

    /** `o.a.b` ≡ `(o['a'] as JsonObject)['b']`。 */
    @TestCase
    public func chainNarrowsAutomatically(): Unit {
        let src = '{ => let o: JsonObject = `{"a":{"b":5}}`\n o.a.b as Int64 }'
        @Assert(JsonAccess_test.resultOf(src), '5')
        @Assert(TCase.hit('T61/chain-narrow', JsonAccess_test.resultOf(src) == '5'), true)
    }

    /** 混链 `o.a[0].b`、`o.a["k"]`：下标按索引静态类型选目标类。 */
    @TestCase
    public func mixedChainsNarrowByIndexType(): Unit {
        let a = '{ => let o: JsonObject = `{"a":[{"b":9}]}`\n o.a[0].b as Int64 }'
        let b = '{ => let o: JsonObject = `{"a":{"k":3}}`\n o.a["k"] as Int64 }'
        @Assert(JsonAccess_test.resultOf(a), '9')
        @Assert(JsonAccess_test.resultOf(b), '3')
    }

    /** 16（`JsonValue`）作接收者：先收窄到具体类再访问（写侧对称）。 */
    @TestCase
    public func jsonValueReceiverNarrows(): Unit {
        let read = '{ => let v: JsonValue = `{"k":4}`\n v.k as Int64 }'
        let write = '{ => let v: JsonValue = `{}`\n v.k = 6\n v["k"] as Int64 }'
        @Assert(JsonAccess_test.resultOf(read), '4')
        @Assert(JsonAccess_test.resultOf(write), '6')
    }

    /** 15 盒作接收者：`x.k` 自动 `as JsonObject`（禁止面的例外，m3 §3）。 */
    @TestCase
    public func anyBoxReceiverIsJsonSugar(): Unit {
        let src = '{ => let x: Any = `{"k":8}`\n x.k as Int64 }'
        @Assert(JsonAccess_test.resultOf(src), '8')
    }

    /** 中间值不是对象 ⇒ **22**（ANY_CAST），不是 8 / 5。 */
    @TestCase
    public func chainMismatchFailsWith22(): Unit {
        let out = JsonAccess_test.run('{ => let o: JsonObject = `{"a":1}`\n o.a.b as Int64 }')
        @Assert(out.errCode, Int64(ErrCode.ANY_CAST))
        @Assert(TCase.hit('T61/chain-mismatch-22', out.errCode == Int64(ErrCode.ANY_CAST)), true)
    }

    /** 深链写：中间节点由空字面量构造（可变、非 frozen）⇒ 写成功。 */
    @TestCase
    public func deepChainWrite(): Unit {
        let src = '{ => let o: JsonObject = `{}`\n o.a = `{}`\n o.a.b = 1\n o.a.b as Int64 }'
        @Assert(JsonAccess_test.resultOf(src), '1')
    }

    // ------------------------------------------------------------------
    // frozen 传播（常量写路径）
    // ------------------------------------------------------------------

    /** 非空字面量是常量（frozen）⇒ 写 → 20 READONLY；空字面量可写，越界仍是 4。 */
    @TestCase
    public func frozenConstantRejectsWrite(): Unit {
        let ro = JsonAccess_test.run('{ => let a: JsonArray = `[1,2]`\n a[0] = 9\n 0 }')
        @Assert(ro.errCode, Int64(ErrCode.READONLY))
        let oob = JsonAccess_test.run('{ => let a: JsonArray = `[]`\n a[0] = 1\n 0 }')
        @Assert(oob.errCode, Int64(ErrCode.IDX_OOB))
    }

    // ------------------------------------------------------------------
    // 负向面：静态已知具体类
    // ------------------------------------------------------------------

    /** `arr.k` / `arr["k"]` / `obj[0]` / `n["k"]` 全部编译错误。 */
    @TestCase
    public func staticConcreteNegatives(): Unit {
        @Assert(JsonAccess_test.errKind('{ => let a: JsonArray = `[1]`\n a.k }'),
            DiagKind.TYPE_MISMATCH)
        @Assert(JsonAccess_test.errKind('{ => let a: JsonArray = `[1]`\n a["k"] }'),
            DiagKind.TYPE_MISMATCH)
        @Assert(JsonAccess_test.errKind('{ => let o: JsonObject = `{}`\n o[0] }'),
            DiagKind.TYPE_MISMATCH)
        @Assert(JsonAccess_test.errKind(
            '{ => let o: JsonObject = `{"a":null}`\n let n = o.a as JsonNull\n n["k"] }'),
            DiagKind.TYPE_MISMATCH)
        @Assert(TCase.hit('T61/static-negatives', true), true)
    }

    /** 索引类型判不出 ⇒ 编译错误（不猜目标类）。 */
    @TestCase
    public func unknownIndexTypeIsRejected(): Unit {
        let src = '{ => let o: JsonObject = `{"a":1}`\n let k = o\n o[k] }'
        @Assert(JsonAccess_test.errKind(src), DiagKind.TYPE_MISMATCH)
    }

    // ------------------------------------------------------------------
    // 成员优先（预定义函数通道 = JSON 成员表）
    // ------------------------------------------------------------------

    /** `o.size()` 命中成员（≡ `size(o)`，CALL_HELPER 0x0100+slot）；`o['size']` 仍取键。 */
    @TestCase
    public func memberWinsOverKey(): Unit {
        let src = '{ => let o: JsonObject = `{"size":7}`\n o.size() }'
        let unit = JsonAccess_test.compileM3(src, JsonAccess_test.snapSize())
        let d = CodeDump.dump(LowererM2_test.entryBytes(unit))
        @Assert(d.contains('CALL_HELPER 256,1'), true)
        @Assert(JsonAccess_test.runWithSize('{ => let o: JsonObject = `{"size":7}`\n o.size() }'), '42')
        @Assert(JsonAccess_test.resultOf(
            '{ => let o: JsonObject = `{"size":7}`\n o["size"] as Int64 }'), '7')
        @Assert(TCase.hit('T61/member-first', true), true)
    }

    /** 成员命中时**裸成员名不给值**（成员是函数）；点号写同样不可（取键写用 `['k']`）。 */
    @TestCase
    public func bareMemberNameIsRejected(): Unit {
        @Assert(JsonAccess_test.errKind('{ => let o: JsonObject = `{"size":7}`\n o.size }',
            JsonAccess_test.snapSize()), DiagKind.TYPE_MISMATCH)
        @Assert(JsonAccess_test.errKind('{ => let o: JsonObject = `{}`\n o.size = 1 }',
            JsonAccess_test.snapSize()), DiagKind.TYPE_MISMATCH)
    }

    /** 成员表为空时 `o.k()` → 编译错误（提示改用键访问）。 */
    @TestCase
    public func unknownMemberCallIsRejected(): Unit {
        @Assert(JsonAccess_test.errKind('{ => let o: JsonObject = `{}`\n o.k() }'),
            DiagKind.TYPE_MISMATCH)
    }

    // ------------------------------------------------------------------
    // JSON 谱系不可类构造
    // ------------------------------------------------------------------

    // `registerType<JsonObject>()` → `RegistrationException(kind=JsonFamily)` 已在根包
    // `ReflectRegistrar_test.jsonFamilyIsRejected` 覆盖（compiler 不能反向依赖根包）。

    /** `JsonObject()` 类构造写法 → 编译错误（构造只能经空字面量或宿主解析器）。 */
    @TestCase
    public func jsonClassConstructionIsRejected(): Unit {
        @Assert(JsonAccess_test.errText('{ => JsonObject() }').contains('JsonObject'), true)
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private static func compileM3(src: String): LoadedUnit {
        JsonAccess_test.compileM3(src, PredefinedSnapshot.empty())
    }

    private static func compileM3(src: String, snap: PredefinedSnapshot): LoadedUnit {
        let sc = SourceCompiler(snap, DummyDiagnosticsSink(), verMajor: Version.M3_MAJOR)
        FbcReader.load(sc.compile(src).raw)
    }

    private static func run(src: String): DiffOutcome {
        JsonAccess_test.run(src, PredefinedSnapshot.empty())
    }

    private static func run(src: String, snap: PredefinedSnapshot): DiffOutcome {
        let sc = SourceCompiler(snap, DummyDiagnosticsSink(), verMajor: Version.M3_MAJOR)
        InterpRunner().run(DiffCase('T61/json-access', sc.compile(src).raw, Array<Any>()))
    }

    private static func resultOf(src: String): String {
        JsonAccess_test.run(src).result
    }

    private static func resultOf(src: String, snap: PredefinedSnapshot): String {
        JsonAccess_test.run(src, snap).result
    }

    /** 成员表快照：`size(JsonObject): Int64`（首参 ∈ 16–19 ⇒ 成员名 = 函数名）。 */
    private static func snapSize(): PredefinedSnapshot {
        PredefinedSnapshot(['size'], [[LocalType.JSON_OBJECT]], [LocalType.I64],
            impls: [JsonAccess_test.sizeImpl()])
    }

    private static func sizeImpl(): (Array<Any>) -> Any {
        { a => let _ = a
            42 }
    }

    /** 执行期装配 user helper（解释器不自带宿主实现表）。 */
    private static func runWithSize(src: String): String {
        UserHelperTable.push(0u16, [UserHelperEntry(params: [LocalType.JSON_OBJECT],
            ret: LocalType.I64, impl: JsonAccess_test.sizeImpl())])
        try {
            return JsonAccess_test.resultOf(src, JsonAccess_test.snapSize())
        } finally {
            UserHelperTable.pop()
        }
    }

    private static func errKind(src: String): String {
        JsonAccess_test.errKind(src, PredefinedSnapshot.empty())
    }

    private static func errKind(src: String, snap: PredefinedSnapshot): String {
        var got = ''
        try {
            let _ = JsonAccess_test.compileM3(src, snap)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    private static func errText(src: String): String {
        var got = ''
        try {
            let _ = JsonAccess_test.compileM3(src)
        } catch (e: SourceCompileException) {
            got = e.message
        }
        got
    }
}
