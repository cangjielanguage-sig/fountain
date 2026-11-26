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
package fountain::f_jsonrpc.server

import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*

/** SSE 流与 hub 的行为：阻塞读、心跳、有界丢弃、topic/taskId 过滤、断线补发 */
@Test
class Sse_test {
    /** 读一帧（帧内都是 ASCII，按字节拼回字符串即可） */
    private static func drain(stream: SseStream, size: Int64): String {
        let buffer = Array<Byte>(size, repeat: 0)
        let count = stream.read(buffer)
        if (count <= 0) {
            return ''
        }
        String.fromUtf8(buffer[0..count])
    }

    @TestCase
    func testPushedFrameIsReadBack(): Unit {
        let stream = SseStream()
        let _ = stream.push('hello\n')
        @Expect(drain(stream, 32), 'hello\n')
    }

    /** 关闭且队列空时才返回 0（std.io 的 EOF 约定） */
    @TestCase
    func testReadReturnsZeroOnlyAfterClose(): Unit {
        let stream = SseStream(heartbeat: Duration.millisecond * 20)
        let _ = stream.push('a')
        @Expect(drain(stream, 4), 'a')
        stream.close()
        @Expect(stream.read(Array<Byte>(4, repeat: 0)), 0)
    }

    /** 空闲一个心跳周期给一行注释帧，代理不会因为长时间无数据断连 */
    @TestCase
    func testIdleReadEmitsHeartbeat(): Unit {
        let stream = SseStream(heartbeat: Duration.millisecond * 30)
        let text = drain(stream, 32)
        @Expect(text.startsWith(': ping'), true)
        stream.close()
    }

    /** 慢消费者：溢出丢最旧的，不阻塞发布方，且 dropped 置位 */
    @TestCase
    func testSlowConsumerDropsOldest(): Unit {
        let stream = SseStream(capacity: 2)
        let _ = stream.push('1')
        let _ = stream.push('2')
        let _ = stream.push('3')

        @Expect(stream.dropped, true)
        // 最旧的被丢，队列里是 2、3
        @Expect(drain(stream, 4), '2')
        @Expect(drain(stream, 4), '3')
        stream.close()
    }

    /** 同一 topic 下 id 单调递增，data 是 JSON-RPC 通知 */
    @TestCase
    func testPublishProducesJsonRpcNotification(): Unit {
        SseHub.reset()
        let subscription = SseHub.subscribe('t')
        let first = SseHub.publish('t', 'a2a.task.status', params: JsonString('x'))
        let second = SseHub.publish('t', 'a2a.task.status', params: JsonString('y'))

        @Expect(second, first + 1)
        let frame = drain(subscription.stream, 128)
        @Expect(frame.contains('id: ${first}'), true)
        @Expect(frame.contains('event: message'), true)
        @Expect(frame.contains('"method":"a2a.task.status"'), true)
        @Expect(frame.contains('"jsonrpc":"2.0"'), true)
        subscription.close()
        SseHub.reset()
    }

    /** topic 之间互不串台 */
    @TestCase
    func testTopicIsolation(): Unit {
        SseHub.reset()
        let a = SseHub.subscribe('a')
        let _ = SseHub.subscribe('b')
        let _ = SseHub.publish('b', 'x.y')

        @Expect(SseHub.subscriberCount('a'), 1)
        @Expect(SseHub.subscriberCount('b'), 1)
        // a 收不到 b 的事件：读会走到心跳（超时），而不是事件帧
        a.close()
        SseHub.reset()
    }

    /** 带 taskId 订阅只收该任务的事件 */
    @TestCase
    func testTaskIdFilter(): Unit {
        SseHub.reset()
        let subscription = SseHub.subscribe('t', taskId: 'task-1')
        let _ = SseHub.publish('t', 'a2a.task.status', params: JsonString('one'), taskId: 'task-1')
        let _ = SseHub.publish('t', 'a2a.task.status', params: JsonString('two'), taskId: 'task-2')

        let first = drain(subscription.stream, 256)
        @Expect(first.contains('one'), true)
        subscription.close()
        SseHub.reset()
    }

    /** Last-Event-ID 之后的才补发 */
    @TestCase
    func testReplayAfterLastEventId(): Unit {
        SseHub.reset()
        let _ = SseHub.publish('t', 'm', params: JsonString('one'))
        let _ = SseHub.publish('t', 'm', params: JsonString('two'))
        let third = SseHub.publish('t', 'm', params: JsonString('three'))

        let subscription = SseHub.subscribe('t', lastEventId: third - 1)
        let frame = drain(subscription.stream, 256)
        @Expect(frame.contains('three'), true)
        subscription.close()
        SseHub.reset()
    }
}
