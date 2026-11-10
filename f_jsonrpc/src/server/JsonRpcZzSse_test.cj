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
import std.net.TcpSocket
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_data.*

/** 跨线程取文本：读线程写、主线程轮询 */
class SseText {
    private let mutex = Mutex()
    private var text: String = ''

    func set(value: String): Unit {
        synchronized(mutex) {
            text = value
        }
    }

    func get(): String {
        synchronized(mutex) {
            text
        }
    }

    func contains(fragment: String): Bool {
        get().contains(fragment)
    }
}

/**
 * SSE 端点必须在真实 MVC 请求链上验证：返回的 `InputStream` 是否**边读边写**，
 * 直接决定「推送能不能立刻到客户端」。若 `f_mvc` 把流读完再发，本用例会超时失败。
 */
@Test
class JsonRpcZzSse_test {
    @TestCase
    public func testStreamPushesIncrementally(): Unit {
        let port = MvcProbe.ensure()
        let socket = TcpSocket('127.0.0.1', port)
        socket.connect()
        let request = 'GET /rpc/stream?topic=sse-smoke HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n' +
            'Accept: text/event-stream\r\nConnection: keep-alive\r\n\r\n'
        socket.write(request.unsafeBytes())

        let box = SseText()
        spawn {
            let out = ArrayList<Byte>()
            let buffer = Array<Byte>(4096, repeat: 0)
            while (true) {
                let count = try {
                    socket.read(buffer)
                } catch (_: Exception) {
                    0
                }
                if (count <= 0) {
                    break
                }
                out.add(all: buffer[0..count])
                box.set(String.fromUtf8(out.unsafeData()))
                if (box.contains('a2a.task.status')) {
                    break
                }
            }
        }

        // 控制器返回后订阅才在 hub 里登记，先等它出现再发布
        for (_ in 0..30) {
            if (SseHub.subscriberCount('sse-smoke') > 0) {
                break
            }
            sleep(Duration.millisecond * 100)
        }
        let _ = SseHub.publish('sse-smoke', 'a2a.task.status', params: JsonString('ok'))

        for (_ in 0..50) {
            if (box.contains('a2a.task.status')) {
                break
            }
            sleep(Duration.millisecond * 100)
        }
        // 响应头：证明走的就是 SSE 的 produces
        @Expect(box.get().toAsciiLower().contains('text/event-stream'), true)
        // 无 Content-Length、用 chunked：这是「边读边写」的前提（也是 f_mvc 修的 bug）
        @Expect(box.get().toAsciiLower().contains('transfer-encoding: chunked'), true)
        // 增量到达：证明 InputStream 是流式写出，而不是缓冲到结束
        @Expect(box.contains('a2a.task.status'), true)
        socket.close()
    }

    /** 查询串解析：缺省 topic 有回落，taskId/cursor 原样取出 */
    @TestCase
    public func testQueryParsing(): Unit {
        let query = SseController.queryOf('topic=a2a&taskId=task-1&cursor=7')
        @Expect(SseController.textOf(query, 'topic'), 'a2a')
        @Expect(SseController.textOf(query, 'taskId'), 'task-1')
        @Expect(SseController.textOf(query, 'cursor'), '7')

        let empty = SseController.queryOf('')
        @Expect(empty.size, 0)
    }
}
