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
public class ProduceCodecBoundsTest {
    @TestCase
    public func testDecodeRejectsNegativeLabelCount(): Unit {
        let buf = ByteBuffer()
        DefaultCodec().encode("/test").encode(-1i64).encode([0x01u8])
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        @Assert(ProduceCodec.decode(raw).isNone())
    }

    @TestCase
    public func testDecodeRejectsExcessiveLabelCount(): Unit {
        let buf = ByteBuffer()
        DefaultCodec().encode("/test").encode(257i64).encode([0x01u8])
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        @Assert(ProduceCodec.decode(raw).isNone())
    }

    @TestCase
    public func testDecodeAcceptsValidLabelCount(): Unit {
        let buf = ByteBuffer()
        let enc = DefaultCodec().encode("/test").encode(64i64)
        for (_ in 0..64) { enc.encode("l") }
        enc.encode([0x01u8])
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        @Assert(ProduceCodec.decode(raw).isSome())
    }

    // ── P2-4: 自定义 maxLabels ──

    @TestCase
    public func testDecodeAcceptsMaxLabelsParam(): Unit {
        // encode 3 labels, maxLabels=5 should accept
        let buf = ByteBuffer()
        let enc = DefaultCodec().encode("/p2-4").encode(3i64)
        for (_ in 0..3) { enc.encode("x") }
        enc.encode([0x01u8])
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        @Assert(ProduceCodec.decode(raw, maxLabels: 5).isSome())
    }

    @TestCase
    public func testDecodeRejectsLabelsOverMaxLabelsParam(): Unit {
        // encode 3 labels, maxLabels=2 should reject
        let buf = ByteBuffer()
        let enc = DefaultCodec().encode("/p2-4b").encode(3i64)
        for (_ in 0..3) { enc.encode("y") }
        enc.encode([0x01u8])
            .finish().copy(to: buf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(buf)
        @Assert(ProduceCodec.decode(raw, maxLabels: 2).isNone())
    }
}
