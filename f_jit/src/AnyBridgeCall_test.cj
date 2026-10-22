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

import std.time.DateTime
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.{JsonArray, JsonNull, JsonObject, JsonValue}
import fountain::f_jit.base.CallContext
import fountain::f_jit.base.DummyDiagnosticsSink
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.InterruptedException
import fountain::f_jit.base.JitException
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.RuntimeEnv
import fountain::f_jit.test.ReflectUser

/**
 * A3 根包验收：桥的入参/出参与调用入口。
 *
 * - P0-2：`CallMarshal` 的「类型名 → LocalType」表缺 15 与 16–19 ⇒ `call<Any>` / `call<Json*>`
 *   恒报「T 不是可解包类型」；本文件用**真实返回 Any / JSON 的单元**验证宿侧可达与无泄漏。
 * - P0-6：`CallContext.deadline` 原无消费点 ⇒ `−2 INTERRUPT` 生产不可达；本文件验证
 *   过期期限在 `LOOP_BACK` 处变成 `InterruptedException`，且调用后期限**栈式恢复**。
 * - A3.4：`invoke(args, CallContext())` 与 `call(args)` 的结果 / 错误码 / site 逐位一致。
 * - A3.5：桥层不改变除法语义（严格浮点已归位 `CompileOptions`）。
 */
@Test
public class AnyBridgeCall_test {

    private static func compiler(): Compiler {
        Compiler(CompileOptions(DummyDiagnosticsSink()))
    }

