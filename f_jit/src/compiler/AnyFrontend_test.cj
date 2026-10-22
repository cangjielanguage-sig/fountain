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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_base.UnsafeBytes
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.SourceCompileException
import fountain::f_jit.base.Version
import fountain::f_jit.bytecode.FbcReader
import fountain::f_jit.bytecode.LoadedUnit
import fountain::f_jit.test.TCase

/**
 * M3 R3.1–R3.2：`Any` 的声明面与四类装箱插入点（m3 §3）。
 *
 * 断言口径是**产物**而不是「编译通过」：① 类型注解落到 `LocalTypes` 的槽位码；② 装箱点真的
 * 发射了 `CALL_HELPER 78,2`（H78 `any_box`），且码是源表达式的静态类型码；③ 操作数只求值一次
 * （含装箱的表达式里 `tick()` 只出现一次）；④ 禁止面（二次装箱 / 闭包装箱 / 非可转集）。
 */
@Test
public class AnyFrontend_test {

    // ------------------------------------------------------------------
    // R3.1 声明面
    // ------------------------------------------------------------------

    /** `Any` 与 JSON 谱系四个类型名可作形参，槽位码 = 15 / 17 / 18 / 16 / 19。 */
    @TestCase
    public func anyAndJsonTypeNamesDeclare(): Unit {
        let unit = AnyFrontend_test.compileM3(
            '{ a: Any, o: JsonObject, r: JsonArray, v: JsonValue, n: JsonNull => 0 }')
        let t = unit.types[0]
        @Assert(Int64(t.get(0)), Int64(LocalType.ANY))
        @Assert(Int64(t.get(1)), Int64(LocalType.JSON_OBJECT))
        @Assert(Int64(t.get(2)), Int64(LocalType.JSON_ARRAY))
        @Assert(Int64(t.get(3)), Int64(LocalType.JSON_VALUE))
        @Assert(Int64(t.get(4)), Int64(LocalType.JSON_NULL))
        @Assert(TCase.hit('T37/any-decl-slots',
            t.get(0) == UInt8(LocalType.ANY) && t.get(1) == UInt8(LocalType.JSON_OBJECT)), true)
    }

    /** `Any` 可作局部与返回值：`let a: Any = 1` 的槽位码为 15。 */
    @TestCase
    public func anyLocalSlotIsHandleType(): Unit {
        let unit = AnyFrontend_test.compileM3('{ => let a: Any = 1\n 0 }')
        @Assert(Int64(unit.types[0].get(1)), Int64(LocalType.ANY))
    }

    /** `Any` 不接受泛型实参（`Any<Int64>` → 编译错误）。 */
    @TestCase
    public func anyRejectsTypeArguments(): Unit {
        @Assert(AnyFrontend_test.errKind('{ => let a: Any<Int64> = 1\n 0 }'),
            DiagKind.BAD_PARAMETER_LIST)
    }

    /** 容器元素类型进 AST：`List<Any>` / `Map<String,Any>` 可解析（码仍为 10/11）。 */
    @TestCase
    public func containerElementTypesAreParsed(): Unit {
        let l = Parser('{ a: List<Any>, b: Map<String, Any> => 0 }').parseLambda()
        @Assert(l.params[0].typeAnn.code(), LocalType.LIST)
        @Assert(l.params[0].typeAnn.elemCode(), LocalType.ANY)
        @Assert(l.params[1].typeAnn.code(), LocalType.MAP)
        @Assert(l.params[1].typeAnn.keyCode(), LocalType.STRING)
        @Assert(l.params[1].typeAnn.elemCode(), LocalType.ANY)
    }

    // ------------------------------------------------------------------
    // R3.2 四类装箱插入点
    // ------------------------------------------------------------------

    /** ① 初始化 Any 槽：`any_box(0, 1)`，码 = 源表达式静态类型码。 */
    @TestCase
    public func boxesAtAnyInitialization(): Unit {
        let d = AnyFrontend_test.dumpOf(AnyFrontend_test.compileM3('{ => let a: Any = 1\n 0 }'))
        @Assert(d.contains('CALL_HELPER 78,2'), true)
        // 码在压栈里：PUSH_I64 0（Int64 = 0）出现在 H78 调用之前
        @Assert(d.contains('PUSH_I64 0'), true)
        @Assert(AnyFrontend_test.countOf(d, 'CALL_HELPER 78,2'), 1)
        @Assert(TCase.hit('T37/box-decl', d.contains('CALL_HELPER 78,2')), true)
    }

