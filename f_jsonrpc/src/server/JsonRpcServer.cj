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

import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.time.MonoTime
import stdx.log.LogLevel
import fountain::f_data.*
import fountain::f_log.impl.*
import fountain::f_mvc.MVCConfig
import fountain::f_jsonrpc.base.*

/**
 * JSON-RPC 2.0 服务端：方法表 + 编解码 + 错误映射。不依赖 HTTP，
 * 可以被 stdio / 本地直调复用。
 */
public class JsonRpcServer {
    static let log = LoggerFactory.getLogger<JsonRpcServer>()

    private let endpointName: String
    private let maxBatchSize: Int64
    private let maxBodyBytes: Int64
    private let methods_ = ConcurrentHashMap<String, JsonRpcMethodMeta>()

    init(endpointName: String, maxBatchSize: Int64, maxBodyBytes: Int64, initial: ArrayList<JsonRpcMethodMeta>) {
        this.endpointName = endpointName
        this.maxBatchSize = maxBatchSize
        this.maxBodyBytes = maxBodyBytes
        for (m in initial) {
            addMethod(m)
        }
    }

    public static func builder(): JsonRpcServerBuilder {
        JsonRpcServerBuilder()
    }

    /** 注册方法。重复注册抛异常，不覆盖已有方法。运行期可调用（线程安全）。 */
    public func addMethod(meta: JsonRpcMethodMeta): Unit {
        if (let Some(_) <- methods_.addIfAbsent(meta.name, meta)) {
            throw JsonRpcException(JsonRpcProtocol.INTERNAL_ERROR, "duplicate json-rpc method '${meta.name}'")
        }
    }

    /** 方法元数据，按方法名升序（供上层生成稳定的 `tools/list`）。 */
    public func methods(): ArrayList<JsonRpcMethodMeta> {
        let list = ArrayList<JsonRpcMethodMeta>()
        for ((_, m) in methods_) {
            list.add(m)
        }
        // 方法数很少（几十个），插入排序足够，且不依赖 T <: Comparable
        for (i in 1..list.size) {
            var j = i
            while (j > 0 && list[j].name < list[j - 1].name) {
                let tmp = list[j]
                list[j] = list[j - 1]
                list[j - 1] = tmp
                j--
            }
        }
        list
    }

    public prop endpoint: String {
        get() {
            endpointName
        }
    }

    /**
     * 处理一段原始请求体，返回响应体；`None` 表示通知（不写响应体）。
     */
    public func handle(body: Array<Byte>, ctx!: JsonRpcContext): ?Array<Byte> {
        if (body.size > maxBodyBytes) {
            markStatusCode(ctx, 413)
            let data = JsonObject()
            data.add('limit', maxBodyBytes)
            return Some(
                errorBytes(None, JsonRpcProtocol.INVALID_REQUEST, 'Request body exceeds ${maxBodyBytes} bytes', data))
        }
        if (body.size == 0) {
            return Some(errorBytes(None, JsonRpcProtocol.PARSE_ERROR, 'Parse error', None))
        }
        var parsed = None<JsonValue>
        try {
            parsed = Some(JsonValue.fromBytes(body))
        } catch (_: Exception) {
            parsed = None
        }
        match (parsed) {
            case Some(value) => match (value) {
                case a: JsonArray => handleBatch(a, ctx)
                case o: JsonObject => encode(processOne(o, ctx))
                case _ => Some(
                    errorBytes(None, JsonRpcProtocol.INVALID_REQUEST, 'Invalid Request: expected an object or an array',
                        None))
            }
            case _ => Some(errorBytes(None, JsonRpcProtocol.PARSE_ERROR, 'Parse error', None))
        }
    }

    /** 本地直调，不经 HTTP。 */
    public func invoke(method: String, params!: ?JsonValue = None, ctx!: JsonRpcContext = JsonRpcContext()): JsonValue {
        match (methods_.get(method)) {
            case Some(meta) =>
                checkParams(meta, params)
                invokeHandler(meta, params, ctx.derive(ctx.id, deadlineOf(meta)))
            case _ => throw JsonRpcException(JsonRpcProtocol.METHOD_NOT_FOUND, "Method not found: '${method}'")
        }
    }

    // —— 批量 ——

