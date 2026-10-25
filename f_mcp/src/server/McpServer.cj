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
package fountain::f_mcp.server

import std.collection.{ArrayList, HashMap}
import std.sync.{AtomicInt64, Mutex}
import stdx.crypto.digest.SHA256
import stdx.log.LogLevel
import fountain::f_data.*
import fountain::f_jsonrpc.base.*
import fountain::f_jsonrpc.server.*
import fountain::f_log.impl.*
import fountain::f_mcp.base.*

/** 订阅者：一条 SSE 连接一个队列。 */
public class McpSubscriber {
    let id: Int64
    let topics: ArrayList<String>
    var attached = false
    let queue = ArrayList<JsonObject>()
    let mutex = Mutex()

    init(id: Int64, topics: ArrayList<String>) {
        this.id = id
        this.topics = topics
    }

    func matches(topic: String): Bool {
        topics.isEmpty() || topics.contains(topic)
    }

    func offer(notification: JsonObject): Unit {
        synchronized(mutex) {
            queue.add(notification)
        }
    }

    /** 取走全部待发送通知；没有则返回空。 */
    public func drain(): ArrayList<JsonObject> {
        let result = ArrayList<JsonObject>()
        synchronized(mutex) {
            for (item in queue) {
                result.add(item)
            }
            queue.clear()
        }
        result
    }
}

/** 进程内订阅中心。SSE 端点从订阅者队列取通知。 */
public class SubscriptionHub {
    private let subscribers = ArrayList<McpSubscriber>()
    private let mutex = Mutex()
    private let nextId = AtomicInt64(0)

    public func subscribe(topics: ArrayList<String>): McpSubscriber {
        let subscriber = McpSubscriber(nextId.fetchAdd(1) + 1, topics)
        synchronized(mutex) {
            subscribers.add(subscriber)
        }
        subscriber
    }

    public func unsubscribe(subscriber: McpSubscriber): Unit {
        synchronized(mutex) {
            subscribers.removeIf({s => s.id == subscriber.id})
        }
    }

    /**
     * 把 SSE 连接绑定到 `subscriptions/listen` 创建的订阅者。
     *
     * 同一个订阅者只能绑定一次；绑定成功后 SSE 流直接消费它的队列。
     */
    public func attach(id: Int64): ?McpSubscriber {
        var found: ?McpSubscriber = None
        synchronized(mutex) {
            for (subscriber in subscribers) {
                if (subscriber.id == id && !subscriber.attached) {
                    subscriber.attached = true
                    found = Some(subscriber)
                    break
                }
            }
        }
        found
    }

    public func publish(topic: String, params: JsonValue): Unit {
        let notification = JsonObject()
        notification.add('jsonrpc', '2.0')
        notification.add('method', 'notifications/${topic}')
        notification.add('params', params)
        synchronized(mutex) {
            for (subscriber in subscribers) {
                if (subscriber.matches(topic)) {
                    subscriber.offer(notification)
                }
            }
        }
    }
}

public class McpServerBuilder {
    private var serverName = 'fountain-mcp'
    private var serverVersion: ?String = None
    private var rateLimitPolicy: ?RateLimitPolicy = None
    private var publicBaseUrl_: ?String = None
    private var pageSize_ = 100
    private var resultOptions = ResultStoreOptions()
    private var backend: ?RateLimitBackend = None
    private let tools = ArrayList<McpTool>()
    private let resources = ArrayList<McpResource>()
    private let prompts = ArrayList<McpPrompt>()

    /** 设置 `serverInfo`；`version` 为空时取 `mcp_version`（默认 `1.0.0`）。 */
    public func serverInfo(name: String, version: String): McpServerBuilder {
        serverName = name
        serverVersion = if (version.trimAscii().isEmpty()) {
            None<String>
        } else {
            Some(version)
        }
        this
    }

    public func rateLimit(policy: RateLimitPolicy): McpServerBuilder {
        rateLimitPolicy = Some(policy)
        this
    }

    public func publicBaseUrl(url: String): McpServerBuilder {
        var normalized = url.trimAscii()
        while (normalized.endsWith('/') && !normalized.isEmpty()) {
            normalized = normalized[0..normalized.size - 1]
        }
        publicBaseUrl_ = if (normalized.isEmpty()) {
            None<String>
        } else {
            Some(normalized)
        }
        this
    }