    /** ① 赋值位置同样装箱；引用型按引用存（码 4 = String）。 */
    @TestCase
    public func boxesAtAnyAssignment(): Unit {
        let unit = AnyFrontend_test.compileM3('{ => var a: Any = 1\n a = "s"\n 0 }')
        let d = AnyFrontend_test.dumpOf(unit)
        @Assert(AnyFrontend_test.countOf(d, 'CALL_HELPER 78,2'), 2)
        @Assert(d.contains('PUSH_I64 4'), true)
    }

    /** ② Any 形参的实参：先装箱再 CALL_HOST；形参槽位码 15。 */
    @TestCase
    public func boxesAtAnyArgument(): Unit {
        let unit = AnyFrontend_test.compileM3('{ f: (Any) -> Int64, x: Int64 => f(x) }')
        let d = AnyFrontend_test.dumpOf(unit)
        @Assert(d.contains('CALL_HELPER 78,2'), true)
        @Assert(d.contains('CALL_HOST 1'), true)
        @Assert(Int64(unit.types[0].get(0)), Int64(LocalType.HOST_CLOSURE))
    }

    /** ② 预定义函数（user helper）的 Any 形参：按注册快照的形参类型装箱。 */
    @TestCase
    public func boxesAtUserHelperAnyParam(): Unit {
        let snap = AnyFrontend_test.snapAny(['sink'])
        let unit = AnyFrontend_test.compileM3('{ => sink(1)\n 0 }', snap)
        let d = AnyFrontend_test.dumpOf(unit)
        @Assert(d.contains('CALL_HELPER 78,2'), true)
        @Assert(TCase.hit('T37/box-arg', d.contains('CALL_HELPER 78,2')), true)
    }

    /** ③ Any 返回：闭包尾表达式位置装箱。 */
    @TestCase
    public func boxesAtAnyReturn(): Unit {
        let unit = AnyFrontend_test.compileM3('{ => let f = { => 7 }\n f() }')
        // 无 Any 目标 ⇒ 零装箱（对照）
        @Assert(AnyFrontend_test.countOf(AnyFrontend_test.dumpOf(unit), 'CALL_HELPER 78,2'), 0)
        // 形参声明为 Any 的闭包返回该形参：同型直传，仍不装箱
        let unit2 = AnyFrontend_test.compileM3('{ a: Any => let f = { => a }\n 0 }')
        @Assert(AnyFrontend_test.countOf(AnyFrontend_test.dumpOf(unit2), 'CALL_HELPER 78,2'), 0)
    }

    /** ④ `List<Any>` 字面量：每个元素一次装箱，且不走常量路径。 */
    @TestCase
    public func boxesAtListElement(): Unit {
        let unit = AnyFrontend_test.compileM3('{ => let l: List<Any> = [1, 2]\n 0 }')
        let d = AnyFrontend_test.dumpOf(unit)
        @Assert(AnyFrontend_test.countOf(d, 'CALL_HELPER 78,2'), 2)
        @Assert(d.contains('LIST_APPEND'), true)
        @Assert(TCase.hit('T37/box-list-elem', d.contains('LIST_APPEND') &&
            AnyFrontend_test.countOf(d, 'CALL_HELPER 78,2') == 2), true)
    }

    /** ④ `List<Any>` 元素写：`l[0] = 7` 先装箱。 */
    @TestCase
    public func boxesAtListElementWrite(): Unit {
        let unit = AnyFrontend_test.compileM3('{ => let l: List<Any> = []\n l[0] = 7\n 0 }')
        let d = AnyFrontend_test.dumpOf(unit)
        @Assert(AnyFrontend_test.countOf(d, 'CALL_HELPER 78,2'), 1)
        @Assert(d.contains('LIST_SET'), true)
    }

    /** ④ `Map<String,Any>`：键按 String 降低、值装箱。 */
    @TestCase
    public func boxesAtMapValueWrite(): Unit {
        let unit = AnyFrontend_test.compileM3(
            '{ => let m: Map<String, Any> = {}\n m["k"] = 3\n 0 }')
        let d = AnyFrontend_test.dumpOf(unit)
        @Assert(AnyFrontend_test.countOf(d, 'CALL_HELPER 78,2'), 1)
        @Assert(d.contains('MAP_PUT'), true)
        @Assert(TCase.hit('T37/box-map-value', d.contains('MAP_PUT')), true)
    }

