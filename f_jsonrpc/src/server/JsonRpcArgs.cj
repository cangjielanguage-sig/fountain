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
package fountain::f_jsonrpc.server

import fountain::f_data.*
import fountain::f_jsonrpc.base.*

/**
 * `@JsonRpc` 展开出来的参数 / 返回值转换。
 *
 * 单参数直接用整个 `params`；多参数要求 `params` 是对象，按参数名取。
 * 转换失败统一抛 `-32602`。
 */
public class JsonRpcArgs {
    public static func extract<T>(params: ?JsonValue, name: String, named!: Bool): T where T <: DataFields<T> {
        let value = if (named) {
            match (params) {
                case Some(obj: JsonObject) => match (obj.get(name)) {
                    case Some(v) => v
                    case _ => throw JsonRpcException(JsonRpcProtocol.INVALID_PARAMS, "missing parameter '${name}'",
                        data: JsonString(name))
                }
                case _ => throw JsonRpcException(JsonRpcProtocol.INVALID_PARAMS,
                    'params must be an object for a multi-parameter method', data: JsonString(name))
            }
        } else {
            match (params) {
                case Some(array: JsonArray) =>
                    if (array.size == 1) {
                        array[0]
                    } else {
                        throw JsonRpcException(JsonRpcProtocol.INVALID_PARAMS,
                            "single parameter '${name}' expects exactly one element", data: JsonString(name))
                    }
                case Some(obj: JsonObject) => match (obj.get(name)) {
                    case Some(v) => v
                    case _ => obj
                }
                case Some(v) => v
                case _ => throw JsonRpcException(JsonRpcProtocol.INVALID_PARAMS, "missing parameter '${name}'",
                    data: JsonString(name))
            }
        }
        match (convert<T>(value.toData())) {
            case Some(v) => v
            case _ => throw JsonRpcException(JsonRpcProtocol.INVALID_PARAMS, "invalid parameter '${name}'",
                data: JsonString(name))
        }
    }

    public static func toJson<T>(value: T): JsonValue where T <: DataFields<T> {
        JsonValue.from(value.toData())
    }

    public static func toJson(value: Unit): JsonValue {
        JsonNull.instance
    }
}
