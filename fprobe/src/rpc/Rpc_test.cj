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
package fountain::fprobe.rpc

import std.reflect.TypeInfo
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.*
import fountain::f_probe.{ProbeAgent, ProbeErrorCode, ProbeException, ProbeRegistry}
import fountain::f_protocol.default.{Message, MessageID, QoS}
import fountain::f_rpc.base.RPCMessage
import fountain::fprobe.snapshot.{ProbeAgentData, ProbeKinds, ProbeSnapshot, SnapshotStore}

/** `@RPCStub` 必须能展开出可用的桩类（编译期即验证契约可被宏消费）。 */
@Test
public class ProbeRPCStub_test {
    @TestCase
    public func stubTypeIsGenerated(): Unit {
        let name = TypeInfo.of<ProbeRPC_Stub__>().qualifiedName
        @Assert(name.endsWith("ProbeRPC_Stub__"))
    }
}

/** 7.4：三个 DTO 的 JSON 编解码往返，覆盖中文与特殊字符。 */
@Test
public class ProbeDTOTest {
    @TestCase
    public func agentDataRoundTrips(): Unit {
        let original = ProbeAgentData("cpu", "主机-a", '{"msg":"中文 \\"quoted\\" <>&","n":1.5}', 1720000000000, "")
        let text = JsonValue.from(original.toData()).toString()
        let restored = DataObject<ProbeAgentData>.populate(JsonValue.fromStr(text).toData()).getOrThrow()
        @Assert(restored.kind, original.kind)
        @Assert(restored.host, original.host)
        @Assert(restored.dataJson, original.dataJson)
        @Assert(restored.collectedAt, original.collectedAt)
        @Assert(restored.error, original.error)
    }

    @TestCase
    public func snapshotRoundTrips(): Unit {
        let original = ProbeSnapshot("节点-1", "主机-a", 1720000000001,
            [
                ProbeAgentData("cpu", "主机-a", '{"usage":"中文"}', 1720000000001, ""),
                ProbeAgentData("disk", "主机-a", "{}", 1720000000001, "采集失败")
            ])
        let text = JsonValue.from(original.toData()).toString()
        let restored = DataObject<ProbeSnapshot>.populate(JsonValue.fromStr(text).toData()).getOrThrow()
        @Assert(restored.node, original.node)
        @Assert(restored.host, original.host)
        @Assert(restored.timestamp, original.timestamp)
        @Assert(restored.agents.size, 2)
        @Assert(restored.agents[0].kind, original.agents[0].kind)
        @Assert(restored.agents[0].host, original.agents[0].host)
        @Assert(restored.agents[0].dataJson, original.agents[0].dataJson)
        @Assert(restored.agents[1].error, original.agents[1].error)
    }

    @TestCase
    public func kindsRoundTrip(): Unit {
        let original = ProbeKinds(["cpu", "memory", "disk"])
        let text = JsonValue.from(original.toData()).toString()
        let restored = DataObject<ProbeKinds>.populate(JsonValue.fromStr(text).toData()).getOrThrow()
        @Assert(restored.kinds.size, 3)
        @Assert(restored.kinds[0], "cpu")
        @Assert(restored.kinds[2], "disk")
    }
}

/** 7.2：实现直接读快照仓库与注册表。 */
@Test
public class ProbeRPCImpl_test {
    @TestCase
    public func collectReadsStoreAndKindsReadsRegistry(): Unit {
        let store = SnapshotStore()
        store.replace(ProbeSnapshot("node", "host", 7,
            [ProbeAgentData("cpu", "host", '{"v":1}', 7, "")]))
        let impl = ProbeRPCImpl(store)

        let snapshot = impl.collect()
        @Assert(snapshot.node, "node")
        @Assert(snapshot.timestamp, 7)
        @Assert(snapshot.agents.size, 1)

        ProbeRegistry.clear()
        ProbeRegistry.registerAgent("cpu", {=> StubAgent("cpu")})
        ProbeRegistry.registerAgent("memory", {=> StubAgent("memory")})
        let kinds = impl.kinds().kinds
        @Assert(kinds.size, 2)
        @Assert(kinds.contains("cpu"))
        @Assert(kinds.contains("memory"))
        ProbeRegistry.clear()
    }

    /** 无参构造 + install：供 @Bean 在服务启动时使用同一份快照仓库。 */
    @TestCase
    public func installedStoreIsUsedByDefaultConstructor(): Unit {
        let store = SnapshotStore()
        store.replace(ProbeSnapshot("installed", "host", 9, []))
        ProbeRPCImpl.install(store)
        let impl = ProbeRPCImpl()
        @Assert(impl.collect().node, "installed")
        ProbeRPCImpl.reset()
    }
}

