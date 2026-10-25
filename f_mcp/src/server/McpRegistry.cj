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

import std.collection.ArrayList
import std.reflect.{InfoNotFoundException, TypeInfo}
import std.sync.Mutex
import fountain::f_data.*
import fountain::f_mcp.base.*

/** 进程内默认 MCP server。应用在 static init 阶段用 `configure` 注册工具 / 资源。 */
public class McpRegistry {
    private static let mutex = Mutex()
    private static let builder = McpServer.builder()
    private static var built: ?McpServer = None

    /**
     * 追加注册项。已经 `build()` 过时立即重建，新注册的 tool / resource / prompt 马上生效。
     *
     * 仅用于启动阶段（`fboot` 串行加载 dylib），不要在请求处理中调用。
     */
    public static func configure(configure: (McpServerBuilder) -> Unit): Unit {
        synchronized(mutex) {
            configure(builder)
            if (built.isSome()) {
                built = Some(builder.build())
            }
        }
    }

    /**
     * 读取 `T.name` 上的 `@McpToolMeta`；函数不存在或没有注解时返回 `None`。
     */
    public static func getToolMeta<T>(name: String, args: Array<TypeInfo>): ?McpToolMeta where T <: Object {
        let function = try {
            TypeInfo.of<T>().getInstanceFunction(name, args)
        } catch (_: InfoNotFoundException) {
            return None<McpToolMeta>
        }
        function.findAnnotation<McpToolMeta>()
    }

    /** 读取 `T.name` 上的 `@McpResourceMeta`；函数不存在或没有注解时返回 `None`。 */
    public static func getResourceMeta<T>(name: String, args: Array<TypeInfo>): ?McpResourceMeta where T <: Object {
        let function = try {
            TypeInfo.of<T>().getInstanceFunction(name, args)
        } catch (_: InfoNotFoundException) {
            return None<McpResourceMeta>
        }
        function.findAnnotation<McpResourceMeta>()
    }

    /** 读取 `T.name` 上的 `@McpPromptMeta`；函数不存在或没有注解时返回 `None`。 */
    public static func getPromptMeta<T>(name: String, args: Array<TypeInfo>): ?McpPromptMeta where T <: Object {
        let function = try {
            TypeInfo.of<T>().getInstanceFunction(name, args)
        } catch (_: InfoNotFoundException) {
            return None<McpPromptMeta>
        }
        function.findAnnotation<McpPromptMeta>()
    }

    /**
     * 注册 tool。函数必须恰好一个参数，参数类型用于生成 `inputSchema`。
     */
    public static func registerToolMeta<T>(name: String, meta: McpToolMeta, args: Array<TypeInfo>,
        fn: (JsonValue) -> CallToolResult): Unit where T <: Object {
        if (args.size != 1) {
            throw McpException(McpProtocol.INTERNAL_ERROR,
                "tool '${name}' must have exactly one parameter, got ${args.size}")
        }
        try {
            args[0].getStaticFunction('dataFields')
        } catch (_: InfoNotFoundException) {
            throw McpException(McpProtocol.INTERNAL_ERROR,
                "tool '${name}' parameter must be an @DataAssist[props fields] class")
        }
        let schema = JsonObject.toJsonSchema(args[0])
        let toolName = if (meta.name.isEmpty()) {
            name
        } else {
            meta.name
        }
        let toolBuilder = McpTool.builder(toolName).description(meta.description).inputSchema(schema)
        match (toolRateLimitOf(meta)) {
            case Some(limit) =>
                toolBuilder.rateLimit(limit)
                ()
            case _ => ()
        }
        let tool = toolBuilder.handler(
            {
                _, jsonArgs =>
                    let payload = match (jsonArgs) {
                        case obj: JsonObject => obj
                        case _ => JsonObject()
                    }
                    fn(payload)
            }
        ).build()
        configure({b => b.tool(tool)})
    }

    /**
     * 注册 resource。函数必须没有参数；`uri` 不能为空。
     *
     * 处理器返回 `ArrayList<ResourceContent>`；内容的 `uri` 为空时用实际请求的 `ctx.uri` 补全，
     * `meta.mediaType` 非空时覆盖内容里的 `mimeType`。
     */
    public static func registerResourceMeta<T>(name: String, meta: McpResourceMeta, args: Array<TypeInfo>,
        fn: () -> ArrayList<ResourceContent>): Unit where T <: Object {
        if (args.size != 0) {
            throw McpException(McpProtocol.INTERNAL_ERROR,
                "resource '${name}' must have no parameters, got ${args.size}")
        }
        if (meta.uri.isEmpty()) {
            throw McpException(McpProtocol.INTERNAL_ERROR,
                "resource '${name}' has no uri; set @McpResourceMeta[uri: ...]")
        }
        let resourceName = if (meta.name.isEmpty()) {
            name
        } else {
            meta.name
        }
        let builder = McpResource.builder(meta.uri, resourceName).description(meta.description)
        if (!meta.mediaType.isEmpty()) {
            builder.mimeType(meta.mediaType)
        }
        let resource = builder.handler({ctx => withContext(fn(), ctx.uri, meta.mediaType)}).build()
        configure({b => b.resource(resource)})
    }

