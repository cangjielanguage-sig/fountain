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
import fountain::f_data.*
import fountain::f_mcp.base.*

/** 资源读取上下文。 */
public class McpResourceContext {
    public let uri: String
    public let callerId: String

    public init(uri: String, callerId: String) {
        this.uri = uri
        this.callerId = callerId
    }
}

public type McpResourceHandler = (McpResourceContext) -> ArrayList<ResourceContent>

/** 一个静态资源。 */
public class McpResource {
    /** `listResources` 条目 JSON 的构建期缓存。 */
    var listJson: ?JsonObject = None

    public let uri: String
    public let name: String
    public let description: String
    public let mimeType: ?String
    public let handler: McpResourceHandler

    init(uri!: String, name!: String, description!: String, mimeType!: ?String, handler!: McpResourceHandler) {
        this.uri = uri
        this.name = name
        this.description = description
        this.mimeType = mimeType
        this.handler = handler
    }

    public static func builder(uri: String, name: String): McpResourceBuilder {
        McpResourceBuilder(uri, name)
    }

    /**
     * 解析相对资源 URI：`/doc` 会拼成 `${publicBaseUrl}/doc`；
     * 已经是完整 URL 的资源原样返回。
     */
    func resolved(baseUrl: ?String): McpResource {
        if (!uri.startsWith('/')) {
            return this
        }
        let base = match (baseUrl) {
            case Some(value) => value
            case _ => throw McpException(McpProtocol.INTERNAL_ERROR,
                "resource '${uri}' uses a path URI but publicBaseUrl is not configured")
        }
        let full = '${base}${uri}'
        McpResourceBuilder.validateUri(full)
        McpResource(uri: full, name: name, description: description, mimeType: mimeType, handler: handler)
    }
}

public class McpResourceBuilder {
    private let uri: String
    private let name: String
    private var description_ = ''
    private var mimeType_: ?String = None
    private var handler_: ?McpResourceHandler = None

    init(uri: String, name: String) {
        this.uri = uri
        this.name = name
    }

    public func description(text: String): McpResourceBuilder {
        description_ = text
        this
    }

    public func mimeType(value: String): McpResourceBuilder {
        mimeType_ = Some(value)
        this
    }

    public func handler(handler: McpResourceHandler): McpResourceBuilder {
        handler_ = Some(handler)
        this
    }

    public func build(): McpResource {
        validateUri(uri)
        match (handler_) {
            case Some(h) => McpResource(uri: uri, name: name, description: description_, mimeType: mimeType_, handler: h)
            case _ => throw McpException(McpProtocol.INTERNAL_ERROR, "resource '${uri}' has no handler")
        }
    }

    /**
     * 只接受三种形式：
     * - 完整 `http` / `https` / `ftp` URL
     * - 以 `/` 开头的绝对路径（构建服务时用 `publicBaseUrl` 拼成完整 URL）
     *
     * 不允许 fragment，不允许 `//` 协议相对地址，不允许占用临时结果前缀。
     */
    public static func validateUri(uri: String): Unit {
        if (uri.contains('#')) {
            throw McpException(McpProtocol.INVALID_PARAMS, "resource uri must not contain a fragment",
                data: JsonString(uri))
        }
        if (uri.contains(McpProtocol.TOOL_RESULT_PREFIX)) {
            throw McpException(McpProtocol.INVALID_PARAMS,
                "resource uri prefix '${McpProtocol.TOOL_RESULT_PREFIX}' is reserved", data: JsonString(uri))
        }
        if (uri.startsWith('/')) {
            if (uri.startsWith('//')) {
                throw McpException(McpProtocol.INVALID_PARAMS,
                    "resource uri must be an absolute path or a full http(s)/ftp URL", data: JsonString(uri))
            }
            return
        }
        if (!(uri.startsWith('http://') || uri.startsWith('https://') || uri.startsWith('ftp://'))) {
            throw McpException(McpProtocol.INVALID_PARAMS, "resource uri must be an absolute path or a full http(s)/ftp URL",
                data: JsonString(uri))
        }
    }
}
