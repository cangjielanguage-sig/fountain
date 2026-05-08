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
 * 心跳注册管理器。
 * 通过周期性 PING 保持 MQ 服务端连接活跃。
 * 使用 Timer.repeat 驱动心跳间隔。
 */
public class SyncRegistry {
    private let config: MqConfig
    private let client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>
    private let log = LoggerFactory.getLogger('fountain::fmq.SyncRegistry')
    private var heartbeatTimer: ?Timer = None

    public init(config: MqConfig,
                client: Client<ProtocolMessage, EncodedMessage, ProtocolMessage, MqBody, MessageID>) {
        this.config = config
        this.client = client
    }

    /**
     * 启动心跳定时器。
     * 按 heartbeatIntervalSec 间隔发送 PING。
     */
    public func startHeartbeat(): Unit {
        if (heartbeatTimer != None) {
            log.debug{"heartbeat already running"}
            return
        }
        let interval = Duration.second * config.heartbeatIntervalSec
        let selfRef = this
        heartbeatTimer = Timer.repeat(interval, interval, {
            => selfRef.sendHeartbeat()
        })
        log.info{"SyncRegistry heartbeat started (interval=${config.heartbeatIntervalSec}s)"}
    }

    /**
     * 停止心跳。
     */
    public func stopHeartbeat(): Unit {
        if (let Some(t) <- heartbeatTimer) {
            t.cancel()
            heartbeatTimer = None
            log.info{"SyncRegistry heartbeat stopped"}
        }
    }

    /**
     * 发送单次心跳。
     */
    private func sendHeartbeat(): Unit {
        try {
            let req = ProtocolMessage(Command.PING(0), MessageID(),
                MqBody("ping", []).toData())
            let resp = client.transfer(req.id, req, Duration.second * 5)
            if (resp.isSome()) {
                log.debug{"heartbeat OK"}
            } else {
                log.warn{"heartbeat: no response"}
            }
        } catch (e: Exception) {
            log.warn{"heartbeat error: ${e.message}"}
        }
    }

    /**
     * 是否在运行。
     */
    public func isRunning(): Bool {
        heartbeatTimer != None
    }
}
