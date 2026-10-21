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
package fountain::f_mq.client

import fountain::f_config.Config
import fountain::f_mq.base.{MQConfigKey, MQHost}
import fountain::f_mq.exception.MQConnectionException

/**
 * 客户端配置：节点列表按配置顺序即节点下标顺序。
 *
 * 配置缺失、为空或存在非法 `host:port` 时在构造期抛 `MQConnectionException`，不静默跳过。
 */
public struct MQClientConfig {

    /** 从 `mqClient_hosts` 读取节点表（每项 `host:port`）。 */
    public static prop hosts: Array<String> {
        get() {
            let entries = Config.getStringArray(MQConfigKey.CLIENT_HOSTS)
            if (entries.size == 0) {
                throw MQConnectionException("configuration '${MQConfigKey.CLIENT_HOSTS}' is required")
            }
            for (entry in entries) {
                if (MQHost.parseHost(entry).isNone()) {
                    throw MQConnectionException(
                        "invalid node '${entry}' in '${MQConfigKey.CLIENT_HOSTS}', expect host:port")
                }
            }
            entries
        }
    }
}
