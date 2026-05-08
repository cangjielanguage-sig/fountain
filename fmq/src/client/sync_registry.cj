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
package fountain::fmq.client

import fountain::f_protocol.default.{Message as ProtocolMessage, EncodedMessage}

/**
 * fsync 心跳注册管理器。
 * 定期更新生产者/消费者在 fsync 中的注册信息。
 *
 * Phase 7 为骨架占位。
 */
public class SyncRegistry {
    private let config: MqConfig
    private let client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, DataAny, MessageID>
    private let log = LoggerFactory.getLogger('fountain::fmq.SyncRegistry')

    public init(config: MqConfig,
                client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, DataAny, MessageID>) {
        this.config = config
        this.client = client
    }

    /**
     * 启动注册心跳（Phase 7 占位）。
     */
    public func startHeartbeat(): Unit {
        log.debug{"SyncRegistry startHeartbeat (placeholder)"}
    }
}
