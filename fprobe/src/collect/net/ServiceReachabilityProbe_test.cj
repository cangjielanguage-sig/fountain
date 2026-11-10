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
package fountain::fprobe.collect.net

import std.net.{IPSocketAddress, TcpServerSocket}
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.JsonObject
import fountain::fprobe.collect.health.{HttpProbe, HttpProbeResult}

class HttpStub <: HttpProbe {
    private let result: HttpProbeResult

    init(result: HttpProbeResult) {
        this.result = result
    }

    public func get(url: String, timeoutMs: Int64): HttpProbeResult {
        result
    }
}

class TcpStub <: TcpProbe {
    private let result: TcpProbeResult

    init(result: TcpProbeResult) {
        this.result = result
    }

    public func connect(host: String, port: UInt16, timeoutMs: Int64): TcpProbeResult {
        result
    }
}

/** 起一个只接受连接的本地监听端口；返回监听器与端口。 */
private func listeningPort(): (TcpServerSocket, UInt16) {
    let listener = TcpServerSocket(bindAt: 0)
    listener.bind()
    var port: UInt16 = 0
    match (listener.localAddress) {
        case address: IPSocketAddress => port = address.port
        case _ => ()
    }
    let socket = listener
    spawn {
        while (true) {
            try {
                let accepted = socket.accept()
                accepted.close()
            } catch (_: Exception) {
                break
            }
        }
    }
    (listener, port)
}

@Test
public class ServiceReachabilityProbe_test {
    private func probe(http: HttpProbe, targets: Array<String>): JsonObject {
        ServiceReachabilityProbe(http, StdTcpProbe(), targets).data
    }

    @TestCase
    public func http200IsReachable(): Unit {
        let http = HttpStub(HttpProbeResult(200, "ok", 12.0, false, ""))
        let target = probe(http, ["web@http://127.0.0.1:8080/health"]).get("targets").getOrThrow().asArray()[0]
            .asObject()
        @Assert(target.get("name").getOrThrow().asString().value, "web")
        @Assert(target.get("reachable").getOrThrow().asBool().value)
        @Assert(target.get("statusCode").getOrThrow().asInt().toInt64(), 200)
        @Assert(target.get("latencyMs").getOrThrow().asDecimal().toFloat64(), 12.0)
        @Assert(target.get("error").getOrThrow().asString().value.isEmpty())
    }

    @TestCase
    public func http500IsUnreachable(): Unit {
        let http = HttpStub(HttpProbeResult(500, "boom", 5.0, false, ""))
        let target = probe(http, ["web@http://127.0.0.1:8080/health"]).get("targets").getOrThrow().asArray()[0]
            .asObject()
        @Assert(!target.get("reachable").getOrThrow().asBool().value)
        @Assert(target.get("statusCode").getOrThrow().asInt().toInt64(), 500)
        @Assert(target.get("error").getOrThrow().asString().value.contains("500"))
    }

    @TestCase
    public func httpTimeoutIsUnreachable(): Unit {
        let http = HttpStub(HttpProbeResult(0, "", 2000.0, true, "HTTP 请求超时"))
        let target = probe(http, ["web@http://127.0.0.1:8080/health"]).get("targets").getOrThrow().asArray()[0]
            .asObject()
        @Assert(!target.get("reachable").getOrThrow().asBool().value)
        @Assert(target.get("error").getOrThrow().asString().value.contains("超时"))
    }

    @TestCase
    public func localListeningPortIsReachable(): Unit {
        let (listener, port) = listeningPort()
        let target = ServiceReachabilityProbe(HttpStub(HttpProbeResult(200, "", 0.0, false, "")), StdTcpProbe(),
            ['tcp@tcp://127.0.0.1:${port}']).data.get("targets").getOrThrow().asArray()[0].asObject()
        @Assert(target.get("reachable").getOrThrow().asBool().value)
        @Assert(target.get("error").getOrThrow().asString().value.isEmpty())
        listener.close()
    }

    @TestCase
    public func refusedPortIsUnreachable(): Unit {
        // 端口 1 只用于构造「确定没有监听者」的地址，不是为了真正访问服务。
        let target = ServiceReachabilityProbe(HttpStub(HttpProbeResult(200, "", 0.0, false, "")), StdTcpProbe(),
            ["tcp@tcp://127.0.0.1:1"]).data.get("targets").getOrThrow().asArray()[0].asObject()
        @Assert(!target.get("reachable").getOrThrow().asBool().value)
        @Assert(!target.get("error").getOrThrow().asString().value.isEmpty())
    }

    @TestCase
    public func malformedTargetIsIsolated(): Unit {
        let http = HttpStub(HttpProbeResult(200, "ok", 1.0, false, ""))
        let targets = probe(http, ["bad", "web@http://127.0.0.1:8080/health"]).get("targets").getOrThrow().asArray()
        @Assert(targets.size, 2)
        @Assert(!targets[0].asObject().get("reachable").getOrThrow().asBool().value)
        @Assert(targets[0].asObject().get("error").getOrThrow().asString().value.contains("格式非法"))
        @Assert(targets[1].asObject().get("reachable").getOrThrow().asBool().value)
    }
}