    private func handleBatch(items: JsonArray, ctx: JsonRpcContext): ?Array<Byte> {
        if (items.size == 0) {
            return Some(errorBytes(None, JsonRpcProtocol.INVALID_REQUEST, 'Invalid Request: empty batch', None))
        }
        if (items.size > maxBatchSize) {
            let data = JsonObject()
            data.add('limit', maxBatchSize)
            data.add('size', items.size)
            return Some(
                errorBytes(None, JsonRpcProtocol.OVERLOADED,
                    'Batch size ${items.size} exceeds the limit ${maxBatchSize}', data))
        }
        let responses = ArrayList<JsonValue>()
        for (item in items) {
            match (item) {
                case obj: JsonObject => match (processOne(obj, ctx)) {
                    case Some(response) => responses.add(response)
                    case _ => ()
                }
                case _ => responses.add(
                    respondError(None, JsonRpcProtocol.INVALID_REQUEST, 'Invalid Request: batch item must be an object',
                        None))
            }
        }
        if (responses.isEmpty()) {
            return None
        }
        Some(JsonArray(list: responses).toString().unsafeBytes())
    }

    // —— 单条 ——

    private func processOne(obj: JsonObject, ctx: JsonRpcContext): ?JsonObject {
        let hasId = obj.get('id').isSome()
        let idValue = obj.get('id')
        if (hasId && !isValidId(idValue.getOrThrow())) {
            return notifyOrError(hasId, None, JsonRpcProtocol.INVALID_REQUEST,
                'Invalid Request: id must be a string, number or null', None)
        }
        let versionOk = match (obj.get('jsonrpc')) {
            case Some(v) => v is JsonString && v.asString().value == JsonRpcProtocol.VERSION
            case _ => false
        }
        if (!versionOk) {
            return notifyOrError(hasId, idValue, JsonRpcProtocol.INVALID_REQUEST,
                'Invalid Request: jsonrpc must be "2.0"', None)
        }
        let method = match (obj.get('method')) {
            case Some(m) =>
                if (m is JsonString) {
                    m.asString().value
                } else {
                    ''
                }
            case _ => ''
        }
        if (method.isEmpty()) {
            return notifyOrError(hasId, idValue, JsonRpcProtocol.INVALID_REQUEST,
                'Invalid Request: method must be a non-empty string', None)
        }
        var params: ?JsonValue = None
        if (let Some(p) <- obj.get('params')) {
            if (!(p is JsonObject) && !(p is JsonArray)) {
                return notifyOrError(hasId, idValue, JsonRpcProtocol.INVALID_REQUEST,
                    'Invalid Request: params must be an object or an array', None)
            }
            params = Some(p)
        }
        let (meta, failCode) = resolve(method, ctx.topic)
        match (meta) {
            case Some(m) =>
                match (checkParamsEx(m, params)) {
                    case Some(validation) => return notifyOrError(hasId, idValue, JsonRpcProtocol.INVALID_PARAMS,
                        'Invalid params', validation)
                    case _ => ()
                }
                let callCtx = ctx.derive(idValue, deadlineOf(m))
                var result = None<JsonValue>
                try {
                    result = Some(invokeHandler(m, params, callCtx))
                } catch (e: JsonRpcException) {
                    return notifyOrError(hasId, idValue, e.code, e.message, e.data)
                } catch (e: Exception) {
                    log.append(LogLevel.ERROR, "json-rpc handler '${method}' failed: ${e.message}", None<Exception>)
                    return notifyOrError(hasId, idValue, JsonRpcProtocol.INTERNAL_ERROR, 'Internal error', None)
                }
                if (!hasId) {
                    return None
                }
                return Some(respondOk(idValue.getOrThrow(), result.getOrThrow()))
            case _ =>
                if (!hasId) {
                    log.append(LogLevel.WARN, "json-rpc notification '${method}' failed with ${failCode}",
                        None<Exception>)
                    return None
                }
                return Some(respondError(idValue, failCode, JsonRpcProtocol.messageOf(failCode), None))
        }
    }

    private func resolve(method: String, topic: String): (Option<JsonRpcMethodMeta>, Int64) {
        if (topic.isEmpty()) {
            match (methods_.get(method)) {
                case Some(m) => (Some(m), 0)
                case _ => (None<JsonRpcMethodMeta>, JsonRpcProtocol.METHOD_NOT_FOUND)
            }
        } else {
            var anyInTopic = false
            for ((_, m) in methods_) {
                if (m.namespace() == topic) {
                    anyInTopic = true
                    break
                }
            }
            if (!anyInTopic) {
                (None<JsonRpcMethodMeta>, JsonRpcProtocol.UNKNOWN_TOPIC)
            } else if (!method.startsWith('${topic}.')) {
                (None<JsonRpcMethodMeta>, JsonRpcProtocol.METHOD_NOT_FOUND)
            } else {
                match (methods_.get(method)) {
                    case Some(m) => (Some(m), 0)
                    case _ => (None<JsonRpcMethodMeta>, JsonRpcProtocol.METHOD_NOT_FOUND)
                }
            }
        }
    }

