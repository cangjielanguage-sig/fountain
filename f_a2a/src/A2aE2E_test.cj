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
package fountain::f_a2a

import std.collection.*
import std.net.{IPSocketAddress, TcpServerSocket, TcpSocket}
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_a2a.client.*
import fountain::f_a2a.model.*
import fountain::f_a2a.server.*
import fountain::f_config.Config
import fountain::f_data.*
import fountain::f_jsonrpc.client.*
import fountain::f_mvc.{MVCConfig, MVCStarter}

/** 真实 MVC 服务：走一遍 `/rpc` 与 `/rpc/stream`，验证不是只在单测里成立 */
private class A2aProbe {
    static let lock = Mutex()
    static var port: UInt16 = 0
    static var installed = false

    static func ensure(): UInt16 {
        synchronized(lock) {
            if (port != 0) {
                return port
            }
            let chosen = freePort()
            Config.set([(MVCConfig.HOST, '127.0.0.1'), (MVCConfig.PORT, chosen.toString())])
            MVCStarter.initialize()
            spawn {
                MVCStarter.start()
            }
            for (_ in 0..50) {
                try {
                    let probe = TcpSocket('127.0.0.1', chosen)
                    probe.connect()
                    probe.close()
                    break
                } catch (_: Exception) {
                    sleep(Duration.millisecond * 100)
                }
            }
            port = chosen
            return chosen
        }
    }

    /** 装配一次 A2A 服务端（进程级注册表只注册一次） */
    static func install(): Unit {
        synchronized(lock) {
            if (installed) {
                return
            }
            installed = true
        }
        let card = A2aAgentCard(name: 'e2e 代理', url: 'http://127.0.0.1/rpc/a2a')
        let server = A2aServer(card, DoneExecutor())
        server.register()
    }

    private static func freePort(): UInt16 {
        let probe = TcpServerSocket(bindAt: 0)
        probe.bind()
        var chosen: UInt16 = 0
        match (probe.localAddress) {
            case addr: IPSocketAddress => chosen = addr.port
            case _ => ()
        }
        probe.close()
        chosen
    }
}

class DoneExecutor <: A2aExecutor {
    public func execute(task: A2aTask, message: A2aMessage): A2aExecutionResult {
        A2aExecutionResult.done('完成：${message.text()}')
    }
}

private func oneMessage(text: String): A2aMessage {
    let parts = ArrayList<A2aPart>()
    parts.add(A2aPart(text: text))
    A2aMessage(parts: parts, messageId: 'm-e2e')
}

@Test
class A2aE2E_test {
    /** 真实 HTTP：`a2a.message.send` 跑通并返回终态任务 */
    @TestCase
    func testSendOverHttp(): Unit {
        let port = A2aProbe.ensure()
        A2aProbe.install()
        let client = A2aClient('http://127.0.0.1:${port}/rpc')
        let task = client.send(oneMessage('汇总今天的提交'))
        @Expect(task.status, A2aStates.COMPLETED)
        @Expect(task.artifacts.size, 1)
        @Expect(task.artifacts[0].parts[0].text.contains('完成'), true)
        // 再取一次：存储链路也通
        let again = client.get(task.id)
        @Expect(again.id, task.id)
        client.close()
    }

    /** 真实 SSE：订阅后调 `a2a.message.stream`，收到 working 与 completed 两条事件 */
    @TestCase
    func testStreamOverHttp(): Unit {
        let port = A2aProbe.ensure()
        A2aProbe.install()
        let url = 'http://127.0.0.1:${port}/rpc/stream'
        let sse = JsonRpcSseClient(url, topic: 'a2a', taskId: '')
        let events = Received()
        spawn {
            for (_ in 0..2) {
                match (sse.next()) {
                    case Some(value) =>
                        events.add(value.toString())
                    case None => break
                }
            }
        }
        // 等订阅登记完成，再触发一次流式执行
        sleep(Duration.millisecond * 500)
        let client = A2aClient('http://127.0.0.1:${port}/rpc')
        let raw = JsonRpcClient('http://127.0.0.1:${port}/rpc')
        let params = JsonObject()
        params.add('message', oneMessage('流式汇总').toJson())
        let _ = client.send(oneMessage('普通汇总'))    // 先发一条非流式，确认互不干扰
        let _ = raw.call(A2aServer.METHOD_STREAM, params: params)

        for (_ in 0..50) {
            if (events.size() >= 2) {
                break
            }
            sleep(Duration.millisecond * 100)
        }
        @Expect(events.size() >= 2, true)
        @Expect(events.at(0).contains(A2aStates.WORKING), true)
        @Expect(events.at(1).contains(A2aStates.COMPLETED), true)
        sse.close()
        raw.close()
        client.close()
    }

    /** 真实 HTTP：推送配置的增删查 */
    @TestCase
    func testPushConfigOverHttp(): Unit {
        let port = A2aProbe.ensure()
        A2aProbe.install()
        let raw = JsonRpcClient('http://127.0.0.1:${port}/rpc')

        let setParams = JsonObject()
        setParams.add('taskId', 'task-e2e')
        setParams.add('url', 'http://hook.local/a2a')
        setParams.add('token', 'tk-e2e')
        let set = raw.call(A2aServer.METHOD_PUSH_SET, params: setParams)
        @Expect(set.toString().contains('hook.local'), true)

        let getParams = JsonObject()
        getParams.add('taskId', 'task-e2e')
        @Expect(raw.call(A2aServer.METHOD_PUSH_GET, params: getParams).toString().contains('tk-e2e'), true)

        let deleted = raw.call(A2aServer.METHOD_PUSH_DELETE, params: getParams)
        @Expect(deleted.toString(), 'true')
        raw.close()
    }
}

/** 跨线程收事件 */
class Received {
    private let mutex = Mutex()
    private let items = ArrayList<String>()

    func add(value: String): Unit {
        synchronized(mutex) {
            items.add(value)
        }
    }

    func size(): Int64 {
        synchronized(mutex) {
            Int64(items.size)
        }
    }

    func at(index: Int64): String {
        synchronized(mutex) {
            if (index < Int64(items.size)) {
                items[index]
            } else {
                ''
            }
        }
    }
}