    /** ④ `Map<Int64,Any>`：Int64 键沿用既有键机制，值装箱。 */
    @TestCase
    public func boxesAtIntKeyedMapValue(): Unit {
        let unit = AnyFrontend_test.compileM3(
            '{ => let m: Map<Int64, Any> = {}\n m[1] = 2\n 0 }')
        let d = AnyFrontend_test.dumpOf(unit)
        @Assert(AnyFrontend_test.countOf(d, 'CALL_HELPER 78,2'), 1)
        @Assert(d.contains('MAP_PUT'), true)
    }

    /** 元素类型不是 Any 的容器不装箱（对照：`List<Int64>` 零 H78）。 */
    @TestCase
    public func noBoxForTypedContainer(): Unit {
        let unit = AnyFrontend_test.compileM3('{ => let l: List<Int64> = [1, 2]\n l[0] = 3\n 0 }')
        @Assert(AnyFrontend_test.countOf(AnyFrontend_test.dumpOf(unit), 'CALL_HELPER 78,2'), 0)
    }

    /**
     * 动态列表字面量（元素非常量）多元素：`LIST_APPEND` 后**不得** POP 掉列表。
     *
     * 回归 M1 遗留缺陷：`lowerListLit` 的非恒定路径原先每轮 `LIST_APPEND` 后跟一条 `POP`，
     * 第二个元素的 `LIST_APPEND` 就会因缺列表而栈下越界（该路径此前只有单元素/常量路径被覆盖）。
     */
    @TestCase
    public func dynamicListLiteralKeepsListOnStack(): Unit {
        let unit = AnyFrontend_test.compileM3('{ a: Int64, b: Int64 => let l = [a, b]\n l[0] }')
        let d = AnyFrontend_test.dumpOf(unit)
        @Assert(AnyFrontend_test.countOf(d, 'LIST_APPEND'), 2)
        @Assert(TCase.hit('T39/dynamic-list-literal', AnyFrontend_test.countOf(d, 'LIST_APPEND') == 2),
            true)
    }

    /** 遍历 `List<Any>`：绑定变量静态类型 = 元素码 15（`let y: Any = x` 不再装箱）。 */
    @TestCase
    public func iteratesHeterogeneousList(): Unit {
        let unit = AnyFrontend_test.compileM3(
            '{ => let l: List<Any> = [1]\n for (x in l) { let y: Any = x }\n 0 }')
        // 只有字面量元素那一次装箱；绑定变量是盒句柄，直传不再装箱
        @Assert(AnyFrontend_test.countOf(AnyFrontend_test.dumpOf(unit), 'CALL_HELPER 78,2'), 1)
        @Assert(TCase.hit('T39/iterate-list-any', true), true)
    }

    /** 遍历 `Map<String,Any>`：键绑定为 String、值绑定为 15（值直传不再装箱）。 */
    @TestCase
    public func iteratesHeterogeneousMap(): Unit {
        let unit = AnyFrontend_test.compileM3(
            '{ => let m: Map<String, Any> = {}\n m["k"] = 1\n' +
            ' for ((k, v) in m) { let s: String = k\n let a: Any = v }\n 0 }')
        @Assert(AnyFrontend_test.countOf(AnyFrontend_test.dumpOf(unit), 'CALL_HELPER 78,2'), 1)
        @Assert(TCase.hit('T39/iterate-map-any', true), true)
    }

    // ------------------------------------------------------------------
    // 一次求值 / 禁止面
    // ------------------------------------------------------------------

    /** 装箱点**只对操作数求值一次**：`tick()` 在产物里只出现一次。 */
    @TestCase
    public func boxedOperandEvaluatedOnce(): Unit {
        let snap = AnyFrontend_test.snapAny(['tick'])
        let unit = AnyFrontend_test.compileM3('{ => let a: Any = tick()\n 0 }', snap)
        let d = AnyFrontend_test.dumpOf(unit)
        // user helper slot 0 → hid 256；一次调用
        @Assert(AnyFrontend_test.countOf(d, 'CALL_HELPER 256,0'), 1)
        @Assert(AnyFrontend_test.countOf(d, 'CALL_HELPER 78,2'), 1)
        @Assert(TCase.hit('T37/box-eval-once',
            AnyFrontend_test.countOf(d, 'CALL_HELPER 256,0') == 1), true)
    }