    /** `call<Any>`：值型取回原生值、引用型取回同一对象；200 次调用不泄漏槽。 */
    @TestCase
    public func p0_2_callAnyIsReachable(): Unit {
        let c = AnyBridgeCall_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ x: Any => x }')
        match (f.call<Any>([Int64(42)])) {
            case n: Int64 => @Assert(n, 42)
            case _ => @Fail('Any 返回不是原生 Int64（盒句柄被当成值交回宿主）')
        }
        let u = ReflectUser('bob', 7)
        match (f.call<Any>([u])) {
            case got: ReflectUser =>
                @Assert(got.name, 'bob')
                @Assert(got.id, 7)
            case _ => @Fail('Any 返回丢失了原对象类型')
        }
        let before = HandleTable.liveCount()
        var i = 0
        while (i < 200) {
            let _ = f.call<Any>([Int64(i)])
            i = i + 1
        }
        @Assert(HandleTable.liveCount(), before)
    }

    /** `call<JsonObject>` / `call<JsonArray>` / `call<JsonValue>`：返回节点本身（tag 11 例外行）。 */
    @TestCase
    public func p0_2_callJsonReturnsAreReachable(): Unit {
        let c = AnyBridgeCall_test.compiler()
        CompileCache.reset()
        let o = c.compile('{ => `{"k":1}` }')
        let obj = o.call<JsonObject>([])
        @Assert(obj.toJsonString().contains('"k"'), true)
        let a = c.compile('{ => `[1,2]` }')
        @Assert(a.call<JsonArray>([]).size, 2)
        let v = c.compile('{ => let x: JsonValue = `{"k":1}`\n x }')
        @Assert(v.call<JsonValue>([]).toJsonString().contains('"k"'), true)
        // 资源：JSON 返回同样是「逃逸 → 取回 → 归还」，多次调用表长不增长
        let before = HandleTable.liveCount()
        var i = 0
        while (i < 200) {
            let _ = o.call<JsonObject>([])
            i = i + 1
        }
        @Assert(HandleTable.liveCount(), before)
    }

    /**
     * `JsonNull` 映射存在：对 17 型返回单元用 `call<JsonNull>` 必须报「T 与返回类型不符」，
     * 而不是「T 不是可解包类型」（后者说明类型名表仍缺 19）。
     */
    @TestCase
    public func p0_2_jsonNullMappingExists(): Unit {
        let c = AnyBridgeCall_test.compiler()
        CompileCache.reset()
        let o = c.compile('{ => `{"k":1}` }')
        var msg = ''
        var code: Int64 = -1
        try {
            let _ = o.call<JsonNull>([])
        } catch (e: JitException) {
            code = e.code
            msg = e.message
        }
        @Assert(code, ErrCode.CALL_CONTRACT)
        @Assert(msg.contains('T 与返回类型不符'), true)
        @Assert(msg.contains('不是可解包类型'), false)
    }

    /** P0-6：过期 `deadline` 在循环回边处返回 −2 ⇒ `InterruptedException`。 */
    @TestCase
    public func p0_6_deadlineInterruptsLoop(): Unit {
        let c = AnyBridgeCall_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ n: Int64 => var i = 0\n while (i < n) { i = i + 1 }\n i }')
        // 无期限：正常完成
        @Assert(f.call<Int64>([Int64(10)]), 10)
        let opts = CallContext(deadline: Some(DateTime.UnixEpoch))
        var interrupted = false
        try {
            let _ = f.call<Int64>([Int64(100000000)], opts)
        } catch (_: InterruptedException) {
            interrupted = true
        }
        @Assert(interrupted, true)
    }

    /** P0-6：期限是栈式的——内层调用（成功或中断）返回后，外层期限原样恢复。 */
    @TestCase
    public func p0_6_deadlineRestoredAfterCall(): Unit {
        let c = AnyBridgeCall_test.compiler()
        CompileCache.reset()
        let f = c.compile('{ n: Int64 => var i = 0\n while (i < n) { i = i + 1 }\n i }')
        let expired = CallContext(deadline: Some(DateTime.UnixEpoch))
        // 外层无期限：内层中断后必须回到 −1
        RuntimeEnv.clearDeadline()
        try {
            let _ = f.call<Int64>([Int64(100000000)], expired)
        } catch (_: InterruptedException) {}
        @Assert(RuntimeEnv.deadlineNanos, -1)
        // 外层有期限：内层成功返回后必须回到外层值
        RuntimeEnv.setDeadline(12345)
        @Assert(f.call<Int64>([Int64(3)], CallContext()), 3)
        @Assert(RuntimeEnv.deadlineNanos, 12345)
        RuntimeEnv.clearDeadline()
    }

    /** A3.4：`invoke(args, CallContext())` 与 `call(args)` 的结果 / 错误码 / site 完全一致。 */
    @TestCase
    public func a3_4_invokeMatchesCall(): Unit {
        let c = AnyBridgeCall_test.compiler()
        CompileCache.reset()
        let ok = c.compile('{ x: Int64 => x + 1 }')
        @Assert(ok.call<Int64>([Int64(41)], CallContext()), ok.call<Int64>([Int64(41)]))
        let bad = c.compile('{ x: Int64 => 100 / x }')
        var ic = 0
        var invokeSite: Int64 = -2
        var cc = 0
        var callSite: Int64 = -2
        try {
            let _ = bad.call<Int64>([Int64(0)], CallContext())
        } catch (e: JitException) {
            ic = e.code
            invokeSite = e.site
        }
        try {
            let _ = bad.call<Int64>([Int64(0)])
        } catch (e: JitException) {
            cc = e.code
            callSite = e.site
        }
        @Assert(ic, ErrCode.DIV_ZERO)
        @Assert(ic, cc)
        @Assert(invokeSite, callSite)
    }

    /**
     * A3.5（口径探针，X3 改写）：桥层**不改变**浮点除零语义。
     *
     * 严格浮点已归位 `CompileOptions.strictFp`（产物级：`FDIV` vs `FDIV_CHK`），
     * `CallContext` 不再有 `strictFp`。因此无论走 `invoke` 还是 `call`，默认产物（非严格）
     * 的 `÷0` 都恒得 `+Inf`；严格产物的 1（`DIV_ZERO`）由 `StrictFp_test` 覆盖。
     */
    @TestCase
    public func a3_5_bridgeKeepsDivisionSemantics(): Unit {
        // 本用例断言 IEEE 语义：显式关闭严格浮点
        let opts = CompileOptions(DummyDiagnosticsSink())
        opts.strictFp = false
        let c = Compiler(opts)
        CompileCache.reset()
        let f = c.compile('{ x: Float64 => 1.0f64 / x }')
        let viaInvoke = f.call<Float64>([0.0], CallContext())
        let plain = f.call<Float64>([0.0])
        @Assert(viaInvoke.toBits(), plain.toBits())
        // +Inf（0x7FF0000000000000）：不报错、也不是 ±Max
        @Assert(Int64(viaInvoke.toBits()), Int64(0x7FF0000000000000u64))
    }
}
