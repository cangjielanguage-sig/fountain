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
public class EncodePublishConsistencyTest {
    @TestCase
    public func testEncodePublishMatchesProduceCodec(): Unit {
        let topic = "/test-consistency"
        let labels = ArrayList<String>()
        labels.add("k1")
        labels.add("k2")
        let payload: Array<Byte> = [0xABu8, 0xCDu8]
        let msg = encodePublish(topic, labels, payload)
        let raw = ProduceCodec.encode(topic, labels, payload)
        if (let Some(body) <- convert<MqBody>(msg.data)) {
            @Assert(body.bodyType == "produce")
            @Assert(body.payload == raw)
        } else {
            @Assert(false)
        }
    }
}
