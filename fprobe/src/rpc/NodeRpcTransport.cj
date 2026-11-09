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

import std.sync.Mutex
import fountain::f_data.*
import fountain::f_net.client.Client
import fountain::f_probe.{ProbeErrorCode, ProbeException}
import fountain::f_protocol.default.{Command, Message, QoS}
import fountain::f_rpc.base.{RPCMessage, ServiceMeta}
import fountain::fprobe.snapshot.{ProbeKinds, ProbeSnapshot}

/**
 * 定向传输的最小抽象。
 *
 * 生产实现包 `f_net.Client`，用例注入脚本化替身，从而在不监听真实端口的前提下
 * 覆盖超时、ERROR 与重连。
 */
public interface ClientTransport {
    func transfer(message: Message, timeout: Duration): ?Message

    func close(): Unit
}

/** `f_net.Client` 的适配器。 */
public class NetClientTransport <: ClientTransport {
    private let client: Client<RPCMessage>

    public init(client: Client<RPCMessage>) {
        this.client = client
    }

    public func transfer(message: Message, timeout: Duration): ?Message {
        client.transfer(message, timeout)
    }

    public func close(): Unit {
        client.close()
    }
}

/**
 * 单节点的定向 RPC 传输。
 *
 * 全局 `RPCClient` 会按权重挑选节点，无法把调用固定到 supervisor 选中的主机；
 * 这里每节点维护一个 `Client<RPCMessage>`，失败后关闭并在下次调用时重建。
 */
public class NodeRpcTransport {
    public static let SERVICE_TYPE = "fountain::fprobe.rpc.ProbeRPC"

    private let node: NodeEndpoint
    private let timeout: Duration
    private let clientBuilder: (String) -> ClientTransport
    private let lock = Mutex()
    private var client: ?ClientTransport = None

    public init(node: NodeEndpoint) {
        this(node, 3000)
    }

    public init(node: NodeEndpoint, timeoutMs: Int64) {
        this(node, timeoutMs, {address => createNetClient(address)})
    }

    public init(node: NodeEndpoint, timeoutMs: Int64, clientBuilder: (String) -> ClientTransport) {
        this.node = node
        this.timeout = Duration.millisecond * timeoutMs
        this.clientBuilder = clientBuilder
    }

    /** 拉取一次完整快照。 */
    public func collect(): ProbeSnapshot {
        let response = call("collect")
        match (convert<ProbeSnapshot>(response.data)) {
            case Some(value) => value
            case None => throw ProbeException(ProbeErrorCode.COLLECT, '${node.name} collect 响应不是 ProbeSnapshot')
        }
    }

    /** 拉取节点支持的监控项列表。 */
    public func kinds(): ProbeKinds {
        let response = call("kinds")
        match (convert<ProbeKinds>(response.data)) {
            case Some(value) => value
            case None => throw ProbeException(ProbeErrorCode.COLLECT, '${node.name} kinds 响应不是 ProbeKinds')
        }
    }

    /** 主动关闭到该节点的连接。 */
    public func close(): Unit {
        synchronized(lock) {
            dropClient()
        }
    }

    private func call(method: String): Message {
        synchronized(lock) {
            let message = buildRequest(method)
            let active = requireClient(method)

            var response: ?Message = None
            try {
                response = active.transfer(message, timeout)
            } catch (e: Exception) {
                dropClient()
                throw ProbeException(ProbeErrorCode.COLLECT, '${node.name} ${method} 调用失败: ${e.message}', e)
            }

            match (response) {
                case Some(value) =>
                    match (value.command) {
                        case Command.RESP(_) => value
                        case Command.ERROR =>
                            throw ProbeException(ProbeErrorCode.COLLECT,
                                '${node.name} ${method} 返回错误: ${value.data}')
                        case other =>
                            throw ProbeException(ProbeErrorCode.COLLECT,
                                '${node.name} ${method} 返回非预期命令: ${other}')
                    }
                case None =>
                    dropClient()
                    throw ProbeException(ProbeErrorCode.COLLECT, '${node.name} ${method} 超时（${timeout}）')
            }
        }
    }

    private func buildRequest(method: String): Message {
        let meta = ServiceMeta("*", "", SERVICE_TYPE, method, [], 0.0, exactlyVersion: true)
        Message.consume<RPCMessage>(once: true, qos: QoS.AtMostOnce, data: RPCMessage(meta, []))
    }

    /** 取当前连接；不存在或已丢弃时重建。调用方必须持有 `lock`。 */
    private func requireClient(method: String): ClientTransport {
        match (client) {
            case Some(value) => value
            case None =>
                var created: ?ClientTransport = None
                try {
                    created = Some(clientBuilder(node.address()))
                } catch (e: Exception) {
                    throw ProbeException(ProbeErrorCode.COLLECT,
                        '${node.name} ${method} 连接失败: ${e.message}', e)
                }
                let resolved = created.getOrThrow()
                client = Some(resolved)
                resolved
        }
    }

    /** 关闭并清空缓存的连接。调用方必须持有 `lock`。 */
    private func dropClient(): Unit {
        match (client) {
            case Some(value) =>
                try {
                    value.close()
                } catch (_: Exception) {
                    ()
                }
                client = None
            case None => ()
        }
    }
}

func createNetClient(address: String): ClientTransport {
    let client = Client<RPCMessage>.builder(
        address: address,
        checkDuration: Duration.second,
        checker: {=> Some(Message.ping())}
    ).build()
    NetClientTransport(client)
}
