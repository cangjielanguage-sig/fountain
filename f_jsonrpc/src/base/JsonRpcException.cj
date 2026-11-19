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

import std.io.IOException
import fountain::f_data.*

/**
 * 建连 / 发送阶段失败：**唯一可重试**的传输异常。
 *
 * 读响应阶段（服务端可能已经执行）失败必须是普通异常，不能被 `retryOnConnectFailure` 重试。
 */
public class JsonRpcConnectException <: IOException {
    public init(message: String) {
        super(message)
    }
}

/**
 * JSON-RPC 错误。handler 抛出它时，`code` / `message` / `data` 原样进入响应体。
 * 业务自定义错误码请落在 `-32020 ~ -32099`，不要占用 `-32001 ~ -32004`。
 */
public open class JsonRpcException <: Exception {
    public let code: Int64
    public let data: ?JsonValue

    public init(code: Int64, message: String, data!: ?JsonValue = None) {
        super(message)
        this.code = code
        this.data = data
    }
}

/** 响应体里的 `error` 对象。 */
public struct JsonRpcError {
    public const JsonRpcError(public let code: Int64, public let message: String, public let data: ?JsonValue) {}

    public static func from(ex: JsonRpcException): JsonRpcError {
        JsonRpcError(ex.code, ex.message, ex.data)
    }

    public func toJson(): JsonObject {
        let obj = JsonObject()
        obj.add('code', code)
        obj.add('message', message)
        match (data) {
            case Some(d) => obj.add('data', d)
            case _ => ()
        }
        obj
    }
}
