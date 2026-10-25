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

import fountain::f_config.Config
import fountain::f_data.*

/**
 * MCP 配置项。
 *
 * `mcp_rateLimit` 支持两种写法：
 * - 逗号分隔：`perCallerRpm,perCallerToolRpm,perToolRpm,maxConcurrency,perCallerConcurrency`
 * - JSON：`{"perCallerRpm":600,"perCallerToolRpm":120,"perToolRpm":6000}`
 *
 * 省略的字段表示不限制。
 *
 * `mcp_rateLimitBackend` 选择进程内限流算法：
 * `token-bucket`（默认）/ `leaking-bucket` / `sliding-window` / `any-moment` / `unlimited`。
 *
 * `mcp_publicBaseUrl` 是本服务对外暴露的根地址，用于大结果链接、SSE 地址与相对资源 URI。
 *
 * `mcp_version` 是 `server/discover` 返回的 `serverInfo.version`，未配置时 `1.0.0`。
 */
public class McpConfig {
    public static const RATE_LIMIT = 'mcp_rateLimit'
    public static const RATE_LIMIT_BACKEND = 'mcp_rateLimitBackend'
    public static const PUBLIC_BASE_URL = 'mcp_publicBaseUrl'
    public static const VERSION = 'mcp_version'

    /** `mcp_version`，去掉首尾空白；未配置或为空时返回 `1.0.0`。 */
    public static func version(): String {
        let value = Config.getString(VERSION)?.trimAscii() ?? ''
        if (value.isEmpty()) {
            '1.0.0'
        } else {
            value
        }
    }

    /** `mcp_publicBaseUrl`，去掉首尾空白与末尾 `/`；未配置或为空时返回 `None`。 */
    public static func publicBaseUrl(): ?String {
        match (Config.getString(PUBLIC_BASE_URL)) {
            case Some(value) =>
                var url = value.trimAscii()
                while (url.endsWith('/') && !url.isEmpty()) {
                    url = url[0..url.size - 1]
                }
                if (url.isEmpty()) {
                    None<String>
                } else {
                    Some(url)
                }
            case _ => None<String>
        }
    }

    /** `mcp_rateLimitBackend` 的原始值；未配置时为空串。 */
    public static func rateLimitBackendName(): String {
        Config.getString(RATE_LIMIT_BACKEND)?.trimAscii() ?? ''
    }

    public static func rateLimit(): RateLimitPolicy {
        let raw = Config.getString(RATE_LIMIT)?.trimAscii() ?? ''
        if (raw.isEmpty()) {
            return RateLimitPolicy()
        }
        if (raw.startsWith('{')) {
            return parseJson(raw)
        }
        let parts = raw.split(',')
        RateLimitPolicy(
            perCallerRpm: intAt(parts, 0),
            perCallerToolRpm: intAt(parts, 1),
            perToolRpm: intAt(parts, 2),
            maxConcurrency: intAt(parts, 3),
            perCallerConcurrency: intAt(parts, 4))
    }

    private static func intAt(parts: Array<String>, index: Int64): ?Int64 {
        if (index >= parts.size) {
            return None<Int64>
        }
        let text = parts[index].trimAscii()
        if (text.isEmpty()) {
            return None<Int64>
        }
        match (Int64.tryParse(text)) {
            case Some(value) => Some(value)
            case _ => throw IllegalArgumentException("invalid mcp_rateLimit segment '${text}'")
        }
    }

    private static func parseJson(raw: String): RateLimitPolicy {
        let obj = match (JsonValue.fromStr(raw)) {
            case value: JsonObject => value
            case _ => throw IllegalArgumentException('mcp_rateLimit must be a JSON object')
        }
        RateLimitPolicy(
            perCallerRpm: jsonInt(obj, 'perCallerRpm'),
            perCallerToolRpm: jsonInt(obj, 'perCallerToolRpm'),
            perToolRpm: jsonInt(obj, 'perToolRpm'),
            maxConcurrency: jsonInt(obj, 'maxConcurrency'),
            perCallerConcurrency: jsonInt(obj, 'perCallerConcurrency'))
    }

    private static func jsonInt(obj: JsonObject, key: String): ?Int64 {
        match (obj.get(key)) {
            case Some(value) =>
                if (value is JsonInt || value is JsonDecimal) {
                    Some(value.asInt().toInt64())
                } else {
                    throw IllegalArgumentException("mcp_rateLimit.${key} must be an integer")
                }
            case _ => None<Int64>
        }
    }
}
