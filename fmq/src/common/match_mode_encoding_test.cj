/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain at the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::fmq.common

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.env.{setVariable, removeVariable}
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.Message as ProtocolMessage


@Test
public class MatchModeEncodingTest {
    @TestCase
    public func testEncodeMatchModeExactRoundtrip(): Unit {
        let mode = MatchMode.Exact("/order/create")
        let encoded = encodeMatchMode(mode)
        @Assert(encoded == "Exact:/order/create")
        // 验证 encodeMatchMode 输出与 decodeMatchMode 兼容
        let reg = ConsumerRegistration(
            consumerId: "c1", groupId: "g1",
            matchModeStr: encoded,
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let decoded = reg.getMatchMode()
        if (let MatchMode.Exact(t) <- decoded) { @Assert(t == "/order/create") }
        else { @Assert(false) }
    }

    @TestCase
    public func testEncodeMatchModeGlobRoundtrip(): Unit {
        let mode = MatchMode.Glob("/order/*")
        let encoded = encodeMatchMode(mode)
        @Assert(encoded == "Glob:/order/*")
        let reg = ConsumerRegistration(
            consumerId: "c2", groupId: "g2",
            matchModeStr: encoded,
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let decoded = reg.getMatchMode()
        if (let MatchMode.Glob(p) <- decoded) { @Assert(p == "/order/*") }
        else { @Assert(false) }
    }

    @TestCase
    public func testEncodeMatchModePrefixRoundtrip(): Unit {
        let mode = MatchMode.Prefix("/order/")
        let encoded = encodeMatchMode(mode)
        @Assert(encoded == "Prefix:/order/")
        let reg = ConsumerRegistration(
            consumerId: "c3", groupId: "g3",
            matchModeStr: encoded,
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let decoded = reg.getMatchMode()
        if (let MatchMode.Prefix(p) <- decoded) { @Assert(p == "/order/") }
        else { @Assert(false) }
    }
}
