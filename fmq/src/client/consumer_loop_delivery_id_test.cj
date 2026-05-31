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
public class ConsumerLoopDeliveryIdTest {
    @TestCase
    public func testExtractQueueIndexFromDeliveryId(): Unit {
        // deliveryId 格式: "topic:queueIndex:groupId:offset"
        @Assert(ConsumerLoop.extractQueueIndex("/order/create:0:group1:10") == Some(0))
        @Assert(ConsumerLoop.extractQueueIndex("/order/create:3:groupA:0") == Some(3))
        @Assert(ConsumerLoop.extractQueueIndex("/a/b/c:7:myGroup:5") == Some(7))
    }

    @TestCase
    public func testExtractQueueIndexWithInvalidFormatReturnsNone(): Unit {
        // P3-4: 格式异常 → 返回 None 而非合法值 0
        @Assert(ConsumerLoop.extractQueueIndex("noColons").isNone())
        @Assert(ConsumerLoop.extractQueueIndex("one:paren").isNone())
    }

    @TestCase
    public func testExtractQueueIndexWithMultiSegmentTopic(): Unit {
        // topic 多段路径不含 ':'（validateTopic 禁止），queueIndex 始终在 parts[1]
        // deliveryId 格式: topic:queueIndex:groupId:offset[:sn]
        @Assert(ConsumerLoop.extractQueueIndex("/a/b/c:3:g:5") == Some(3))
        @Assert(ConsumerLoop.extractQueueIndex("/:1:x:2") == Some(1))
        @Assert(ConsumerLoop.extractQueueIndex("normal:0:g:0") == Some(0))
    }
}
