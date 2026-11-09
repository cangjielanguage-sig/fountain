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

import std.convert.*

/**
 * supervisor 配置中的一个 agent 节点。
 *
 * 展示名与网络地址分开保存：节点名是历史窗口与告警的稳定键，host/port 只用于建连。
 */
public class NodeEndpoint {
    public let name: String
    public let host: String
    public let port: UInt16

    public init(name: String, host: String, port: UInt16) {
        this.name = name
        this.host = host
        this.port = port
    }

    /** 解析 `name@host:port`；格式非法返回 None，由调用方聚合成启动错误。 */
    public static func parse(spec: String): ?NodeEndpoint {
        let text = spec.trimAscii()
        let atIndex = match (text.indexOf('@')) {
            case Some(index) => index
            case None => return None
        }
        let name = text[0..atIndex].trimAscii()
        let address = text[atIndex + 1..].trimAscii()
        if (name.isEmpty() || address.isEmpty()) {
            return None
        }

        let colonIndex = match (address.lastIndexOf(':')) {
            case Some(index) => index
            case None => return None
        }
        let host = address[0..colonIndex].trimAscii()
        let portText = address[colonIndex + 1..].trimAscii()
        if (host.isEmpty() || portText.isEmpty()) {
            return None
        }

        let port = match (Int64.tryParse(portText)) {
            case Some(value) => value
            case None => return None
        }
        if (port < 1 || port > 65535) {
            return None
        }
        NodeEndpoint(name, host, UInt16(port))
    }

    public func address(): String {
        "${host}:${port}"
    }

    public func toString(): String {
        "${name}@${host}:${port}"
    }
}