    public func pageSize(size: Int64): McpServerBuilder {
        if (size > 0) {
            pageSize_ = size
        }
        this
    }

    public func resultStore(options: ResultStoreOptions): McpServerBuilder {
        resultOptions = options
        this
    }

    public func rateLimitBackend(backend: RateLimitBackend): McpServerBuilder {
        this.backend = Some(backend)
        this
    }

    public func tool(tool: McpTool): McpServerBuilder {
        tools.add(tool)
        this
    }

    public func resource(resource: McpResource): McpServerBuilder {
        resources.add(resource)
        this
    }

    public func prompt(prompt: McpPrompt): McpServerBuilder {
        prompts.add(prompt)
        this
    }

    public func build(): McpServer {
        McpServer(serverName, serverVersion ?? McpConfig.version(), rateLimitPolicy ?? McpConfig.rateLimit(),
            publicBaseUrl_ ?? McpConfig.publicBaseUrl(), pageSize_, resultOptions, backend, tools, resources, prompts)
    }
}

/** MCP 服务端。内部持有一个 JSON-RPC server，方法表固定。 */
public class McpServer {
    static let log = LoggerFactory.getLogger<McpServer>()

    private let serverName: String
    private let serverVersion: String
    private let policy: RateLimitPolicy
    private let baseUrl: ?String
    private let pageSize: Int64
    private let resultStore: ToolResultStore
    private let backend: RateLimitBackend
    private let gates = ConcurrencyGate()
    private let hub_ = SubscriptionHub()
    private var jsonRpc: JsonRpcServer = JsonRpcServer.builder().build()

    private let toolsByName = HashMap<String, McpTool>()
    private let toolsSorted = ArrayList<McpTool>()
    private let resourcesByUri = HashMap<String, McpResource>()
    private let resourcesSorted = ArrayList<McpResource>()
    private let promptsByName = HashMap<String, McpPrompt>()
    private let promptsSorted = ArrayList<McpPrompt>()

    init(serverName: String, serverVersion: String, policy: RateLimitPolicy, baseUrl: ?String, pageSize: Int64,
        resultOptions: ResultStoreOptions, backend: ?RateLimitBackend, tools: ArrayList<McpTool>,
        resources: ArrayList<McpResource>, prompts: ArrayList<McpPrompt>) {
        this.serverName = serverName
        this.serverVersion = serverVersion
        this.policy = policy
        this.baseUrl = baseUrl
        this.pageSize = pageSize
        this.resultStore = ToolResultStore(options: resultOptions)
        this.backend = backend ?? RateLimitBackends.fromConfig()
        registerTools(tools)
        registerResources(resources)
        registerPrompts(prompts)
        this.jsonRpc = buildJsonRpc()
    }

    public static func builder(): McpServerBuilder {
        McpServerBuilder()
    }

    public func jsonRpcServer(): JsonRpcServer {
        jsonRpc
    }

    public func resultStoreRef(): ToolResultStore {
        resultStore
    }

    public func hub(): SubscriptionHub {
        hub_
    }

    public func close(): Unit {
        resultStore.close()
        gates.close()
        backend.close()
    }

    // —— 注册与校验 ——

    private func registerTools(tools: ArrayList<McpTool>): Unit {
        for (tool in tools) {
            if (toolsByName.contains(tool.name)) {
                throw McpException(McpProtocol.INTERNAL_ERROR, "duplicate tool '${tool.name}'")
            }
            toolsByName.add(tool.name, tool)
            toolsSorted.add(tool)
        }
        sortTools()
    }

    private func registerResources(resources: ArrayList<McpResource>): Unit {
        for (resource in resources) {
            let resolved = resource.resolved(baseUrl)
            if (resourcesByUri.contains(resolved.uri)) {
                throw McpException(McpProtocol.INTERNAL_ERROR, "duplicate resource '${resolved.uri}'")
            }
            resourcesByUri.add(resolved.uri, resolved)
            resourcesSorted.add(resolved)
        }
        sortResources()
    }

    private func registerPrompts(prompts: ArrayList<McpPrompt>): Unit {
        for (prompt in prompts) {
            if (promptsByName.contains(prompt.name)) {
                throw McpException(McpProtocol.INTERNAL_ERROR, "duplicate prompt '${prompt.name}'")
            }
            promptsByName.add(prompt.name, prompt)
            promptsSorted.add(prompt)
        }
        sortPrompts()
    }