/** 7.3：定向传输的请求构造、超时、ERROR 映射与失败重连。 */
@Test
public class NodeRpcTransport_test {
    @TestCase
    public func collectSendsDirectedMessageAndReturnsSnapshot(): Unit {
        let snapshot = ProbeSnapshot("node-1", "host-1", 10,
            [ProbeAgentData("cpu", "host-1", '{"v":1}', 10, "")])
        let transport = FakeClientTransport([Some(resp(snapshot))])
        let rpc = NodeRpcTransport(NodeEndpoint("node-1", "127.0.0.1", 1), 500, {_ => transport})

        let result = rpc.collect()
        @Assert(result.node, "node-1")
        @Assert(result.agents.size, 1)
        @Assert(result.agents[0].dataJson, '{"v":1}')

        let request = convert<RPCMessage>(transport.lastRequest.getOrThrow().data).getOrThrow()
        @Assert(request.meta.version, "*")
        @Assert(request.meta.typeName, "fountain::fprobe.rpc.ProbeRPC")
        @Assert(request.meta.methodName, "collect")
        @Assert(request.params.size, 0)
    }

    @TestCase
    public func kindsSendsKindsMethod(): Unit {
        let transport = FakeClientTransport([Some(respKinds(ProbeKinds(["cpu", "disk"])))])
        let rpc = NodeRpcTransport(NodeEndpoint("node-1", "127.0.0.1", 1), 500, {_ => transport})
        let kinds = rpc.kinds()
        @Assert(kinds.kinds.size, 2)
        let request = convert<RPCMessage>(transport.lastRequest.getOrThrow().data).getOrThrow()
        @Assert(request.meta.methodName, "kinds")
    }

    @TestCase
    public func timeoutClosesClientAndReconnects(): Unit {
        let first = FakeClientTransport([noneResponse()])
        let second = FakeClientTransport([Some(resp(ProbeSnapshot("node-1", "h", 1, [])))])
        let scripts: Array<ClientTransport> = [first, second]
        let builds = AtomicInt64(0)
        let rpc = NodeRpcTransport(NodeEndpoint("node-1", "127.0.0.1", 1), 500, {_ =>
            let index = builds.fetchAdd(1)
            scripts[index]
        })

        var caught = false
        try {
            rpc.collect()
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("timeout") || e.message.contains("超时"))
        }
        @Assert(caught)
        @Assert(first.closed)
        @Assert(builds.load(), 1)

        let snapshot = rpc.collect()
        @Assert(snapshot.node, "node-1")
        @Assert(builds.load(), 2)
    }

    @TestCase
    public func errorResponseMapsToCollectException(): Unit {
        let transport = FakeClientTransport([Some(Message.error(MessageID(hostId: 1), data: "collect exploded"))])
        let rpc = NodeRpcTransport(NodeEndpoint("node-1", "127.0.0.1", 1), 500, {_ => transport})
        var caught = false
        try {
            rpc.collect()
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("collect exploded"))
        }
        @Assert(caught)
    }

    @TestCase
    public func transferExceptionClosesClientAndReconnects(): Unit {
        let first = FakeClientTransport([])
        first.failOnTransfer = true
        let second = FakeClientTransport([Some(resp(ProbeSnapshot("node-1", "h", 1, [])))])
        let scripts: Array<ClientTransport> = [first, second]
        let builds = AtomicInt64(0)
        let rpc = NodeRpcTransport(NodeEndpoint("node-1", "127.0.0.1", 1), 500, {_ =>
            let index = builds.fetchAdd(1)
            scripts[index]
        })

        var caught = false
        try {
            rpc.collect()
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("socket boom"))
        }
        @Assert(caught)
        @Assert(first.closed)

        @Assert(rpc.collect().node, "node-1")
        @Assert(builds.load(), 2)
    }
}

private func noneResponse(): ?Message {
    None<Message>
}

private func resp(snapshot: ProbeSnapshot): Message {
    Message.resp(MessageID(hostId: 1), qos: QoS.AtMostOnce, ack: false, data: snapshot.toData())
}

private func respKinds(kinds: ProbeKinds): Message {
    Message.resp(MessageID(hostId: 1), qos: QoS.AtMostOnce, ack: false, data: kinds.toData())
}

private class StubAgent <: ProbeAgent {
    private let name: String

    init(name: String) {
        this.name = name
    }

    public prop kind: String {
        get() {
            name
        }
    }

    public prop data: JsonObject {
        get() {
            JsonObject()
        }
    }
}

class FakeClientTransport <: ClientTransport {
    private let responses: Array<?Message>
    private var index: Int64 = 0
    public var closed: Bool = false
    public var lastRequest: ?Message = None<Message>
    public var failOnTransfer: Bool = false

    public init(responses: Array<?Message>) {
        this.responses = responses
    }

    public func transfer(message: Message, timeout: Duration): ?Message {
        lastRequest = Some(message)
        if (failOnTransfer) {
            throw Exception("socket boom")
        }
        let current = index
        index += 1
        if (current >= responses.size) {
            return None<Message>
        }
        responses[current]
    }

    public func close(): Unit {
        closed = true
    }
}
