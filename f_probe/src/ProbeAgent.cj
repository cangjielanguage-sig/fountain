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
package fountain::f_probe

import fountain::f_data.JsonObject

/**
 * 统一监控项契约。
 *
 * `kind` 必须全局唯一且稳定，作为快照数据键与配置键；`data` 必须是 JSON object。
 * 扩展通常只需要覆写 [kind] 与 [data]。
 */
public interface ProbeAgent {
    /** 受监控类型，例如 `cpu`、`memory`、`k8s`。 */
    prop kind: String

    /** 受监控主机；扩展未指定时由宿主用配置或本机主机名补齐。 */
    prop host: String {
        get() {
            ""
        }
    }

    /** 监控数据，必须是 JSON object。 */
    prop data: JsonObject
}
