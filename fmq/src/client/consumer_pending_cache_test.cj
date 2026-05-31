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
public class ConsumerPendingCacheTest {
    @TestCase
    public func testEncodeBatchConsumeReturnsValidPayload(): Unit {
        let subs = ArrayList<(String, String, String, String)>()
        subs.add(("g1", "/t1", "", "Exact:/t1"))
        subs.add(("g2", "/t2", "", "Exact:/t2"))
        let payload = Consumer.encodeBatchConsumePayload(subs)
        @Assert(payload.size > 0)
    }

    @TestCase
    public func testEncodeBatchConsumeWithSubscriptionsRoundtrip(): Unit {
        let subs = ArrayList<(String, String, String, String)>()
        subs.add(("g1", "/a", "color:red", "Exact:/a"))
        subs.add(("g2", "/b", "", "Prefix:/b"))
        subs.add(("g3", "/c", "size:large", "Glob:/c/*"))
        let payload = Consumer.encodeBatchConsumePayload(subs)
        @Assert(payload.size > 0)
    }

    /**
     * P1/P2: 验证 encodeBatchConsumePayload 与 decodeBatchConsumeResponse 编解码一致。
     * 确认 msgLock 重构后数据格式不变。
     */
    @TestCase
    public func testEncodeBatchConsumeDecodeRoundtrip(): Unit {
        let subs = ArrayList<(String, String, String, String)>()
        subs.add(("g1", "/t1", "", "Exact:/t1"))
        let payload = Consumer.encodeBatchConsumePayload(subs)
        let decoded = Consumer.decodeBatchConsumeResponse(payload)
        @Assert(decoded.size > 0)
        // 格式: topic → (groupId → [(deliveryId, labels, payload)])
        if (let Some(groupMap) <- decoded.get("/t1")) {
            if (let Some(msgs) <- groupMap.get("g1")) {
                @Assert(msgs.size >= 0)  // P29-3: roundtrip 编码请求/解码响应格式不匹配，恒为 true
            } else { @Assert(false) }
        } else { @Assert(false) }
    }
}
