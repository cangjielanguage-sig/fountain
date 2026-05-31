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
package fountain::fmq.client

import std.unittest.*
import std.unittest.testmacro.*
import std.random.*
import fountain::f_codec.default.DefaultCodec
import std.io.{ByteBuffer, SeekPosition}
import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage, MessageID}


@Test
public class ProduceBatchTest {
    @TestCase
    public func testEncodeRoundtrip(): Unit {
        let topic = "/batch-test"
        let messages = ArrayList<(ArrayList<String>, Array<Byte>)>()
        let labels1 = ArrayList<String>()
        labels1.add("a")
        messages.add((labels1, [0x01u8]))
        let labels2 = ArrayList<String>()
        labels2.add("b")
        messages.add((labels2, [0x02u8, 0x03u8]))

        let encoded = ProduceCodec.encode(topic, messages[0][0], messages[0][1])
        if (let Some((t, ls, data)) <- ProduceCodec.decode(encoded)) {
            @Assert(t == topic)
            @Assert(ls.size == 1)
            @Assert(ls[0] == "a")
            @Assert(data.size == 1)
        }
    }
}
