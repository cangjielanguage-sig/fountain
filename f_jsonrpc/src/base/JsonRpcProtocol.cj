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
package fountain::f_jsonrpc.base

/** JSON-RPC 2.0 协议常量。码段划分见 `f_jsonrpc/doc/f_jsonrpc模块设计.md` 4.6。 */
public class JsonRpcProtocol {
    public static const VERSION = '2.0'
    /** 默认端点路径 */
    public static const PATH = '/rpc'
    /** 带 topic 的端点路径 */
    public static const TOPIC_PATH = '/rpc/{topic}'

    // —— 标准错误码 ——
    public static const PARSE_ERROR = -32700
    public static const INVALID_REQUEST = -32600
    public static const METHOD_NOT_FOUND = -32601
    public static const INVALID_PARAMS = -32602
    public static const INTERNAL_ERROR = -32603

    // —— 框架保留段（业务不要占用）——
    /** 保留：当前实现不产生这个码（只为兼容客户端的老分支保留常量）。 */
    public static const SERVER_ERROR = -32001
    public static const TIMEOUT = -32002
    public static const OVERLOADED = -32003
    public static const UNKNOWN_TOPIC = -32004

    /** 单次批量请求的默认条数上限 */
    public static const DEFAULT_MAX_BATCH_SIZE = 100

    public static func messageOf(code: Int64): String {
        if (code == -32700) {
            return 'Parse error'
        } else if (code == -32600) {
            return 'Invalid Request'
        } else if (code == -32601) {
            return 'Method not found'
        } else if (code == -32602) {
            return 'Invalid params'
        } else if (code == -32603) {
            return 'Internal error'
        } else if (code == -32001) {
            return 'Server error'
        } else if (code == -32002) {
            return 'Timeout'
        } else if (code == -32003) {
            return 'Overloaded'
        } else if (code == -32004) {
            return 'Unknown topic'
        }
        'Error'
    }
}
