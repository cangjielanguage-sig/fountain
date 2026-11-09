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
package fountain::fprobe.collect.health

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_protocol.default.{Message, MessageID, QoS}
import fountain::fprobe.rpc.NodeEndpoint

class FakeHealthRpcTransport <: HealthRpcTransport {
    private let result: HealthRpcResult

    init(result: HealthRpcResult) {
        this.result = result
    }

    public func call(target: NodeEndpoint, timeoutMs: Int64): HealthRpcResult {
        result
    }
}

private func metrics(): HealthMetrics {
    HealthMetrics(1024, 2048, 1, 3, 4096, 10, 8192, 2, 8, 16, 512)
}

@Test
public class RpcHealthProbe_test {
    @TestCase
    public func mapsHealthFieldsAndLatency(): Unit {
        let transport = FakeHealthRpcTransport(HealthRpcResult(Some(metrics()), "", false, 8.5))
        let data = RpcHealthProbe(transport, [NodeEndpoint("node1", "127.0.0.1", 12323)]).data
        let targets = data.get("targets").getOrThrow().asArray()
        @Assert(targets.size, 1)
        let target = targets[0].asObject()
        @Assert(target.get("name").getOrThrow().asString().value, "node1")
        @Assert(target.get("latencyMs").getOrThrow().asDecimal().toFloat64(), 8.5)
        @Assert(target.get("allocatedHeapSize").getOrThrow().asInt().toInt64(), 1024)
        @Assert(target.get("processorCount").getOrThrow().asInt().toInt64(), 8)
        @Assert(target.get("usedHeapSize").getOrThrow().asInt().toInt64(), 512)
        @Assert(target.get("error").getOrThrow().asString().value.isEmpty())
    }

    @TestCase
    public func failedCallMapsToProbeError(): Unit {
        let transport = FakeHealthRpcTransport(HealthRpcResult(None, "RPC 返回 ERROR: boom", false, 3.0))
        let data = RpcHealthProbe(transport, [NodeEndpoint("node1", "127.0.0.1", 12323)]).data
        let target = data.get("targets").getOrThrow().asArray()[0].asObject()
        @Assert(target.get("error").getOrThrow().asString().value.contains("ERROR"))
        @Assert(target.get("latencyMs").getOrThrow().asDecimal().toFloat64(), 3.0)
    }

    @TestCase
    public func timeoutMapsToProbeError(): Unit {
        let transport = FakeHealthRpcTransport(HealthRpcResult(None, "RPC 调用超时", true, 3000.0))
        let target = RpcHealthProbe(transport, [NodeEndpoint("node1", "127.0.0.1", 12323)]).data
            .get("targets").getOrThrow().asArray()[0].asObject()
        @Assert(target.get("error").getOrThrow().asString().value.contains("超时"))
    }

    /** 直接覆盖 `Command.ERROR` → 探针错误的映射。 */
    @TestCase
    public func errorCommandMapsToProbeError(): Unit {
        let response = Message.error(MessageID(hostId: 1), data: DataAny(DataString("boom")))
        let result = interpretHealthResponse(Some(response), 1.0)
        @Assert(result.metrics.isNone())
        @Assert(result.error.contains("boom"))
        @Assert(!result.timedOut)
    }

    /** 直接覆盖 `Command.RESP` → HealthMetrics 的映射。 */
    @TestCase
    public func respCommandMapsToHealthMetrics(): Unit {
        let response = Message.resp(MessageID(hostId: 1), qos: QoS.AtMostOnce, ack: true,
            data: DataAny(metrics().toData()))
        let result = interpretHealthResponse(Some(response), 2.5)
        @Assert(result.metrics.isSome())
        @Assert(result.metrics.getOrThrow().allocatedHeapSize, 1024)
        @Assert(result.latencyMs, 2.5)
    }

    @TestCase
    public func missingResponseMapsToTimeout(): Unit {
        let result = interpretHealthResponse(None<Message>, 3000.0)
        @Assert(result.metrics.isNone())
        @Assert(result.timedOut)
        @Assert(result.error.contains("超时"))
    }

    @TestCase
    public func emptyTargetsProduceEmptyList(): Unit {
        let data = RpcHealthProbe(FakeHealthRpcTransport(HealthRpcResult(None, "", false, 0.0)), []).data
        @Assert(data.get("targets").getOrThrow().asArray().isEmpty())
    }
}
