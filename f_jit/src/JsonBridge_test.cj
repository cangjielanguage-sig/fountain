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
import fountain::f_data.json.{JsonArray, JsonNull, JsonObject}
import fountain::f_jit.base.ErrCode
import fountain::f_jit.base.JitException
import fountain::f_jit.base.LocalType
import fountain::f_jit.base.TypeToken
import fountain::f_jit.runtime.HandleTable
import fountain::f_jit.runtime.SignatureDescriptor
import fountain::f_jit.test.TCase

/**
 * M3 R3.10：JSON 内建码（16–19）的**跨桥一行**——`CallMarshal` 参数封送与返回解包。
 *
 * 口径（v0.3.20）：JSON 码零注册，句柄 **tag/token 复用 11**，不为 JSON 新开编码；
 * 封送只校验「是 JSON 节点」这一层（17/18/19 精确、16 收全部节点），失败一律 19。
 */
@Test
public class JsonBridge_test {
    private static func setup(): Unit {
        HandleTable.resetForTest()
        HandleTable.openWindow(128)
    }

    /** 17 型实参：pin 后 tag = 11，取回即同一对象。 */
    @TestCase
    public func marshalJsonObject(): Unit {
        JsonBridge_test.setup()
        let m = CallMarshal()
        let o = JsonObject()
        let id = m.marshalArg(LocalType.JSON_OBJECT, o)
        @Assert(id != 0, true)
        @Assert(HandleTable.isType(id, TypeToken.HOST_OBJECT), true)
        match (HandleTable.getAny(id)) {
            case Some(v) =>
                match (v) {
                    case back: JsonObject => @Assert(back is JsonObject, true)
                    case _ => @Fail('17 载荷不是 JsonObject')
                }
            case None => @Fail('17 句柄不可读')
        }
        @Assert(TCase.hit('T61/marshal-json-object', true), true)
    }

    /** 16 型收全部节点（码级继承）；17/18/19 精确。 */
    @TestCase
    public func marshalJsonValueAcceptsWholeFamily(): Unit {
        JsonBridge_test.setup()
        let m = CallMarshal()
        @Assert(m.marshalArg(LocalType.JSON_VALUE, JsonObject()) != 0, true)
        @Assert(m.marshalArg(LocalType.JSON_VALUE, JsonArray()) != 0, true)
        @Assert(m.marshalArg(LocalType.JSON_VALUE, JsonNull.instance) != 0, true)
        @Assert(m.marshalArg(LocalType.JSON_ARRAY, JsonArray()) != 0, true)
        @Assert(m.marshalArg(LocalType.JSON_NULL, JsonNull.instance) != 0, true)
    }

    /** 类型不符 → 契约错误 19（不是 22：22 只属于 `any_as` 世界内转型）。 */
    @TestCase
    public func marshalRejectsWrongJsonClass(): Unit {
        JsonBridge_test.setup()
        let m = CallMarshal()
        @Assert(JsonBridge_test.codeOf({ => m.marshalArg(LocalType.JSON_ARRAY, JsonObject()) }),
            Int64(ErrCode.CALL_CONTRACT))
        @Assert(JsonBridge_test.codeOf({ => m.marshalArg(LocalType.JSON_OBJECT, 'not-json') }),
            Int64(ErrCode.CALL_CONTRACT))
        @Assert(TCase.hit('T61/marshal-json-19', true), true)
    }

    /** 返回解包：17 型逃逸后取回节点对象。 */
    @TestCase
    public func unboxJsonReturnEscapes(): Unit {
        JsonBridge_test.setup()
        let m = CallMarshal()
        let o = JsonObject()
        let id = m.marshalArg(LocalType.JSON_OBJECT, o)
        match (m.makeRetUnboxer(LocalType.JSON_OBJECT)(id)) {
            case v: JsonObject => @Assert(v is JsonObject, true)
            case _ => @Fail('17 返回解包类型不符')
        }
    }

    /** 编码不变式：JSON 句柄 tag 仍是 11，且 `TypeToken.HOST_OBJECT == 11`（无新 token）。 */
    @TestCase
    public func jsonTagsReuseHostObject(): Unit {
        JsonBridge_test.setup()
        @Assert(TypeToken.HOST_OBJECT, 11u16)
        let o = HandleTable.pin(JsonObject())
        @Assert(HandleTable.isType(o, TypeToken.HOST_OBJECT), true)
        let a = HandleTable.pin(JsonArray())
        @Assert(HandleTable.isType(a, TypeToken.HOST_OBJECT), true)
    }

    /** HostClosure 签名含 JSON 形参：验签通过（反射侧按名字取码）、句柄 tag = 10。 */
    @TestCase
    public func hostClosureWithJsonSignature(): Unit {
        JsonBridge_test.setup()
        let m = CallMarshal()
        let f: (JsonObject) -> Int64 = { o =>
            let _ = o
            1
        }
        let sig = SignatureDescriptor([LocalType.JSON_OBJECT], LocalType.I64)
        let id = m.marshalHostClosure(f, sig)
        @Assert(id != 0, true)
        @Assert(HandleTable.isType(id, TypeToken.HOST_CLOSURE), true)
        @Assert(TCase.hit('T61/host-closure-json-sig', true), true)
    }

    private static func codeOf(f: () -> Unit): Int64 {
        try {
            f()
        } catch (e: JitException) {
            return e.code
        }
        0
    }
}