    private func sortTools(): Unit {
        for (i in 1..toolsSorted.size) {
            var j = i
            while (j > 0 && toolsSorted[j].name < toolsSorted[j - 1].name) {
                let tmp = toolsSorted[j]
                toolsSorted[j] = toolsSorted[j - 1]
                toolsSorted[j - 1] = tmp
                j--
            }
        }
    }

    private func sortResources(): Unit {
        for (i in 1..resourcesSorted.size) {
            var j = i
            while (j > 0 && resourcesSorted[j].uri < resourcesSorted[j - 1].uri) {
                let tmp = resourcesSorted[j]
                resourcesSorted[j] = resourcesSorted[j - 1]
                resourcesSorted[j - 1] = tmp
                j--
            }
        }
    }

    private func sortPrompts(): Unit {
        for (i in 1..promptsSorted.size) {
            var j = i
            while (j > 0 && promptsSorted[j].name < promptsSorted[j - 1].name) {
                let tmp = promptsSorted[j]
                promptsSorted[j] = promptsSorted[j - 1]
                promptsSorted[j - 1] = tmp
                j--
            }
        }
    }

    // —— JSON-RPC 方法表 ——

    private func buildJsonRpc(): JsonRpcServer {
        let builder = JsonRpcServer.builder().endpoint(McpProtocol.PATH)
        builder.addMethod(JsonRpcMethodMeta(name: 'server/discover', handler: {ctx, params => discover(ctx, params)}))
        builder.addMethod(JsonRpcMethodMeta(name: 'tools/list', handler: {ctx, params => listTools(ctx, params)}))
        builder.addMethod(JsonRpcMethodMeta(name: 'tools/call', handler: {ctx, params => callTool(ctx, params)}))
        builder.addMethod(JsonRpcMethodMeta(name: 'resources/list', handler: {ctx, params => listResources(ctx, params)}))
        builder.addMethod(JsonRpcMethodMeta(name: 'resources/read', handler: {ctx, params => readResource(ctx, params)}))
        builder.addMethod(JsonRpcMethodMeta(name: 'prompts/list', handler: {ctx, params => listPrompts(ctx, params)}))
        builder.addMethod(JsonRpcMethodMeta(name: 'prompts/get', handler: {ctx, params => getPrompt(ctx, params)}))
        builder.addMethod(JsonRpcMethodMeta(name: 'subscriptions/listen', handler: {ctx, params => listen(ctx, params)}))
        // legacy 握手：明确拒绝并提示升级
        let legacy = {
            ctx: JsonRpcContext, params: ?JsonValue => throw McpException(JsonRpcProtocol.METHOD_NOT_FOUND,
                'MCP 2026-07-28 has no handshake; upgrade the client', data: legacyData())
        }
        builder.addMethod(JsonRpcMethodMeta(name: 'initialize', handler: legacy))
        builder.addMethod(JsonRpcMethodMeta(name: 'notifications/initialized', handler: legacy))
        builder.build()
    }

    private static func legacyData(): JsonObject {
        let data = JsonObject()
        data.add('legacyMethod', 'initialize')
        data.add('supportedVersion', McpProtocol.VERSION)
        data
    }

    // —— 方法实现 ——

    private func discover(ctx: JsonRpcContext, params: ?JsonValue): JsonValue {
        let request = requireMeta(params)
        let root = JsonObject()
        root.add('resultType', 'complete')
        let versions = JsonArray()
        versions.add(McpProtocol.VERSION)
        root.add('supportedVersions', versions)
        root.add('capabilities', capabilities())
        let meta = JsonObject()
        let info = JsonObject()
        info.add('name', serverName)
        info.add('version', serverVersion)
        meta.add(McpProtocol.KEY_SERVER_INFO, info)
        root.add(McpProtocol.META, meta)
        root
    }

    private func capabilities(): JsonObject {
        let caps = JsonObject()
        let tools = JsonObject()
        tools.add('listChanged', false)
        caps.add('tools', tools)
        let resources = JsonObject()
        resources.add('subscribe', true)
        resources.add('listChanged', false)
        caps.add('resources', resources)
        let prompts = JsonObject()
        prompts.add('listChanged', false)
        caps.add('prompts', prompts)
        caps
    }

