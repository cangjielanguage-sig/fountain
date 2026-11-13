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
package fountain::fprobe.collect.health

import fountain::f_data.*
import fountain::f_probe.ProbeAgent

/**
 * MVC `/health` 端点探针。
 *
 * 只读取 `probe_mvcHealthUrl` 指向的地址；成功时把 `HealthData` 同名字段展开到数据根，
 * 并附带 `latencyMs` 与 `statusCode`。非 200、超时或响应非法都收敛为 `error`，
 * 不抛异常，避免一个端点拖垮整次采集。
 */
public class MvcHealthProbe <: ProbeAgent {
    private let http: HttpProbe
    private let url: String
    private let timeoutMs: Int64

    public init(http: HttpProbe, url: String, timeoutMs!: Int64 = 2000) {
        this.http = http
        this.url = url
        this.timeoutMs = timeoutMs
    }

    public prop kind: String {
        get() {
            "mvc-health"
        }
    }

    public prop data: JsonObject {
        get() {
            if (url.trimAscii().isEmpty()) {
                return healthJson(HealthSample(0.0, 0, "未配置 probe_mvcHealthUrl"))
            }

            let response = http.get(url, timeoutMs)
            if (response.timedOut) {
                return healthJson(HealthSample(response.latencyMs, 0, response.error))
            }
            if (!response.error.isEmpty()) {
                return healthJson(HealthSample(response.latencyMs, response.statusCode, response.error))
            }
            if (response.statusCode < 200 || response.statusCode >= 400) {
                return healthJson(HealthSample(response.latencyMs, response.statusCode,
                    'HTTP 状态码 ${response.statusCode}'))
            }

            match (HealthMetrics.tryParse(response.body)) {
                case Some(metrics) => healthJson(HealthSample(metrics, response.latencyMs, response.statusCode, ""))
                case None => healthJson(HealthSample(response.latencyMs, response.statusCode,
                        "响应不是合法 HealthData JSON"))
            }
        }
    }
}

private func healthJson(value: HealthSample): JsonObject {
    JsonValue.from(value.toData()).asObject()
}
