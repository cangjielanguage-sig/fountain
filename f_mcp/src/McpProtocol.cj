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
package fountain::f_mcp

import std.convert.Parsable
import stdx.encoding.base64.*

/** MCP 协议常量。 */
public class McpProtocol {
    public static const VERSION = '2026-07-28'
    public static const PATH = '/mcp'
    public static const SSE_PATH = '/mcp/sse'
    public static const TOOL_RESULT_PREFIX = '/mcp/tool-results/'

    public static const META = '_meta'
    public static const KEY_PROTOCOL_VERSION = 'io.modelcontextprotocol/protocolVersion'
    public static const KEY_CLIENT_INFO = 'io.modelcontextprotocol/clientInfo'
    public static const KEY_CLIENT_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities'
    public static const KEY_SERVER_INFO = 'io.modelcontextprotocol/serverInfo'

    // 错误码
    public static const METHOD_NOT_FOUND = -32601
    public static const INVALID_PARAMS = -32602
    public static const INTERNAL_ERROR = -32603
    public static const RESOURCE_NOT_FOUND = -32002
    public static const UNSUPPORTED_VERSION = -32022
    public static const RATE_LIMITED = -32050

    public static func isToolName(name: String): Bool {
        if (name.isEmpty() || name.size > 128) {
            return false
        }
        for (c in name.toRuneArray()) {
            if (!((c >= r'a' && c <= r'z') || (c >= r'A' && c <= r'Z') || (c >= r'0' && c <= r'9') || c == r'_' || c ==
                r'-' || c == r'.')) {
                return false
            }
        }
        true
    }

    public static func encodeCursor(offset: Int64): String {
        toBase64String("offset:${offset}".toArray())
    }

    public static func decodeCursor(cursor: String): Int64 {
        if (cursor.isEmpty()) {
            return 0
        }
        match (fromBase64String(cursor)) {
            case Some(bytes) =>
                let text = try {
                    String.fromUtf8(bytes)
                } catch (_: Exception) {
                    return 0
                }
                if (text.startsWith('offset:')) {
                    return Int64.tryParse(text[7..]) ?? 0
                }
                0
            case _ => 0
        }
    }
}
