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
public class BatchConsumeProtocolTest {
    @TestCase
    public func testEncodeBatchConsumePayload(): Unit {
        let subs = ArrayList<(String, String, String, String)>()
        subs.add(("g1", "/topic/a", "", "exact"))
        subs.add(("g2", "/topic/b", "", "prefix"))
        let payload = Consumer.encodeBatchConsumePayload(subs)
        // 解码验证: topicCount=2, topic="/topic/a", groupId="g1", batchSize=1, ...
        let buf = ByteBuffer(payload)
        let dec = DefaultCodec()
        if (let Some(count) <- dec.decode<Int64>(buf)
            && let Some(t1) <- dec.decode<String>(buf)
            && let Some(g1) <- dec.decode<String>(buf)
            && let Some(bs1) <- dec.decode<Int64>(buf)
            && let Some(t2) <- dec.decode<String>(buf)
            && let Some(g2) <- dec.decode<String>(buf)
            && let Some(bs2) <- dec.decode<Int64>(buf)) {
            @Assert(count == 2)
            @Assert(t1 == "/topic/a")
            @Assert(g1 == "g1")
            @Assert(bs1 == 1)
            @Assert(t2 == "/topic/b")
            @Assert(g2 == "g2")
            @Assert(bs2 == 1)
        }
    }

    @TestCase
    public func testDecodeBatchConsumeResponseEmpty(): Unit {
        let encBuf = ByteBuffer()
        DefaultCodec().encode(0i64)
            .finish().copy(to: encBuf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(encBuf)
        let result = Consumer.decodeBatchConsumeResponse(raw)
        @Assert(result.size == 0)
    }

    @TestCase
    public func testBatchConsumeRoundtrip(): Unit {
        // 构造响应: 1 topic "/a", group "g1", 1 msg
        let encBuf = ByteBuffer()
        DefaultCodec()
            .encode(1i64)              // topicCount
            .encode("/a")              // topic
            .encode("g1")              // groupId
            .encode(1i64)              // msgCount
            .encode("id:a:0:g1:0")     // deliveryId
            .encode(1i64)              // labelCount
            .encode("k=v")             // label
            .encode([0x01u8, 0x02u8])  // payload
            .finish().copy(to: encBuf, closeFromOnEnd: true, closeToOnEnd: false)
        let raw = extractBytes(encBuf)
        let result = Consumer.decodeBatchConsumeResponse(raw)
        @Assert(result.size == 1)
        if (let Some(groupMap) <- result.get("/a")) {
            @Assert(groupMap.size == 1)
            if (let Some(msgs) <- groupMap.get("g1")) {
                @Assert(msgs.size == 1)
                let (id, labels, payload) = msgs[0]
                @Assert(id == "id:a:0:g1:0")
                @Assert(labels.size == 1)
                @Assert(labels[0] == "k=v")
                @Assert(payload.size == 2)
            }
        }
    }
}
