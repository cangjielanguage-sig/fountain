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
package fountain::f_dbd.multid

import std.net.{IPSocketAddress, TcpServerSocket}
import std.sync.AtomicInt64
import fountain::f_data.DataAny
import fountain::f_net.server.Server
import fountain::f_protocol.default.*
import fountain::f_dbd.common.UpdateResultPayload

/**
 * 多节点用例的最小 fdbm 桩：回环 + 随机端口，统计收到的 `CONSUME` 条数。
 *
 * `respond = false` 时静默（用于超时用例）；`PING` 由 `Server` 内置回 `ACK`。
 */
class MultiStub {
    private let server: Server<DataAny>
    private let hits = AtomicInt64(0)
    let port: UInt16

    init(respond!: Bool = true) {
        let p = freePortOf()
        this.port = p
        this.server = Server<DataAny>(bindAt: p, checkDuration: Duration.second * 30, checker: {=> Message.ping()})
        spawn {
            try {
                server.start {_, request =>
                    if (respond) {
                        hits.fetchAdd(1)
                        Message.resp(request.id, qos: QoS.AtMostOnce, ack: false,
                            data: UpdateResultPayload(1, 0))
                    } else {
                        None<Message>
                    }
                }
            } catch (_: Exception) {
                // close() 会把 accept() 带出来，属正常收尾
            }
        }
    }

    /** 收到的 `CONSUME` 条数。 */
    func received(): Int64 {
        hits.load()
    }

    func close(): Unit {
        server.close()
    }
}

/** 探测一个空闲端口（bind 0 → 取内核分配的端口 → 关闭）。 */
func freePortOf(): UInt16 {
    let probe = TcpServerSocket(bindAt: 0)
    probe.bind()
    var port: UInt16 = 0
    match (probe.localAddress) {
        case address: IPSocketAddress => port = address.port
        case _ => port = 0
    }
    probe.close()
    port
}
