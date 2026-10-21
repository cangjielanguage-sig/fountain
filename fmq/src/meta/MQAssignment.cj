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
package fountain::fmq.meta

import std.collection.{HashMap, Map}
import fountain::f_mq.base.MQTopic
import fountain::f_mq.base.payload.MQTopicAssignment

/**
 * 队列轮转分配（纯函数）。
 *
 * `owners[i] = (start + i) % nodeCount`；下一主题的起始下标为 `(start + queueNum) % nodeCount`。
 */
protected class MQAssignment {
    protected static func allocate(topic: String, queueNum: Int64, nodeCount: Int64, start: Int64,
        delayingMs!: Int64 = 0, revision!: Int64 = 0, origin!: Int64 = 0): MQTopicAssignment {
        if (queueNum < 1) {
            throw IllegalArgumentException("queueNum must be at least 1, got ${queueNum}")
        }
        if (nodeCount < 1) {
            throw IllegalArgumentException("nodeCount must be at least 1, got ${nodeCount}")
        }
        let normalized = normalize(start, nodeCount)
        let owners = Array<Int64>(queueNum) {i => (normalized + i) % nodeCount}
        MQTopicAssignment(topic, queueNum, normalized, owners, delayingMs: delayingMs, revision: revision,
            origin: origin)
    }

    protected static func nextStart(start: Int64, queueNum: Int64, nodeCount: Int64): Int64 {
        if (nodeCount < 1) {
            throw IllegalArgumentException("nodeCount must be at least 1, got ${nodeCount}")
        }
        normalize(start + queueNum, nodeCount)
    }

    /**
     * 结构校验：远端/快照里的分配必须自洽，畸形载荷不得落盘（A34）。
     *
     * 校验项：主题名、队列数、owners 数量、起点与 owner 范围、延迟非负、版本与来源范围。
     */
    protected static func validate(assignment: MQTopicAssignment, nodeCount: Int64): Bool {
        if (nodeCount < 1 || !MQTopic.isValid(assignment.topic)) {
            return false
        }
        if (assignment.queueNum < 1 || assignment.owners.size != assignment.queueNum) {
            return false
        }
        if (assignment.startNodeIndex < 0 || assignment.startNodeIndex >= nodeCount) {
            return false
        }
        if (assignment.delayingMs < 0 || assignment.revision < 0) {
            return false
        }
        if (assignment.origin < 0 || assignment.origin >= nodeCount) {
            return false
        }
        for (owner in assignment.owners) {
            if (owner < 0 || owner >= nodeCount) {
                return false
            }
        }
        true
    }

    protected static func ownersOf(assignment: MQTopicAssignment): Map<Int64, Int64> {
        let result = HashMap<Int64, Int64>()
        for (i in 0..assignment.owners.size) {
            result.add(i, assignment.owners[i])
        }
        result
    }

    private static func normalize(value: Int64, nodeCount: Int64): Int64 {
        let remainder = value % nodeCount
        if (remainder < 0) {
            remainder + nodeCount
        } else {
            remainder
        }
    }
}
