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

import std.time.MonoTime
import fountain::f_net.client.Client
import fountain::f_protocol.default.{Command, Message, QoS}
import fountain::f_rpc.base.{RPCMessage, ServiceMeta}
import fountain::fprobe.rpc.NodeEndpoint

/** 一次定向 RPC 健康调用的结果。 */
public class HealthRpcResult {
    public let metrics: ?HealthMetrics
    public let error: String
    public let timedOut: Bool
    public let latencyMs: Float64

    public init(metrics: ?HealthMetrics, error: String, timedOut: Bool, latencyMs: Float64) {
        this.metrics = metrics
        this.error = error
        this.timedOut = timedOut
        this.latencyMs = latencyMs
    }
}

/** 可注入的定向健康调用抽象；用例返回预置结果，不启动真实端口。 */
public interface HealthRpcTransport {
    func call(target: NodeEndpoint, timeoutMs: Int64): HealthRpcResult
}

/**
 * 生产实现：每个目标临时建一个 `f_net.Client<RPCMessage>`，用 `Message.consume` 定向调用
 * `fountain::f_rpc.health.HealthRPC.health()`，不经过全局 `RPCClient` 的负载均衡与发现表。
 *
 * 服务端 `RPCSkeleton` 同时登记 `'*'` 版本，因此这里固定用 `version='*'`。
 */
public class FNetHealthRpcTransport <: HealthRpcTransport {
    public init() {}

    public func call(target: NodeEndpoint, timeoutMs: Int64): HealthRpcResult {
        let start = MonoTime.now()
        var client = None<Client<RPCMessage>>
        try {
            let connection = Client<RPCMessage>.builder(
                address: target.address(),
                checkDuration: Duration.second * 30,
                checker: {=> Message.ping()}
            ).pingTimeout(Duration.millisecond * timeoutMs).build()
            client = Some(connection)

            let meta = ServiceMeta('*', '', 'fountain::f_rpc.health.HealthRPC', 'health', [],
                0.0, exactlyVersion: true)
            let request = Message.consume<RPCMessage>(once: true, qos: QoS.AtMostOnce,
                data: RPCMessage(meta, []))
            let response = connection.transfer(request, Duration.millisecond * timeoutMs)
            interpretHealthResponse(response, elapsedMillis(start))
        } catch (e: Exception) {
            HealthRpcResult(None, 'RPC 调用失败: ${e.message}', false, elapsedMillis(start))
        } finally {
            match (client) {
                case Some(connection) =>
                    try {
                        connection.close()
                    } catch (_: Exception) {
                        ()
                    }
                case None => ()
            }
        }
    }
}

/** 把 RPC 响应映射为探针结果；`ERROR`/超时/非法 RESP 都收敛为 `error`。 */
public func interpretHealthResponse(response: ?Message, latencyMs: Float64): HealthRpcResult {
    match (response) {
        case None => HealthRpcResult(None, 'RPC 调用超时', true, latencyMs)
        case Some(message) =>
            match (message.command) {
                case Command.RESP(_) =>
                    match (HealthMetrics.tryFrom(message.data)) {
                        case Some(metrics) => HealthRpcResult(Some(metrics), "", false, latencyMs)
                        case None => HealthRpcResult(None, "RPC 响应不是合法 HealthData", false, latencyMs)
                    }
                case Command.ERROR => HealthRpcResult(None, 'RPC 返回 ERROR: ${message.data}', false, latencyMs)
                case other => HealthRpcResult(None, 'RPC 返回意外响应: ${other}', false, latencyMs)
            }
    }
}

private func elapsedMillis(start: MonoTime): Float64 {
    Float64((MonoTime.now() - start).toNanoseconds()) / 1000000.0
}
