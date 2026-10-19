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
package fountain::f_mq.client.test

import std.collection.ArrayList
import std.net.{TcpSocket, IPSocketAddress}
import std.sync.{Mutex, AtomicInt64}
import fountain::f_data.DataAny
import fountain::f_net.*
import fountain::f_net.SocketBuffer
import fountain::f_net.server.Server
import fountain::f_protocol.default.Message

/**
 * 进程内 MQ 桩服务端：基于 `f_net.Server<DataAny>`，可预设响应并记录收到的请求。
 *
 * 用于客户端单测，不启动真实 `fmq`。
 */
public class MQStubServer <: Resource {
    private static let nextPort = AtomicInt64(25000)

    let port: UInt16
    private let server: Server<DataAny>
    private let requests = ArrayList<Message>()
    private let lock = Mutex()
    private var responder: (SocketBuffer, Message) -> ?Message

    public init(responder: (SocketBuffer, Message) -> ?Message) {
        this.responder = responder
        var built: ?Server<DataAny> = None
        var chosen: UInt16 = 0
        var attempt = 0
        while (built.isNone() && attempt < 100) {
            let candidate = UInt16(nextPort.fetchAdd(1) % 60000)
            try {
                built = Some(Server<DataAny>(bindAt: candidate, checkDuration: Duration.second * 30,
                    executors: 8, checker: {=> Message.ping()}))
                chosen = candidate
            } catch (_: Exception) {
                attempt++
            }
        }
        this.server = built.getOrThrow {MQStubException("cannot bind a free port")}
        this.port = chosen
    }

    /** 启动监听（后台线程），并等到端口可连接。 */
    public func start(): MQStubServer {
        let server = this.server
        let responder = this.responder
        let requests = this.requests
        let lock = this.lock
        spawn {
            server.start {buffer, request =>
                synchronized(lock) {
                    requests.add(request)
                }
                responder(buffer, request)
            }
        }
        // 等待端口就绪：探针连接会被 accept 后立即关闭
        var ready = false
        var tries = 0
        while (!ready && tries < 200) {
            try {
                let probe = TcpSocket(IPSocketAddress("127.0.0.1", port))
                probe.close()
                ready = true
            } catch (_: Exception) {
                sleep(Duration.millisecond * 10)
                tries++
            }
        }
        if (!ready) {
            throw MQStubException("stub server on port ${port} did not start")
        }
        this
    }

    public func address(): String {
        "127.0.0.1:${port}"
    }

    /** 已收到的请求快照。 */
    public func received(): Array<Message> {
        synchronized(lock) {
            requests.toArray()
        }
    }

    public func receivedCount(): Int64 {
        synchronized(lock) {
            requests.size
        }
    }

    public func clear(): Unit {
        synchronized(lock) {
            requests.clear()
        }
    }

    public func isClosed(): Bool {
        server.isClosed()
    }

    public func close(): Unit {
        server.close()
    }
}

class MQStubException <: Exception {
    init(message: String) {
        super(message)
    }
}
