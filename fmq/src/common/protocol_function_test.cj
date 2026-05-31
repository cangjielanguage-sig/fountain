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
public class ProtocolFunctionTest {
    @TestCase
    public func testEncodePingCommand(): Unit {
        // 验证 PING 命令标签 = 12 (0x0C)
        let msg = ProtocolMessage(Command.PING(0))
        @Assert((msg.command.value >> 4) == 12u8)
    }

    @TestCase
    public func testEncodeSubscribeCommand(): Unit {
        let msg = encodeSubscribe("my-group", MatchMode.Exact("/topic"))
        // encodeSubscribe 返回 ProtocolMessage
        @Assert((msg.command.value >> 4) == 8u8)  // SUBSCRIBE tag
    }

    @TestCase
    public func testEncodeConsumeCommand(): Unit {
        let msg = encodeConsume("/topic", "my-group", 1)
        @Assert((msg.command.value >> 4) == 10u8)  // CONSUME tag
    }

    @TestCase
    public func testEncodeAckCommand(): Unit {
        let msg = encodeAck("msg-id", "/topic", 0)
        @Assert((msg.command.value >> 4) == 14u8)  // ACK tag
    }

    @TestCase
    public func testExtractBytesEmpty(): Unit {
        let buf = ByteBuffer()
        @Assert(extractBytes(buf).size == 0)
    }

    @TestCase
    public func testExtractBytesNonEmpty(): Unit {
        let buf = ByteBuffer()
        buf.write([0x01u8, 0x02u8, 0x03u8])
        let raw = extractBytes(buf)
        @Assert(raw.size == 3)
        @Assert(raw[0] == 0x01u8)
        @Assert(raw[2] == 0x03u8)
    }

    @TestCase
    public func testExtractBytesNegativeGuard(): Unit {
        let buf = ByteBuffer()
        // 空 buffer 的 seek=0, read=0, bytesRead=0 >= 0 → 返回 []
        let result = extractBytes(buf)
        @Assert(result.size == 0)
    }
}