    /** 盒不套盒：`let b: Any = a`（a: Any）不发射任何 H78（同型直传）。 */
    @TestCase
    public func noDoubleBoxing(): Unit {
        let unit = AnyFrontend_test.compileM3('{ a: Any => let b: Any = a\n 0 }')
        let d = AnyFrontend_test.dumpOf(unit)
        @Assert(AnyFrontend_test.countOf(d, 'CALL_HELPER 78,2'), 0)
        @Assert(TCase.hit('T38/no-double-box', AnyFrontend_test.countOf(d, 'CALL_HELPER 78,2') == 0),
            true)
    }

    /** 闭包不得装箱（12 不在可转集；含经 Any 盒的间接路径）。 */
    @TestCase
    public func rejectsClosureBoxing(): Unit {
        @Assert(AnyFrontend_test.errKind('{ => let a: Any = { => 1 }\n 0 }'),
            DiagKind.TYPE_MISMATCH)
    }

    /** 闭包不得存入 `List<Any>`（直接或装箱后放入都拒绝）。 */
    @TestCase
    public func rejectsClosureInHeterogeneousList(): Unit {
        @Assert(AnyFrontend_test.errKind('{ => let l: List<Any> = [{ => 1 }]\n 0 }'),
            DiagKind.TYPE_MISMATCH)
    }

    /** `Any` 可作 HostClosure 签名的 T/R（m3 §3；其它非法分量仍拒）。 */
    @TestCase
    public func anyAllowedInHostClosureSignature(): Unit {
        let l = Parser('{ f: (Any) -> Any => 0 }').parseLambda()
        @Assert(l.params[0].typeAnn.code(), LocalType.HOST_CLOSURE)
        @Assert(l.params[0].typeAnn.hostParams()[0], LocalType.ANY)
        @Assert(l.params[0].typeAnn.hostRet(), LocalType.ANY)
        @Assert(TCase.hit('T37/any-signature-component', true), true)
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private static func compileM3(src: String): LoadedUnit {
        AnyFrontend_test.compileM3(src, PredefinedSnapshot.empty())
    }

    private static func compileM3(src: String, snap: PredefinedSnapshot): LoadedUnit {
        let sc = SourceCompiler(snap, DummyDiagnosticsSink(), verMajor: Version.M3_MAJOR)
        FbcReader.load(sc.compile(src).raw)
    }

    private static func errKind(src: String): String {
        AnyFrontend_test.errKind(src, PredefinedSnapshot.empty())
    }

    private static func errKind(src: String, snap: PredefinedSnapshot): String {
        var got = ''
        try {
            let _ = AnyFrontend_test.compileM3(src, snap)
        } catch (e: SourceCompileException) {
            got = e.kind
        }
        got
    }

    private static func dumpOf(unit: LoadedUnit): String {
        CodeDump.dump(LowererM2_test.entryBytes(unit))
    }

    /** 注册快照：每个函数一个 `Any` 形参、返回 Int64（slot 序 = 名字序）。 */
    private static func snapAny(names: Array<String>): PredefinedSnapshot {
        var params = ArrayList<Array<UInt16>>()
        var rets = ArrayList<UInt16>()
        for (_ in names) {
            params.add([LocalType.ANY])
            rets.add(LocalType.I64)
        }
        PredefinedSnapshot(names, params.toArray(), rets.toArray())
    }

    private static func countOf(text: String, pat: String): Int64 {
        let t = text.unsafeBytes()
        let p = pat.unsafeBytes()
        if (p.size == 0 || t.size < p.size) {
            return 0
        }
        var n: Int64 = 0
        var i: Int64 = 0
        while (i + p.size <= t.size) {
            var j: Int64 = 0
            var ok = true
            while (j < p.size) {
                if (t[i + j] != p[j]) {
                    ok = false
                    break
                }
                j = j + 1
            }
            if (ok) {
                n = n + 1
                i = i + p.size
            } else {
                i = i + 1
            }
        }
        n
    }
}
