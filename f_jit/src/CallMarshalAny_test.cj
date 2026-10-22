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
import fountain::f_jit.base.ErrCode
import fountain::f_data.json.JsonObject
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType
import fountain::f_jit.test.ReflectUser
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.test.TCase

/**
 * M3 R5.1–R5.3：`CallMarshal` 的 Any 行与桥层错误码。
 *
 * - 参数 Any 行：任意宿主值 → 装箱 → 盒句柄；
 * - 返回 Any 行：逃逸 + 拆盒，把**原生 Any** 交还宿主；
 * - 桥层：22（`any_as` 未命中）按原码 + 原 site 抛 `JitException`。
 */
@Test
public class CallMarshalAny_test {
    private func setup(): Unit {
        HandleTable.resetForTest()
        HandleTable.initialCapacity = 128
        HandleTable.capacityLimit = 1048576
        HandleTable.openWindow(128)
    }

    /** Any 实参：值型 / 引用型都装箱，盒内容与实参逐位一致。 */
    @TestCase
    public func anyArgIsBoxed(): Unit {
        this.setup()
        let m = CallMarshal()
        let h = m.marshalArg(LocalType.ANY, 7)
        @Assert(h != 0, true)
        match (HandleTable.fetchAnyBox(h)) {
            case v: Int64 => @Assert(v, 7)
            case _ => @Fail('盒内容不是 Int64')
        }
        let hs = m.marshalArg(LocalType.ANY, 'hi')
        match (HandleTable.fetchAnyBox(hs)) {
            case v: String => @Assert(v, 'hi')
            case _ => @Fail('盒内容不是 String')
        }
        // 注册类实例：盒内保持同一引用
        let user = ReflectUser('u')
        let hu = m.marshalArg(LocalType.ANY, user)
        match (HandleTable.fetchAnyBox(hu)) {
            case v: ReflectUser => @Assert(v.name, 'u')
            case _ => @Fail('盒内容不是 ReflectUser')
        }
        // 仓颉闭包：可持有并原样取回（仍可调用）
        let f: (Int64) -> Int64 = { x => x + 1 }
        let hf = m.marshalArg(LocalType.ANY, f)
        match (HandleTable.fetchAnyBox(hf)) {
            case g: (Int64) -> Int64 => @Assert(g(41), 42)
            case _ => @Fail('盒内容不是闭包')
        }
        // JSON 节点：跨桥走 token 11 例外行，盒内是节点本身
        let node = JsonObject()
        let hn = m.marshalArg(LocalType.ANY, node)
        match (HandleTable.fetchAnyBox(hn)) {
            case o: JsonObject => @Assert(o.size, 0)
            case _ => @Fail('盒内容不是 JsonObject')
        }
        @Assert(TCase.hit('T37/marshal-any-arg', true), true)
    }

    /** Any 返回：拆盒后是原生值，不是盒句柄。 */
    @TestCase
    public func anyReturnUnboxes(): Unit {
        this.setup()
        let m = CallMarshal()
        let h = m.marshalArg(LocalType.ANY, 'hi')
        let out = m.makeRetUnboxer(LocalType.ANY)(h)
        match (out) {
            case s: String => @Assert(s, 'hi')
            case _ => @Fail('Any 返回未解包为原生值')
        }
        @Assert(TCase.hit('T37/marshal-any-ret', true), true)
    }

    /** 桥层：22 按原码 + `any_as` 调用点 site 抛出（不吞成 19/99）。 */
    @TestCase
    public func anyCastErrorReachesBridge(): Unit {
        let f = JitFunction(0, LocalType.I64, Array<UInt16>(),
            { ctx, _ =>
                ctx.errCode = ErrCode.ANY_CAST
                ctx.site = 42
                -1
            },
            { _, _ => 0 }, '')
        try {
            let _ = f.call<Int64>(Array<Any>())
            @Fail('未抛 22')
        } catch (e: JitException) {
            @Assert(e.code, ErrCode.ANY_CAST)
            @Assert(e.site, 42)
        }
        @Assert(TCase.hit('T38/bridge-22', true), true)
    }
}
