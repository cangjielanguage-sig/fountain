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
public class MqBodyTest {
    @TestCase
    public func testRoundtrip(): Unit {
        let body = MqBody("test-type", [0x01u8, 0x02u8, 0x03u8])
        let data = body.toData()
        if (let Some(decoded) <- convert<MqBody>(data)) {
            @Assert(decoded.bodyType == "test-type")
            @Assert(decoded.payload.size == 3)
            @Assert(decoded.payload[0] == 0x01u8)
        } else {
            @Assert(false)
        }
    }
}
