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

import std.net.{TcpSocket, IPSocketAddress}
import std.time.MonoTime

/** 一次 TCP 连接尝试的结果。 */
public struct TcpProbeResult {
    public let reachable: Bool
    public let latencyMs: Float64
    public let error: String

    public init(reachable: Bool, latencyMs: Float64, error: String) {
        this.reachable = reachable
        this.latencyMs = latencyMs
        this.error = error
    }
}

/** TCP 连通性探测抽象；用例可注入假实现或本地监听端口。 */
public interface TcpProbe {
    func connect(host: String, port: UInt16, timeoutMs: Int64): TcpProbeResult
}

/** 生产实现：直接 `TcpSocket` 建连并立即关闭，只验证三次握手。 */
public class StdTcpProbe <: TcpProbe {
    public init() {}

    public func connect(host: String, port: UInt16, timeoutMs: Int64): TcpProbeResult {
        let start = MonoTime.now()
        try {
            let socket = TcpSocket(IPSocketAddress(host, port))
            socket.connect(timeout: Duration.millisecond * timeoutMs)
            socket.close()
            TcpProbeResult(true, elapsedMillis(start), "")
        } catch (e: Exception) {
            TcpProbeResult(false, elapsedMillis(start), '连接失败: ${e.message}')
        }
    }
}

private func elapsedMillis(start: MonoTime): Float64 {
    Float64((MonoTime.now() - start).toNanoseconds()) / 1000000.0
}
