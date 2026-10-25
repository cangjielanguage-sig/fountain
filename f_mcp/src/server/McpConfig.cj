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
 * `token-bucket`（默认）/ `leaking-bucket` / `sliding-window` / `unlimited`。
 *
 * `mcp_publicBaseUrl` 是本服务对外暴露的根地址，用于大结果链接、SSE 地址与相对资源 URI。
 *
 * `mcp_version` 是 `server/discover` 返回的 `serverInfo.version`，未配置时 `1.0.0`。
 */
public class McpConfig {
    public static const RATE_LIMIT = 'mcp_rateLimit'
    public static const RATE_LIMIT_BACKEND = 'mcp_rateLimitBackend'
    public static const TRUST_FORWARDED_FOR = 'mcp_trustForwardedFor'
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

    /** 是否信任 `X-Forwarded-For`：必须是 `true` / `false`，默认 `false`。 */
    public static func trustForwardedFor(): Bool {
        match (Config.getString(TRUST_FORWARDED_FOR)) {
            case Some(value) => match (value.trimAscii().toAsciiLower()) {
                    case 'true' => true
                    case 'false' => false
                    case _ => throw IllegalArgumentException("${TRUST_FORWARDED_FOR} must be 'true' or 'false'")
                }
            case _ => false
        }
    }

    private static let FIELDS = ['perCallerRpm', 'perCallerToolRpm', 'perToolRpm', 'maxConcurrency',
        'perCallerConcurrency']
    private static let MAX_VALUE: Int64 = 1_000_000

    public static func rateLimit(): RateLimitPolicy {
        let raw = Config.getString(RATE_LIMIT)?.trimAscii() ?? ''
        if (raw.isEmpty()) {
            return RateLimitPolicy()
        }
        if (raw.startsWith('{')) {
            return parseJson(raw)
        }
        let parts = raw.split(',')
        if (parts.size > FIELDS.size) {
            throw IllegalArgumentException(
                "${RATE_LIMIT} accepts at most ${FIELDS.size} comma separated fields, got ${parts.size}")
        }
        // 尾部空段等价于省略；中间空段无法区分「省略」与「写错」，必须报错
        for (index in 0..parts.size) {
            if (!parts[index].trimAscii().isEmpty()) {
                continue
            }
            var later = index + 1
            while (later < parts.size) {
                if (!parts[later].trimAscii().isEmpty()) {
                    throw IllegalArgumentException(
                        "invalid ${RATE_LIMIT}.${FIELDS[index]}: empty field before '${parts[later].trimAscii()}'")
                }
                later++
            }
        }
        RateLimitPolicy(perCallerRpm: valueAt(parts, 0), perCallerToolRpm: valueAt(parts, 1),
            perToolRpm: valueAt(parts, 2), maxConcurrency: valueAt(parts, 3), perCallerConcurrency: valueAt(parts, 4))
    }

    private static func valueAt(parts: Array<String>, index: Int64): ?Int64 {
        if (index >= parts.size) {
            return None<Int64>
        }
        parseValue(parts[index], FIELDS[index])
    }

    /** 统一数值校验：空串 = 不设置、`0` = 不限制、负数 / 小数 / 超上限一律报错。 */
    private static func parseValue(text: String, field: String): ?Int64 {
        let trimmed = text.trimAscii()
        if (trimmed.isEmpty()) {
            return None<Int64>
        }
        let value = match (Int64.tryParse(trimmed)) {
            case Some(parsed) => parsed
            case _ => throw IllegalArgumentException(
                    "invalid ${RATE_LIMIT}.${field}: '${trimmed}' is not an integer")
        }
        if (value < 0) {
            throw IllegalArgumentException("invalid ${RATE_LIMIT}.${field}: must be >= 0, got ${value}")
        }
        if (value > MAX_VALUE) {
            throw IllegalArgumentException("invalid ${RATE_LIMIT}.${field}: must be <= ${MAX_VALUE}, got ${value}")
        }
        if (value == 0) {
            None<Int64>
        } else {
            Some(value)
        }
    }

    private static func parseJson(raw: String): RateLimitPolicy {
        let obj = match (JsonValue.fromStr(raw)) {
            case value: JsonObject => value
            case _ => throw IllegalArgumentException('${RATE_LIMIT} must be a JSON object')
        }
        for ((key, _) in obj) {
            if (!FIELDS.contains(key)) {
                throw IllegalArgumentException("unknown ${RATE_LIMIT} field '${key}', expected one of ${FIELDS}")
            }
        }
        RateLimitPolicy(perCallerRpm: jsonInt(obj, FIELDS[0]), perCallerToolRpm: jsonInt(obj, FIELDS[1]),
            perToolRpm: jsonInt(obj, FIELDS[2]), maxConcurrency: jsonInt(obj, FIELDS[3]),
            perCallerConcurrency: jsonInt(obj, FIELDS[4]))
    }

    private static func jsonInt(obj: JsonObject, key: String): ?Int64 {
        match (obj.get(key)) {
            case Some(value) =>
                // JSON 只接受整数：小数会让「1.5 rpm」这种输入静默截断
                match (value) {
                    case number: JsonInt => parseValue(number.value.toString(), key)
                    case number: JsonDecimal =>
                        // 解析器把 JSON 数字统一读成 Decimal：这里按字面量判整数
                        let text = number.value.toString()
                        if (text.contains('.') || text.contains('e') || text.contains('E')) {
                            throw IllegalArgumentException(
                                "invalid ${RATE_LIMIT}.${key}: must be an integer, got ${text}")
                        }
                        parseValue(text, key)
                    case _ => throw IllegalArgumentException(
                            "invalid ${RATE_LIMIT}.${key}: must be an integer")
                }
            case _ => None<Int64>
        }
    }
}