    /**
     * 注册 prompt。函数参数即 prompt 参数，`@McpPromptArg` 提供描述与是否必填。
     */
    public static func registerPromptMeta<T>(name: String, meta: McpPromptMeta, args: Array<TypeInfo>,
        fn: (Array<JsonValue>) -> ArrayList<PromptMessage>): Unit where T <: Object {
        let function = try {
            TypeInfo.of<T>().getInstanceFunction(name, args)
        } catch (_: InfoNotFoundException) {
            throw McpException(McpProtocol.INTERNAL_ERROR, "prompt function '${name}' not found")
        }
        let promptName = if (meta.name.isEmpty()) {
            name
        } else {
            meta.name
        }
        let builder = McpPrompt.builder(promptName).description(meta.description)
        let params = function.parameters
        // 注册期把参数元数据算好：请求路径不再反射查 @McpPromptArg
        let argNames = ArrayList<String>()
        let argRequired = ArrayList<Bool>()
        for (param in params) {
            let argMeta = param.findAnnotation<McpPromptArg>() ?? McpPromptArg()
            argNames.add(param.name)
            argRequired.add(argMeta.required)
            builder.argument(param.name, description: argMeta.description, required: argMeta.required)
        }
        let prompt = builder.handler(
            {
                jsonArgs =>
                    let raw = ArrayList<JsonValue>()
                    var index = 0
                    while (index < argNames.size) {
                        let name = argNames[index]
                        match (jsonArgs.get(name)) {
                            case Some(value) => raw.add(value)
                            case _ =>
                                if (argRequired[index]) {
                                    throw McpException(McpProtocol.INVALID_PARAMS,
                                        "missing prompt argument '${name}'", data: JsonString(name))
                                }
                                raw.add(JsonNull.instance)
                        }
                        index++
                    }
                    fn(raw.unsafeData())
            }
        ).build()
        configure({b => b.prompt(prompt)})
    }

    /**
     * 设置 `serverInfo.name`；版本取 `mcp_version`，未配置时 `1.0.0`。
     *
     * `@Mcp[...]` 展开时会自动调用。
     */
    public static func serverInfo(name: String): Unit {
        configure({b => b.serverInfo(name, McpConfig.version())})
    }

    /**
     * 按当前累计的注册重建 `McpServer`，新注册的 tool / resource / prompt 立即生效。
     *
     * 可以重复调用（例如在 `main()` 里继续 `configure` 之后再调一次）；每次都是全量重建，
     * 因此不能在请求处理中调用——会丢掉结果缓存与订阅状态。
     */
    public static func build(): Unit {
        synchronized(mutex) {
            built = Some(builder.build())
        }
    }

    /**
     * 注解数值语义：`-1` 继承服务级、`0` 不限制、`>0` 限额。
     * 全部继承时返回 `None`，等价于没有工具级覆盖。
     */
    private static func toolRateLimitOf(meta: McpToolMeta): ?ToolRateLimit {
        let perCallerRpm = mapLimit(meta.perCallerRpm)
        let perCallerToolRpm = mapLimit(meta.perCallerToolRpm)
        let perToolRpm = mapLimit(meta.perToolRpm)
        let maxConcurrency = mapLimit(meta.maxConcurrency)
        let perCallerConcurrency = mapLimit(meta.perCallerConcurrency)
        if (perCallerRpm.isNone() && perCallerToolRpm.isNone() && perToolRpm.isNone() && maxConcurrency.isNone() &&
            perCallerConcurrency.isNone()) {
            return None<ToolRateLimit>
        }
        ToolRateLimit(perCallerRpm: perCallerRpm, perCallerToolRpm: perCallerToolRpm, perToolRpm: perToolRpm,
            maxConcurrency: maxConcurrency, perCallerConcurrency: perCallerConcurrency)
    }

    private static func mapLimit(value: Int64): ?Int64 {
        if (value < 0) {
            None<Int64>
        } else {
            Some(value)
        }
    }

    private static func withContext(contents: ArrayList<ResourceContent>, uri: String,
        mediaType: String): ArrayList<ResourceContent> {
        let normalized = ArrayList<ResourceContent>()
        for (content in contents) {
            let contentUri = if (content.uri.isEmpty()) {
                uri
            } else {
                content.uri
            }
            let contentMime = if (mediaType.isEmpty()) {
                content.mimeType
            } else {
                Some(mediaType)
            }
            normalized.add(ResourceContent(contentUri, contentMime, content.text, content.blob))
        }
        normalized
    }

    public static func server(): McpServer {
        synchronized(mutex) {
            match (built) {
                case Some(server) => server
                case _ =>
                    let server = builder.build()
                    built = Some(server)
                    server
            }
        }
    }
}
