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
public class DeregisterPayloadTest {
    @TestCase
    public func testDeregisterPayloadRoundtrip(): Unit {
        let groupId = "my-group"
        let consumerId = "consumer-123"

        // 客户端编码（与 Subscriber.deregister 的编码方式一致）
        let buf = ByteBuffer()
        let enc = DefaultCodec()
            .encode(groupId)
            .encode(consumerId)
            .finish()
        enc.copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let size = buf.seek(SeekPosition.End(0))
        buf.seek(SeekPosition.Begin(0))
        let raw = Array<Byte>(Int64(size), repeat: 0u8)
        buf.read(raw)

        // 服务端解码（与 CommandExecutor.handleDeregister 的解码方式一致）
        let dec = DefaultCodec()
        let decBuf = ByteBuffer(raw)
        if (let Some(g) <- dec.decode<String>(decBuf)
            && let Some(c) <- dec.decode<String>(decBuf)) {
            @Assert(g == groupId)
            @Assert(c == consumerId)
        } else {
            @Assert(false)
        }
    }
}