    private func listTools(ctx: JsonRpcContext, params: ?JsonValue): JsonValue {
        let request = requireMeta(params)
        let offset = cursorOf(request)
        let result = JsonObject()
        let list = JsonArray()
        var index = offset
        var emitted = 0
        while (index < toolsSorted.size && emitted < pageSize) {
            list.add(toolJson(toolsSorted[index]))
            index++
            emitted++
        }
        result.add('tools', list)
        if (index < toolsSorted.size) {
            result.add('nextCursor', McpProtocol.encodeCursor(index))
        }
        result.add('resultType', 'complete')
        result
    }

    private func callTool(ctx: JsonRpcContext, params: ?JsonValue): JsonValue {
        let request = requireMeta(params)
        let name = stringField(request, 'name')
        let arguments = match (request.get('arguments')) {
            case Some(obj: JsonObject) => obj
            case Some(other) => throw McpException(McpProtocol.INVALID_PARAMS, 'arguments must be an object',
                data: other)
            case _ => JsonObject()
        }
        let tool = toolsByName.get(name) ?? throw McpException(McpProtocol.INVALID_PARAMS, "unknown tool '${name}'",
            data: JsonString(name))

        let resolved = resolveLimit(tool)
        let caller = callerId(ctx)
        let verdict = checkLimits(resolved, caller, tool.name)
        if (!verdict.ok) {
            throw rateLimitError(verdict)
        }
        let acquire = acquireConcurrency(resolved, caller, tool.name)
        if (!acquire.ok) {
            throw rateLimitError(acquire)
        }
        let toolCtx = McpToolContext(caller, requestId: ctx.id, inputResponses: request.get('inputResponses'),
            requestState: request.get('requestState'))
        var callResult = CallToolResult.text('')
        try {
            let validation = JsonSchemaValidator.validate(tool.inputSchema, arguments)
            if (!validation.isValid) {
                throw McpException(McpProtocol.INVALID_PARAMS, 'Invalid params', data: validation.toJson())
            }
            callResult = tool.handler(toolCtx, arguments)
        } finally {
            releaseConcurrency(resolved, caller, tool.name)
        }
        applyLargeResult(tool, callResult)
    }

    private func listResources(ctx: JsonRpcContext, params: ?JsonValue): JsonValue {
        let request = requireMeta(params)
        let offset = cursorOf(request)
        let result = JsonObject()
        let list = JsonArray()
        var index = offset
        var emitted = 0
        while (index < resourcesSorted.size && emitted < pageSize) {
            let resource = resourcesSorted[index]
            let obj = JsonObject()
            obj.add('uri', resource.uri)
            obj.add('name', resource.name)
            if (!resource.description.isEmpty()) {
                obj.add('description', resource.description)
            }
            match (resource.mimeType) {
                case Some(m) => obj.add('mimeType', m)
                case _ => ()
            }
            list.add(obj)
            index++
            emitted++
        }
        result.add('resources', list)
        if (index < resourcesSorted.size) {
            result.add('nextCursor', McpProtocol.encodeCursor(index))
        }
        result.add('resultType', 'complete')
        result
    }

    private func readResource(ctx: JsonRpcContext, params: ?JsonValue): JsonValue {
        let request = requireMeta(params)
        let uri = stringField(request, 'uri')
        let contents = ArrayList<ResourceContent>()
        if (isResultLink(uri)) {
            let token = tokenOf(uri)
            match (resultStore.get(token)) {
                case Some(content) => contents.add(content)
                case _ => throw resourceMissing(uri, 'expired')
            }
        } else {
            let resource = resourcesByUri.get(uri) ?? throw resourceMissing(uri, 'unknown')
            let read = resource.handler(McpResourceContext(uri, callerId(ctx)))
            contents.add(all: read)
        }
        let result = JsonObject()
        let array = JsonArray()
        for (content in contents) {
            array.add(content.toJson())
        }
        result.add('contents', array)
        result.add('resultType', 'complete')
        result
    }

