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
import fountain::f_httpclient.sse.*
import fountain::f_jsonrpc.base.*

/** 假连接：按脚本吐事件，吐完即结束 */
class FakeSseConnection <: SseConnection {
    private var events: ArrayList<SseEvent>

    FakeSseConnection(events: ArrayList<SseEvent>) {
        this.events = events
    }

    public func next(): ?SseEvent {
        if (events.isEmpty()) {
            return None
        }
        let first = events[0]
        let _ = events.remove(at: 0)
        Some(first)
    }

    public func close(): Unit {
    }
}

private func notification(id: String, method: String): SseEvent {
    SseEvent('message', '{"jsonrpc":"2.0","method":"${method}"}', id, 0)
}

@Test
class SseClient_test {
    /** 正常取一条通知 */
    @TestCase
    func testClientReturnsNotification(): Unit {
        let events = ArrayList<SseEvent>()
        events.add(notification('1', 'a2a.task.status'))
        let client = JsonRpcSseClient({ _ => Some(FakeSseConnection(events)) }, retry: 1)
        let value = client.next().getOrThrow()
        @Expect(value.asObject()['method'].asString().value, 'a2a.task.status')
        client.close()
    }

    /** 坏帧跳过，不影响后续事件 */
    @TestCase
    func testBadFrameIsSkipped(): Unit {
        let events = ArrayList<SseEvent>()
        events.add(SseEvent('message', 'not json', '1', 0))
        events.add(notification('2', 'good.event'))
        let client = JsonRpcSseClient({ _ => Some(FakeSseConnection(events)) }, retry: 1)
        let value = client.next().getOrThrow()
        @Expect(value.asObject()['method'].asString().value, 'good.event')
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

/// 重连脚本：第一次给 id=5 的事件，第二次给 id=6 的事件，并记录每次的请求头
class ReconnectScript {
    var received = ArrayList<HashMap<String, String>>()
    private var round: Int64 = 0

    func next(extra: HashMap<String, String>): ?SseConnection {
        received.add(extra)
        round++
        let events = ArrayList<SseEvent>()
        if (round == 1) {
            events.add(notification('5', 'first.event'))
        } else {
            events.add(notification('6', 'second.event'))
        }
        Some(FakeSseConnection(events))
    }

    func lastEventIdOf(index: Int64): String {
        match (received[index].get('Last-Event-ID')) {
            case Some(value) => value
            case None => ''
        }
    }
}