    private func deadlineOf(meta: JsonRpcMethodMeta): ?MonoTime {
        match (meta.timeout) {
            case Some(t) => Some(MonoTime.now() + t)
            case _ => None<MonoTime>
        }
    }

    private func invokeHandler(meta: JsonRpcMethodMeta, params: ?JsonValue, ctx: JsonRpcContext): JsonValue {
        match (meta.timeout) {
            case Some(t) =>
                let future = spawn {
                    meta.handler(ctx, params)
                }
                try {
                    future.get(t)
                } catch (_: TimeoutException) {
                    throw JsonRpcException(JsonRpcProtocol.TIMEOUT, 'Request timed out')
                }
            case _ => meta.handler(ctx, params)
        }
    }

    private func checkParams(meta: JsonRpcMethodMeta, params: ?JsonValue): Unit {
        if (let Some(validation) <- checkParamsEx(meta, params)) {
            throw JsonRpcException(JsonRpcProtocol.INVALID_PARAMS, 'Invalid params', data: validation)
        }
    }

    private func checkParamsEx(meta: JsonRpcMethodMeta, params: ?JsonValue): ?JsonArray {
        match (meta.paramsSchema) {
            case Some(schema) =>
                let value = params ?? JsonNull.instance
                let result = JsonSchemaValidator.validate(schema, value)
                if (result.isValid) {
                    None<JsonArray>
                } else {
                    Some(result.toJson())
                }
            case _ => None<JsonArray>
        }
    }

    private func isValidId(value: JsonValue): Bool {
        (value is JsonString) || (value is JsonInt) || (value is JsonDecimal) || (value is JsonNull)
    }

    private func notifyOrError(hasId: Bool, id: ?JsonValue, code: Int64, message: String, data: ?JsonValue): ?JsonObject {
        if (hasId) {
            Some(respondError(id, code, message, data))
        } else {
            log.append(LogLevel.WARN, "json-rpc notification rejected: ${message}", None<Exception>)
            None<JsonObject>
        }
    }

    private func respondOk(id: JsonValue, result: JsonValue): JsonObject {
        let obj = JsonObject()
        obj.add('jsonrpc', JsonRpcProtocol.VERSION)
        obj.add('id', id)
        obj.add('result', result)
        obj
    }

    private func respondError(id: ?JsonValue, code: Int64, message: String, data: ?JsonValue): JsonObject {
        let obj = JsonObject()
        obj.add('jsonrpc', JsonRpcProtocol.VERSION)
        match (id) {
            case Some(x) => obj.add('id', x)
            case _ => obj.add('id', JsonNull.instance)
        }
        obj.add('error', JsonRpcError(code, message, data).toJson())
        obj
    }

    private func errorBytes(id: ?JsonValue, code: Int64, message: String, data: ?JsonValue): Array<Byte> {
        respondError(id, code, message, data).toString().unsafeBytes()
    }

    private func encode(response: ?JsonObject): ?Array<Byte> {
        match (response) {
            case Some(obj) => Some(obj.toString().unsafeBytes())
            case _ => None<Array<Byte>>
        }
    }

    private func markStatusCode(ctx: JsonRpcContext, code: UInt16): Unit {
        match (ctx.http) {
            case Some(http) => http.responseBuilder.status(code)
            case _ => ()
        }
    }
}

/** `JsonRpcServer` 的构造器。 */
public class JsonRpcServerBuilder {
    private var endpointName = JsonRpcProtocol.PATH
    private var maxBatchSize_ = JsonRpcProtocol.DEFAULT_MAX_BATCH_SIZE
    private var maxBodyBytes_ = 0
    private let initial = ArrayList<JsonRpcMethodMeta>()

    public func endpoint(name: String): JsonRpcServerBuilder {
        endpointName = name
        this
    }

    public func maxBatchSize(n: Int64): JsonRpcServerBuilder {
        if (n > 0) {
            maxBatchSize_ = n
        }
        this
    }

    public func maxBodyBytes(n: Int64): JsonRpcServerBuilder {
        if (n > 0) {
            maxBodyBytes_ = n
        }
        this
    }

    public func addMethod(meta: JsonRpcMethodMeta): JsonRpcServerBuilder {
        initial.add(meta)
        this
    }

    public func build(): JsonRpcServer {
        let limit = if (maxBodyBytes_ > 0) {
            maxBodyBytes_
        } else {
            MVCConfig.maxRequestBodySize ?? (2 * 1024 * 1024)
        }
        JsonRpcServer(endpointName, maxBatchSize_, limit, initial)
    }
}
