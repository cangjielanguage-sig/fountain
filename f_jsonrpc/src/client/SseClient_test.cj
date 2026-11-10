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
package fountain::f_jsonrpc.client

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*
import fountain::f_jsonrpc.base.*

/** 假连接：按脚本吐块，吐完即结束 */
class FakeSseConnection <: SseConnection {
    private var chunks: ArrayList<String>

    FakeSseConnection(chunks: ArrayList<String>) {
        this.chunks = chunks
    }

    public func readChunk(): ?String {
        if (chunks.isEmpty()) {
            return None
        }
        let first = chunks[0]
        let _ = chunks.remove(at: 0)
        first
    }

    public func close(): Unit {
    }
}

private func frameText(id: Int64, method: String): String {
    'id: ${id}\nevent: message\ndata: {"jsonrpc":"2.0","method":"${method}"}\n\n'
}

@Test
class SseClient_test {
    /** 分块边界可以落在任意位置：半个帧、跨两帧都要能拼对 */
    @TestCase
    func testParserHandlesArbitraryChunkBoundary(): Unit {
        let parser = SseFrameParser()
        let text = frameText(1, 'a2a.task.status')
        let first = parser.feed(text[..7])
        @Expect(first.size, 0)
        let second = parser.feed(text[7..20])
        @Expect(second.size, 0)
        let third = parser.feed(text[20..])
        @Expect(third.size, 1)
        @Expect(third[0].id, 1)
        @Expect(third[0].data.contains('a2a.task.status'), true)
    }

    /** 注释帧与空帧不产出事件 */
    @TestCase
    func testParserIgnoresComments(): Unit {
        let parser = SseFrameParser()
        @Expect(parser.feed(': ping\n\n').size, 0)
        @Expect(parser.feed('\n\n').size, 0)
    }

    /** 正常取一条通知后关闭 */
    @TestCase
    func testClientReturnsNotification(): Unit {
        let chunks = ArrayList<String>()
        chunks.add(frameText(1, 'a2a.task.status'))
        let client = JsonRpcSseClient({ _ => Some(FakeSseConnection(chunks)) }, retry: 1)
        let value = client.next().getOrThrow()
        let method = value.asObject()['method'].asString().value
        @Expect(method, 'a2a.task.status')
        client.close()
    }

    /** 断线后带 Last-Event-ID 重连，只继续拿新事件 */
    @TestCase
    func testReconnectSendsLastEventId(): Unit {
        let script = ReconnectScript()
        let client = JsonRpcSseClient({ extra => script.next(extra) }, retry: 2)

        let a = client.next().getOrThrow()
        @Expect(a.asObject()['method'].asString().value, 'first.event')
        let b = client.next().getOrThrow()
        @Expect(b.asObject()['method'].asString().value, 'second.event')
        // 第二次连接的请求头里必须带上次的 id
        @Expect(script.received.size, 2)
        @Expect(script.lastEventIdOf(1), '5')
        client.close()
    }

    /** 重试用尽必须抛错，而不是静默结束 */
    @TestCase
    func testThrowsWhenRetriesExhausted(): Unit {
        let client = JsonRpcSseClient({ _ => None }, retry: 2)
        var message = ''
        try {
            let _ = client.next()
        } catch (e: JsonRpcConnectException) {
            message = e.message
        }
        @Expect(message.contains('reconnect'), true)
    }
}
/// 重连脚本：第一次给 id=5 的帧，第二次给 id=6 的帧，并记录每次的请求头
class ReconnectScript {
    var received = ArrayList<HashMap<String, String>>()
    private var round: Int64 = 0

    func next(extra: HashMap<String, String>): ?SseConnection {
        received.add(extra)
        round++
        let chunks = ArrayList<String>()
        if (round == 1) {
            chunks.add('id: 5\nevent: message\ndata: {"jsonrpc":"2.0","method":"first.event"}\n\n')
        } else {
            chunks.add('id: 6\nevent: message\ndata: {"jsonrpc":"2.0","method":"second.event"}\n\n')
        }
        Some(FakeSseConnection(chunks))
    }

    func lastEventIdOf(index: Int64): String {
        match (received[index].get('Last-Event-ID')) {
            case Some(value) => value
            case None => ''
        }
    }
}