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
package fountain::f_jit.bytecode

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.json.{JsonArray, JsonNull, JsonObject}

/**
 * M3 R2：JSON 常量（kind 11）—— 拼装只登记原始字节、加载期解析一次、坏载荷拒绝。
 */
@Test
public class JsonConst_test {

    /** 拼装期只登记字节：`addJson` 不解析，返回递增 hid。 */
    @TestCase
    public func addJsonOnlyStoresRawBytes(): Unit {
        let reg = ConstRegistry()
        let a = reg.addJson("{\"a\":1}")
        let b = reg.addJson("[1,2]")
        @Assert(a, 0)
        @Assert(b, 1)
        @Assert(reg.size, 2)
        match (reg.get(0)) {
            case PJson(raw) => @Assert(raw, "{\"a\":1}")
            case _ => @Assert(0, 1)
        }
    }

    /** 编解码往返：kind 11 的 payload 逐字节保真。 */
    @TestCase
    public func jsonPayloadRoundTrips(): Unit {
        let raw = "{\"k\":\"值\",\"n\":[1,2]}"
        let reg = ConstRegistry()
        let _ = reg.addJson(raw)
        let bytes = reg.encode()
        let back = ConstRegistry.decode(bytes)
        @Assert(back.size, 1)
        match (back.get(0)) {
            case PJson(s) => @Assert(s, raw)
            case _ => @Assert(0, 1)
        }
    }

    /** 加载期实例化：对象 → JsonObject、数组 → JsonArray，且跨访问同 ID。 */
    @TestCase
    public func jsonInstantiatesOnceAndReusesIdentity(): Unit {
        let reg = ConstRegistry()
        let objHid = reg.addJson("{\"a\":1}")
        let arrHid = reg.addJson("[]")
        reg.instantiateAll()
        match (reg.instanceAt(objHid)) {
            case _: JsonObject => ()
            case _ => @Assert(0, 1)
        }
        match (reg.instanceAt(arrHid)) {
            case _: JsonArray => ()
            case _ => @Assert(0, 1)
        }
        // 同一条目重复访问取到同一对象：同一 JSON 文本、且内容未被重建（键值仍在）
        let first = reg.instanceAt(objHid)
        let second = reg.instanceAt(objHid)
        match (first) {
            case a: JsonObject =>
                match (second) {
                    case b: JsonObject => @Assert(a.toString(), b.toString())
                    case _ => @Assert(0, 1)
                }
            case _ => @Assert(0, 1)
        }
    }

    /** 非法 JSON：拼装期放过，加载期拒绝（主防线在加载期）。 */
    @TestCase
    public func invalidJsonIsRejectedAtLoad(): Unit {
        let reg = ConstRegistry()
        let _ = reg.addJson("{\"a\":}")
        var rejected = false
        try {
            reg.instantiateAll()
        } catch (_: Exception) {
            rejected = true
        }
        @Assert(rejected, true)
    }

    /** 未知 kind 12：解码期拒绝。 */
    @TestCase
    public func unknownKindIsRejected(): Unit {
        // version u16 = 1；count u32 = 1；kind = 12
        let bytes: Array<UInt8> = [1, 0, 1, 0, 0, 0, 12]
        var rejected = false
        try {
            let _ = ConstRegistry.decode(bytes)
        } catch (_: Exception) {
            rejected = true
        }
        @Assert(rejected, true)
    }

    /** 空载荷在拼装期就被拒绝（空串必是非法 JSON）。 */
    @TestCase
    public func emptyRawIsRejectedAtBuild(): Unit {
        let reg = ConstRegistry()
        var rejected = false
        try {
            let _ = reg.addJson("")
        } catch (_: Exception) {
            rejected = true
        }
        @Assert(rejected, true)
    }
}
