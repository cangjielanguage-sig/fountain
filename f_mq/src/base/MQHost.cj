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
package fountain::f_mq.base

import std.convert.*

/**
 * `host:port` 解析：客户端与服务端共用。
 *
 * 去空白后按单个冒号切分；缺少端口、端口为 0 或越界、主机/端口为空都返回 `None`。
 */
public class MQHost {
    public static func parseHost(entry: String): ?(String, UInt16) {
        let text = entry.trimAscii()
        if (text.isEmpty()) {
            return None<(String, UInt16)>
        }
        let parts = text.split(":")
        if (parts.size != 2) {
            return None<(String, UInt16)>
        }
        let host = parts[0].trimAscii()
        let portText = parts[1].trimAscii()
        if (host.isEmpty() || portText.isEmpty()) {
            return None<(String, UInt16)>
        }
        match (UInt16.tryParse(portText)) {
            case None => None<(String, UInt16)>
            case Some(port) =>
                if (port == 0) {
                    None<(String, UInt16)>
                } else {
                    Some((host, port))
                }
        }
    }
}
