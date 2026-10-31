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
import std.sync.{AtomicInt64, Condition, Mutex}
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
    var detachedAtNanos: Int64 = 0
    private let queue = ArrayList<JsonObject>()
    private let mutex = Mutex()
    private let signal: Condition
    private let capacity: Int64
    private var dropped = 0

    init(id: Int64, topics: ArrayList<String>, capacity!: Int64 = 256) {
        this.id = id
        this.topics = topics
        this.capacity = capacity
        this.signal = synchronized(mutex) {
            mutex.condition()
        }
    }

    func matches(topic: String): Bool {
        topics.isEmpty() || topics.contains(topic)
    }

    /** 入队；队列满时丢最旧的一条并计数（不阻塞发布方）。 */
    func offer(notification: JsonObject): Unit {
        synchronized(mutex) {
            if (queue.size >= capacity && !queue.isEmpty()) {
                queue.remove(at: 0)
                dropped++
            }
            queue.add(notification)
            signal.notifyAll()
        }
    }

    private func drainLocked(): ArrayList<JsonObject> {
        let result = ArrayList<JsonObject>()
        for (item in queue) {
            result.add(item)
        }
        queue.clear()
        result
    }

    /** 取走全部待发送通知；没有则返回空。 */
    public func drain(): ArrayList<JsonObject> {
        synchronized(mutex) {
            drainLocked()
        }
    }

    /**
     * 带超时阻塞等待：有事件立即返回，超时返回空。
     *
     * SSE 连接用它替代 100ms 轮询——空转时 CPU 占用从「每秒 10 次」降到 0。
     */
    public func take(timeout: Duration): ArrayList<JsonObject> {
        synchronized(mutex) {
            if (queue.isEmpty()) {
                let _ = signal.wait(timeout: timeout)
            }
            drainLocked()
        }
    }

    /** 被丢弃的通知数（队列容量压力下的可观测指标）。 */
    public prop droppedCount: Int64 {
        get() {
            synchronized(mutex) {
                dropped
            }
        }
    }

    prop queued: Int64 {
        get() {
            synchronized(mutex) {
                queue.size
            }
        }
    }
}

/**
 * 进程内订阅中心。
 *
 * 三个上限都可配：订阅者总量、单订阅者队列容量、未连接时的保留时长。
 * `attach` / `detach` 支持 SSE 断线后在 grace 内用同一 id 重连。
 */
public class SubscriptionHub {
    private let subscribers = ArrayList<McpSubscriber>()
    private let mutex = Mutex()
    private let nextId = AtomicInt64(0)
    private let maxSubscribers: Int64
    private let detachedTtlNanos: Int64
    private let queueCapacity: Int64

    public init(maxSubscribers!: Int64 = 1024, detachedTtl!: Duration = Duration.second * 60,
        queueCapacity!: Int64 = 256) {
        this.maxSubscribers = maxSubscribers
        this.detachedTtlNanos = detachedTtl.toNanoseconds()
        this.queueCapacity = queueCapacity
    }

    /**
     * 创建订阅者（未 attach）。
     *
     * detached 计时从**创建时刻**开始：`subscriptions/listen` 只返回 `sseUrl`，
     * 客户端可能永远不连接；若计时从首次 detach 开始，这类订阅者既不会被回收，
     * 也无法通过 `detach` 补上时间戳，会永久占用 `maxSubscribers` 与队列内存。
     */
    public func subscribe(topics: ArrayList<String>): McpSubscriber {
        synchronized(mutex) {
            subscribeLocked(topics)
        }
    }

    /** 创建订阅者并立即绑定：`/mcp/sse` 直连（未走 `subscriptions/listen`）用。 */
    public func subscribeAttached(topics: ArrayList<String>): McpSubscriber {
        synchronized(mutex) {
            let subscriber = subscribeLocked(topics)
            subscriber.attached = true
            subscriber.detachedAtNanos = 0
            subscriber
        }
    }