    private func listPrompts(ctx: JsonRpcContext, params: ?JsonValue): JsonValue {
        let request = requireMeta(params)
        let offset = cursorOf(request)
        let result = JsonObject()
        let list = JsonArray()
        var index = offset
        var emitted = 0
        while (index < promptsSorted.size && emitted < pageSize) {
            let prompt = promptsSorted[index]
            let obj = JsonObject()
            obj.add('name', prompt.name)
            if (!prompt.description.isEmpty()) {
                obj.add('description', prompt.description)
            }
            let args = JsonArray()
            for (arg in prompt.arguments) {
                args.add(arg.toJson())
            }
            obj.add('arguments', args)
            list.add(obj)
            index++
            emitted++
        }
        result.add('prompts', list)
        if (index < promptsSorted.size) {
            result.add('nextCursor', McpProtocol.encodeCursor(index))
        }
        result.add('resultType', 'complete')
        result
    }

    private func getPrompt(ctx: JsonRpcContext, params: ?JsonValue): JsonValue {
        let request = requireMeta(params)
        let name = stringField(request, 'name')
        let prompt = promptsByName.get(name) ?? throw McpException(McpProtocol.INVALID_PARAMS,
            "unknown prompt '${name}'", data: JsonString(name))
        let args = match (request.get('arguments')) {
            case Some(obj: JsonObject) => obj
            case _ => JsonObject()
        }
        for (arg in prompt.arguments) {
            if (arg.required && !args.contains(arg.name)) {
                throw McpException(McpProtocol.INVALID_PARAMS, "missing prompt argument '${arg.name}'",
                    data: JsonString(arg.name))
            }
        }
        let messages = prompt.handler(args)
        let result = JsonObject()
        let array = JsonArray()
        for (message in messages) {
            array.add(message.toJson())
        }
        result.add('description', prompt.description)
        result.add('messages', array)
        result.add('resultType', 'complete')
        result
    }

    private func listen(ctx: JsonRpcContext, params: ?JsonValue): JsonValue {
        let request = requireMeta(params)
        let topics = ArrayList<String>()
        if (let Some(array) <- request.get('topics')) {
            if (let a: JsonArray <- array) {
                for (item in a) {
                    if (item is JsonString) {
                        topics.add(item.asString().value)
                    }
                }
            }
        }
        let subscriber = hub_.subscribe(topics)
        let path = '${McpProtocol.SSE_PATH}?subscriptionId=${subscriber.id}'
        let sseUrl = match (baseUrl) {
            case Some(base) => '${base}${path}'
            case _ => path
        }
        let result = JsonObject()
        result.add('resultType', 'complete')
        result.add('subscriptionId', subscriber.id)
        result.add('subscribedTopics', JsonArray(list: topicsToJson(topics)))
        result.add('sseUrl', sseUrl)
        result
    }

    private func topicsToJson(topics: ArrayList<String>): ArrayList<JsonValue> {
        let list = ArrayList<JsonValue>()
        for (topic in topics) {
            list.add(JsonString(topic))
        }
        list
    }

    // —— 辅助 ——

    private func requireMeta(params: ?JsonValue): JsonObject {
        let obj = match (params) {
            case Some(o: JsonObject) => o
            case _ => throw McpException(McpProtocol.INVALID_PARAMS, 'params must be an object')
        }
        let metaValue = obj.get(McpProtocol.META) ?? throw McpException(McpProtocol.INVALID_PARAMS,
            "missing params._meta")
        let meta = match (metaValue) {
            case m: JsonObject => m
            case _ => throw McpException(McpProtocol.INVALID_PARAMS, 'params._meta must be an object')
        }
        let version = match (meta.get(McpProtocol.KEY_PROTOCOL_VERSION)) {
            case Some(v) =>
                if (v is JsonString) {
                    v.asString().value
                } else {
                    ''
                }
            case _ => ''
        }
        if (version.isEmpty()) {
            throw McpException(McpProtocol.INVALID_PARAMS, 'missing params._meta protocolVersion')
        }
        if (version != McpProtocol.VERSION) {
            let data = JsonObject()
            let supported = JsonArray()
            supported.add(McpProtocol.VERSION)
            data.add('supported', supported)
            data.add('requested', version)
            throw McpException(McpProtocol.UNSUPPORTED_VERSION, "unsupported MCP protocol version '${version}'",
                data: data)
        }
        obj.remove(McpProtocol.META)
        obj
    }

    private func cursorOf(request: JsonObject): Int64 {
        match (request.get('cursor')) {
            case Some(value) =>
                if (value is JsonString) {
                    McpProtocol.decodeCursor(value.asString().value)
                } else {
                    0
                }
            case _ => 0
        }
    }

