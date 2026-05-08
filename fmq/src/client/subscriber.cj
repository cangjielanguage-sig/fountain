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

/**
 * 订阅管理器。
 * 管理消费者订阅，向 fsync 注册订阅信息。
 *
 * Phase 7 为骨架占位，fsync 集成在后续阶段。
 */
public class Subscriber {
    private let config: MqConfig
    private let log = LoggerFactory.getLogger('fountain::fmq.Subscriber')
    private let subscriptions = ArrayList<(String, MatchMode)>()  // (groupId, matchMode)

    public init(config: MqConfig) {
        this.config = config
    }

    /**
     * 订阅主题（带 labels 或 dataFilter）。
     */
    public func subscribe(groupId: String, matchMode: MatchMode,
                          labels!: ArrayList<String> = ArrayList(),
                          dataFilter!: String = ""): Bool {
        log.debug{"subscribe group=${groupId} (placeholder)"}
        subscriptions.add((groupId, matchMode))
        // Phase 7: 写入 fsync /mq/consumes
        true
    }

    /**
     * 取消订阅。
     */
    public func unsubscribe(groupId: String, matchMode: MatchMode): Bool {
        log.debug{"unsubscribe group=${groupId} (placeholder)"}
        // Phase 7: 从 fsync /mq/consumes 移除
        true
    }
}