    private func subscribeLocked(topics: ArrayList<String>): McpSubscriber {
        let now = nowNanos()
        pruneLocked(now)
        if (subscribers.size >= maxSubscribers) {
            throw McpException(McpProtocol.OVERLOADED,
                'too many subscribers: limit ${maxSubscribers}', data: JsonInt(maxSubscribers))
        }
        let subscriber = McpSubscriber(nextId.fetchAdd(1) + 1, topics, capacity: queueCapacity)
        subscriber.detachedAtNanos = now
        subscribers.add(subscriber)
        subscriber
    }

    public func unsubscribe(subscriber: McpSubscriber): Unit {
        synchronized(mutex) {
            subscribers.removeIf({s => s.id == subscriber.id})
        }
    }

    /**
     * 断线：保留订阅者一段时间，允许同 id 重连。
     *
     * 幂等：对已 detach 或从未 attach 的订阅者同样写入 detach 时刻，不报错也不提前返回——
     * 否则「创建后从未 attach」的订阅者永远拿不到时间戳，`prune` 也就永远回收不掉。
     */
    public func detach(subscriber: McpSubscriber): Unit {
        synchronized(mutex) {
            subscriber.attached = false
            subscriber.detachedAtNanos = nowNanos()
        }
    }

    /**
     * 把 SSE 连接绑定到 `subscriptions/listen` 创建的订阅者。
     *
     * 同一个订阅者同一时间只能绑定一次；detached 且在 TTL 内的可以重连。
     */
    public func attach(id: Int64): ?McpSubscriber {
        var found: ?McpSubscriber = None
        synchronized(mutex) {
            pruneLocked(nowNanos())
            for (subscriber in subscribers) {
                if (subscriber.id == id && !subscriber.attached) {
                    subscriber.attached = true
                    subscriber.detachedAtNanos = 0
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
        // 快照在锁内、入队在锁外：慢订阅者不能拖住发布方
        let targets = synchronized(mutex) {
            let list = ArrayList<McpSubscriber>()
            for (subscriber in subscribers) {
                if (subscriber.matches(topic)) {
                    list.add(subscriber)
                }
            }
            list
        }
        for (subscriber in targets) {
            subscriber.offer(notification)
        }
    }

    /** 清理超过 grace 的 detached 订阅者。 */
    public func prune(): Unit {
        synchronized(mutex) {
            pruneLocked(nowNanos())
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            subscribers.clear()
        }
    }

    public prop size: Int64 {
        get() {
            synchronized(mutex) {
                subscribers.size
            }
        }
    }

    private func pruneLocked(now: Int64): Unit {
        subscribers.removeIf({s => !s.attached && now - s.detachedAtNanos > detachedTtlNanos})
    }

    private static let origin = MonoTime.now()

    private static func nowNanos(): Int64 {
        (MonoTime.now() - origin).toNanoseconds()
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
    private var trustForwardedFor_ = false
    private var maxSubscribers_ = 1024
    private var subscriberQueueCapacity_ = 256
    private var subscriberDetachedTtl_ = Duration.second * 60
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

    /** 是否信任 `X-Forwarded-For`（默认关闭：伪造该头即可绕过按调用方限流）。 */
    public func trustForwardedFor(trust: Bool): McpServerBuilder {
        trustForwardedFor_ = trust
        this
    }

    /** 订阅者总量上限。 */
    public func maxSubscribers(n: Int64): McpServerBuilder {
        if (n > 0) {
            maxSubscribers_ = n
        }
        this
    }

    /** 单个订阅者的通知队列容量（满了丢最旧）。 */
    public func subscriberQueueCapacity(n: Int64): McpServerBuilder {
        if (n > 0) {
            subscriberQueueCapacity_ = n
        }
        this
    }

    /** SSE 断线后订阅者的保留时长（grace）。 */
    public func subscriberDetachedTtl(ttl: Duration): McpServerBuilder {
        if (ttl > Duration.Zero) {
            subscriberDetachedTtl_ = ttl
        }
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
        // 逐字段合并：配置先落地，Builder 只覆盖显式写过的字段
        let merged = McpConfig.rateLimit().overlay(rateLimitPolicy ?? RateLimitPolicy())
        McpServer(serverName, serverVersion ?? McpConfig.version(), merged,
            publicBaseUrl_ ?? McpConfig.publicBaseUrl(), pageSize_, resultOptions, backend,
            trustForwardedFor_ || McpConfig.trustForwardedFor(), maxSubscribers_, subscriberQueueCapacity_,
            subscriberDetachedTtl_, tools, resources, prompts)
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
    private let hub_: SubscriptionHub
    private var jsonRpc: JsonRpcServer = JsonRpcServer.builder().build()

    private let toolsByName = HashMap<String, McpTool>()
    private let toolsSorted = ArrayList<McpTool>()
    private let resourcesByUri = HashMap<String, McpResource>()
    private let resourcesSorted = ArrayList<McpResource>()
    private let promptsByName = HashMap<String, McpPrompt>()
    private let promptsSorted = ArrayList<McpPrompt>()

    private let trustForwardedFor: Bool

    init(serverName: String, serverVersion: String, policy: RateLimitPolicy, baseUrl: ?String, pageSize: Int64,
        resultOptions: ResultStoreOptions, backend: ?RateLimitBackend, trustForwardedFor: Bool,
        maxSubscribers: Int64, subscriberQueueCapacity: Int64, subscriberDetachedTtl: Duration, tools: ArrayList<McpTool>,
        resources: ArrayList<McpResource>, prompts: ArrayList<McpPrompt>) {
        this.serverName = serverName
        this.serverVersion = serverVersion
        this.policy = policy
        this.baseUrl = baseUrl
        this.pageSize = pageSize
        this.resultStore = ToolResultStore(options: resultOptions)
        this.backend = backend ?? RateLimitBackends.fromConfig()
        this.trustForwardedFor = trustForwardedFor
        this.hub_ = SubscriptionHub(maxSubscribers: maxSubscribers, detachedTtl: subscriberDetachedTtl,
            queueCapacity: subscriberQueueCapacity)
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
        hub_.close()
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
        let request = requireMeta(ctx, params)
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
        // 没有实现 resources/subscribe：能力声明必须与实现一致
        resources.add('subscribe', false)
        resources.add('listChanged', false)
        caps.add('resources', resources)
        let prompts = JsonObject()
        prompts.add('listChanged', false)
        caps.add('prompts', prompts)
        caps
    }

    private func listTools(ctx: JsonRpcContext, params: ?JsonValue): JsonValue {
        let request = requireMeta(ctx, params)
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
        let request = requireMeta(ctx, params)
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
        // 先占并发槽位：并发拒绝的请求不消耗 rpm 令牌
        let lease = acquireConcurrency(resolved, caller, tool.name)
        if (!lease.verdict.ok) {
            throw rateLimitError(ctx, lease.verdict)
        }
        let verdict = checkLimits(resolved, caller, tool.name)
        if (!verdict.ok) {
            releaseConcurrency(lease)
            throw rateLimitError(ctx, verdict)
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
            releaseConcurrency(lease)
        }
        applyLargeResult(tool, callResult)
    }

    private func listResources(ctx: JsonRpcContext, params: ?JsonValue): JsonValue {
        let request = requireMeta(ctx, params)
        let offset = cursorOf(request)
        let result = JsonObject()
        let list = JsonArray()
        var index = offset
        var emitted = 0
        while (index < resourcesSorted.size && emitted < pageSize) {
            list.add(resourceJson(resourcesSorted[index]))
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
        let request = requireMeta(ctx, params)
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
        let request = requireMeta(ctx, params)
        let offset = cursorOf(request)
        let result = JsonObject()
        let list = JsonArray()
        var index = offset
        var emitted = 0
        while (index < promptsSorted.size && emitted < pageSize) {
            list.add(promptJson(promptsSorted[index]))
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
        let request = requireMeta(ctx, params)
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
        let request = requireMeta(ctx, params)
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

    /**
     * 校验并剥离 `params._meta`。
     *
     * 校验顺序固定为「头受支持性 → 头与 body 一致性 → body 受支持性」：
     * 先判 body 会让「头与 body 不一致」在 body 非法时提前变成 `-32022`，
     * `-32602` 分支永远不可达。
     *
     * - `MCP-Protocol-Version` 头存在且不受支持 → `-32022`；
     * - 头与 body 版本不一致 → `-32602`（`data.header` / `data.body` 为原值）；
     * - body 版本不受支持 → `-32022`；
     * - 头缺失时只按 body 校验（兼容不带该头的客户端）。
     */
    private func requireMeta(ctx: JsonRpcContext, params: ?JsonValue): JsonObject {
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
        match (ctx.http) {
            case Some(http) => match (http.request.headers.getFirst('MCP-Protocol-Version')) {
                    case Some(header) =>
                        let trimmed = header.trimAscii()
                        if (!trimmed.isEmpty()) {
                            if (trimmed != McpProtocol.VERSION) {
                                throw unsupportedVersion(trimmed)
                            }
                            if (trimmed != version) {
                                let data = JsonObject()
                                data.add('header', trimmed)
                                data.add('body', version)
                                throw McpException(McpProtocol.INVALID_PARAMS,
                                    'MCP-Protocol-Version header does not match params._meta', data: data)
                            }
                        }
                    case _ => ()
                }
            case _ => ()
        }
        if (version != McpProtocol.VERSION) {
            throw unsupportedVersion(version)
        }
        obj.remove(McpProtocol.META)
        obj
    }

    private static func unsupportedVersion(requested: String): McpException {
        let data = JsonObject()
        let supported = JsonArray()
        supported.add(McpProtocol.VERSION)
        data.add('supported', supported)
        data.add('requested', requested)
        McpException(McpProtocol.UNSUPPORTED_VERSION, "unsupported MCP protocol version '${requested}'", data: data)
    }

    private func cursorOf(request: JsonObject): Int64 {
        match (request.get('cursor')) {
            case Some(value) => match (value) {
                    case text: JsonString =>
                        McpProtocol.decodeCursor(text.value) ?? throw McpException(McpProtocol.INVALID_PARAMS,
                            'invalid cursor', data: text)
                    case other => throw McpException(McpProtocol.INVALID_PARAMS, 'cursor must be a string',
                        data: other)
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

    private static func toolJson(tool: McpTool): JsonObject {
        // 首次 list 请求时缓存：条目对象序列化后不再修改，请求期只把它加进页数组
        match (tool.listJson) {
            case Some(cached) => cached
            case _ =>
                let obj = JsonObject()
                obj.add('name', tool.name)
                obj.add('description', tool.description)
                obj.add('inputSchema', tool.inputSchema)
                tool.listJson = Some(obj)
                obj
        }
    }

    private static func resourceJson(resource: McpResource): JsonObject {
        match (resource.listJson) {
            case Some(cached) => cached
            case _ =>
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
                resource.listJson = Some(obj)
                obj
        }
    }

    private static func promptJson(prompt: McpPrompt): JsonObject {
        match (prompt.listJson) {
            case Some(cached) => cached
            case _ =>
                let obj = JsonObject()
                obj.add('name', prompt.name)
                obj.add('description', prompt.description)
                let args = JsonArray()
                for (arg in prompt.arguments) {
                    args.add(arg.toJson())
                }
                obj.add('arguments', args)
                prompt.listJson = Some(obj)
                obj
        }
    }

    /**
     * 调用方标识，按优先级：
     * 1. `X-Forwarded-For` 第一段（仅当显式信任代理）；
     * 2. `Authorization` 的 SHA-256 前 16 字节（32 位十六进制）；
     * 3. `remoteAddr` 去掉端口；
     * 4. `anonymous` / 本地调用为 `local`。
     */
    private func callerId(ctx: JsonRpcContext): String {
        match (ctx.http) {
            case Some(http) =>
                if (trustForwardedFor && let Some(xff) <- http.request.headers.getFirst('X-Forwarded-For')) {
                    let first = xff.split(',')[0].trimAscii()
                    if (!first.isEmpty()) {
                        return first
                    }
                }
                if (let Some(auth) <- http.request.headers.getFirst('Authorization')) {
                    let digest = sha256Hex(auth)
                    return digest[0..32]
                }
                let addr = withoutPort(http.request.remoteAddr)
                if (!addr.isEmpty()) {
                    return addr
                }
                'anonymous'
            case _ => 'local'
        }
    }

    static func withoutPort(addr: String): String {
        let text = addr.trimAscii()
        if (text.startsWith('[')) {
            match (text.indexOf(']')) {
                case Some(index) => return text[0..index + 1]
                case _ => ()
            }
        }
        match (text.lastIndexOf(':')) {
            case Some(index) => text[0..index]
            case _ => text
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
        let toolLimit = match (tool.rateLimit) {
            case Some(limit) => limit
            case _ => ToolRateLimit()
        }
        // 全局并发只取服务级；工具并发单独一档，避免两个语义挤同一个 key
        ResolvedRateLimit(firstNotNull(toolLimit.perCallerRpm, policy.perCallerRpm),
            firstNotNull(toolLimit.perCallerToolRpm, policy.perCallerToolRpm),
            firstNotNull(toolLimit.perToolRpm, policy.perToolRpm), policy.maxConcurrency, toolLimit.maxConcurrency,
            firstNotNull(toolLimit.perCallerConcurrency, policy.perCallerConcurrency))
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

    private func acquireConcurrency(limit: ResolvedRateLimit, caller: String, tool: String): ConcurrencyLease {
        var acquiredGlobal = false
        var toolKey = ''
        var callerKey = ''
        if (let Some(max) <- limit.globalConcurrency) {
            if (!gates.tryAcquire('conc:g', max)) {
                return ConcurrencyLease(RateVerdict.reject('concurrency', max, 0), false, toolKey: '', callerKey: '')
            }
            acquiredGlobal = true
        }
        if (let Some(max) <- limit.toolConcurrency) {
            toolKey = 'conc:t:${tool}'
            if (!gates.tryAcquire(toolKey, max)) {
                releaseConcurrency(ConcurrencyLease(RateVerdict.pass(), acquiredGlobal, toolKey: '', callerKey: ''))
                return ConcurrencyLease(RateVerdict.reject('concurrency_tool', max, 0), false, toolKey: '', callerKey: '')
            }
        }
        if (let Some(max) <- limit.perCallerConcurrency) {
            callerKey = 'conc:ct:${caller}\u{0}${tool}'
            if (!gates.tryAcquire(callerKey, max)) {
                releaseConcurrency(ConcurrencyLease(RateVerdict.pass(), acquiredGlobal, toolKey: toolKey, callerKey: ''))
                return ConcurrencyLease(RateVerdict.reject('concurrency_caller', max, 0), false, toolKey: '', callerKey: '')
            }
        }
        ConcurrencyLease(RateVerdict.pass(), acquiredGlobal, toolKey: toolKey, callerKey: callerKey)
    }

    private func releaseConcurrency(lease: ConcurrencyLease): Unit {
        if (!lease.callerKey.isEmpty()) {
            gates.release(lease.callerKey)
        }
        if (!lease.toolKey.isEmpty()) {
            gates.release(lease.toolKey)
        }
        if (lease.global) {
            gates.release('conc:g')
        }
    }

    private func rateLimitError(ctx: JsonRpcContext, verdict: RateVerdict): McpException {
        let data = JsonObject()
        data.add('scope', verdict.scope)
        data.add('limit', verdict.limit)
        data.add('retryAfterMs', verdict.retryAfterMs)
        match (ctx.http) {
            case Some(http) =>
                http.responseBuilder.status(429)
                let seconds = if (verdict.retryAfterMs <= 0) {
                    1
                } else {
                    (verdict.retryAfterMs + 999) / 1000
                }
                http.responseBuilder.header('Retry-After', '${seconds}')
            case _ => ()
        }
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