    private func stringField(obj: JsonObject, name: String): String {
        match (obj.get(name)) {
            case Some(value) =>
                if (value is JsonString) {
                    value.asString().value
                } else {
                    throw McpException(McpProtocol.INVALID_PARAMS, "'${name}' must be a string")
                }
            case _ => throw McpException(McpProtocol.INVALID_PARAMS, "missing '${name}'")
        }
    }

    private func toolJson(tool: McpTool): JsonObject {
        let obj = JsonObject()
        obj.add('name', tool.name)
        obj.add('description', tool.description)
        obj.add('inputSchema', tool.inputSchema)
        obj
    }

    private func callerId(ctx: JsonRpcContext): String {
        match (ctx.http) {
            case Some(http) =>
                if (let Some(auth) <- http.request.headers.getFirst('Authorization')) {
                    return sha256Hex(auth)
                }
                let addr = http.request.remoteAddr
                if (!addr.isEmpty()) {
                    return addr
                }
                'anonymous'
            case _ => 'local'
        }
    }

    private static func sha256Hex(text: String): String {
        let hasher = SHA256()
        hasher.write(text.toArray())
        let digest = hasher.finish()
        var hex = ''
        for (byte in digest) {
            hex += hexDigit(byte / 16)
            hex += hexDigit(byte % 16)
        }
        hex
    }

    private static func hexDigit(value: UInt8): String {
        match (value) {
            case 0 => '0'
            case 1 => '1'
            case 2 => '2'
            case 3 => '3'
            case 4 => '4'
            case 5 => '5'
            case 6 => '6'
            case 7 => '7'
            case 8 => '8'
            case 9 => '9'
            case 10 => 'a'
            case 11 => 'b'
            case 12 => 'c'
            case 13 => 'd'
            case 14 => 'e'
            case _ => 'f'
        }
    }

    private func resolveLimit(tool: McpTool): ResolvedRateLimit {
        match (tool.rateLimit) {
            case Some(t) => ResolvedRateLimit(firstNotNull(t.perCallerRpm, policy.perCallerRpm),
                firstNotNull(t.perCallerToolRpm, policy.perCallerToolRpm), firstNotNull(t.perToolRpm, policy.perToolRpm),
                firstNotNull(t.maxConcurrency, policy.maxConcurrency),
                firstNotNull(t.perCallerConcurrency, policy.perCallerConcurrency))
            case _ => ResolvedRateLimit(policy.perCallerRpm, policy.perCallerToolRpm, policy.perToolRpm,
                policy.maxConcurrency, policy.perCallerConcurrency)
        }
    }

    private static func firstNotNull(a: ?Int64, b: ?Int64): ?Int64 {
        match (a) {
            case Some(v) => Some(v)
            case _ => b
        }
    }

    private func checkLimits(limit: ResolvedRateLimit, caller: String, tool: String): RateVerdict {
        let now = DateTime.now().toUnixTimeStamp().toNanoseconds()
        if (let Some(rpm) <- limit.perCallerRpm) {
            if (!backend.tryAcquire('c:${caller}', rpm, now)) {
                return RateVerdict.reject('caller', rpm, retryAfterMs(rpm))
            }
        }
        if (let Some(rpm) <- limit.perCallerToolRpm) {
            if (!backend.tryAcquire('ct:${caller}\u{0}${tool}', rpm, now)) {
                return RateVerdict.reject('caller_tool', rpm, retryAfterMs(rpm))
            }
        }
        if (let Some(rpm) <- limit.perToolRpm) {
            if (!backend.tryAcquire('t:${tool}', rpm, now)) {
                return RateVerdict.reject('tool', rpm, retryAfterMs(rpm))
            }
        }
        RateVerdict.pass()
    }

    private static func retryAfterMs(rpm: Int64): Int64 {
        if (rpm <= 0) {
            return 0
        }
        60_000 / rpm
    }

    private func acquireConcurrency(limit: ResolvedRateLimit, caller: String, tool: String): RateVerdict {
        if (let Some(max) <- limit.maxConcurrency) {
            if (!gates.tryAcquire('g', max)) {
                return RateVerdict.reject('concurrency', max, 0)
            }
        }
        if (let Some(max) <- limit.perCallerConcurrency) {
            if (!gates.tryAcquire('ct:${caller}\u{0}${tool}', max)) {
                if (limit.maxConcurrency.isSome()) {
                    gates.release('g')
                }
                return RateVerdict.reject('concurrency_tool', max, 0)
            }
        }
        RateVerdict.pass()
    }

