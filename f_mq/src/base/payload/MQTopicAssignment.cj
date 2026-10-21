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
package fountain::f_mq.base.payload

import fountain::f_data.*
import fountain::f_data.macros.*

/**
 * 主题的队列分配结果。
 *
 * `owners` 显式携带每个队列的所属节点下标，使分配结果自包含，不依赖各节点对节点表的一致理解。
 */
@DataAssist[props fields]
public class MQTopicAssignment {
    private var topic: String = ''
    private var queueNum: Int64 = 0
    /** 本次分配的起始节点下标（轮转指针） */
    private var startNodeIndex: Int64 = 0
    /** `owners[i]` = 队列 i 的所属节点下标 */
    private var owners: Array<Int64> = []
    /** 延迟投递时长（毫秒），0 表示不延迟 */
    private var delayingMs: Int64 = 0
    /** 元数据版本（Lamport 计数），0 表示旧数据 */
    private var revision: Int64 = 0
    /** 版本的产生节点；同 revision 时用于打破平局 */
    private var origin: Int64 = 0

    public init() {}

    public init(topic: String, queueNum: Int64, startNodeIndex: Int64, owners: Array<Int64>,
        delayingMs!: Int64 = 0, revision!: Int64 = 0, origin!: Int64 = 0) {
        this.topic = topic
        this.queueNum = queueNum
        this.startNodeIndex = startNodeIndex
        this.owners = owners
        this.delayingMs = delayingMs
        this.revision = revision
        this.origin = origin
    }

    /** 队列对应的 owner 节点下标；越界返回 `None`。 */
    public func owner(queueIndex: Int64): ?Int64 {
        if (queueIndex < 0 || queueIndex >= owners.size) {
            None<Int64>
        } else {
            Some(owners[queueIndex])
        }
    }
}