    private func releaseConcurrency(limit: ResolvedRateLimit, caller: String, tool: String): Unit {
        if (limit.perCallerConcurrency.isSome()) {
            gates.release('ct:${caller}\u{0}${tool}')
        }
        if (limit.maxConcurrency.isSome()) {
            gates.release('g')
        }
    }

    private static func rateLimitError(verdict: RateVerdict): McpException {
        let data = JsonObject()
        data.add('scope', verdict.scope)
        data.add('limit', verdict.limit)
        data.add('retryAfterMs', verdict.retryAfterMs)
        McpException(McpProtocol.RATE_LIMITED, "Rate limit exceeded: ${verdict.scope} (${verdict.limit})", data: data)
    }

    private func applyLargeResult(tool: McpTool, result: CallToolResult): JsonValue {
        let limit = tool.maxResultBytes ?? (1024 * 1024)
        let encoded = result.toJson()
        // 唯一一次完整序列化：量字节 / 入库 / 截断共用同一份字符串
        let json = encoded.toString()
        if (json.size <= limit) {
            return encoded
        }
        match (baseUrl) {
            case Some(base) =>
                let token = resultStore.newToken()
                let link = '${base}${McpProtocol.TOOL_RESULT_PREFIX}${token}'
                let content = ResourceContent(link, Some('application/json'), Some(json), None)
                if (resultStore.put(token, content)) {
                    let blocks = ArrayList<ContentBlock>()
                    blocks.add(
                        ContentBlock.resourceLink(link, tool.name, description: 'tool result exceeds ${limit} bytes',
                            mimeType: 'application/json'))
                    let replaced = CallToolResult(content: blocks, isError: result.isError,
                        resultType: result.resultType, inputRequired: result.inputRequired,
                        requestState: result.requestState)
                    return replaced.toJson()
                }
                truncated(tool, result, json, limit)
            case _ => truncated(tool, result, json, limit)
        }
    }

    private func truncated(tool: McpTool, result: CallToolResult, json: String, limit: Int64): JsonValue {
        log.append(LogLevel.WARN,
            "mcp tool '${tool.name}' result exceeds ${limit} bytes without publicBaseUrl; truncated", None<Exception>)
        let cut = truncateUtf8(json, limit)
        let blocks = ArrayList<ContentBlock>()
        blocks.add(ContentBlock.text(cut))
        let extra = JsonObject()
        extra.add('truncated', true)
        extra.add('limit', limit)
        CallToolResult(content: blocks, isError: result.isError, resultType: result.resultType,
            inputRequired: result.inputRequired, requestState: result.requestState, extra: extra).toJson()
    }

    /**
     * 按 UTF-8 rune 边界截断：结果长度不超过 `limit` 字节，且一定是合法字符串。
     * （按字节切片会把中文 / emoji 切成半个码点，序列化时直接抛异常。）
     */
    static func truncateUtf8(text: String, limit: Int64): String {
        if (limit <= 0) {
            return ''
        }
        let builder = StringBuilder()
        var used: Int64 = 0
        for (r in text.toRuneArray()) {
            let code = UInt32(r)
            let size: Int64 = if (code < 0x80) {
                1
            } else if (code < 0x800) {
                2
            } else if (code < 0x10000) {
                3
            } else {
                4
            }
            if (used + size > limit) {
                break
            }
            builder.append(r)
            used += size
        }
        builder.toString()
    }

    private func isResultLink(uri: String): Bool {
        match (baseUrl) {
            case Some(base) => uri.startsWith('${base}${McpProtocol.TOOL_RESULT_PREFIX}')
            case _ => false
        }
    }

    private func tokenOf(uri: String): String {
        match (baseUrl) {
            case Some(base) =>
                let prefix = '${base}${McpProtocol.TOOL_RESULT_PREFIX}'
                if (uri.startsWith(prefix)) {
                    return uri[prefix.size..]
                }
                ''
            case _ => ''
        }
    }

    private static func resourceMissing(uri: String, reason: String): McpException {
        let data = JsonObject()
        data.add('uri', uri)
        data.add('reason', reason)
        McpException(McpProtocol.RESOURCE_NOT_FOUND, "Resource not found: ${uri} (${reason})", data: data)
    }
}
