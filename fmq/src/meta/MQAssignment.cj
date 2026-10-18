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
import fountain::f_mq.base.payload.MQTopicAssignment

/**
 * 队列轮转分配（纯函数）。
 *
 * `owners[i] = (start + i) % nodeCount`；下一主题的起始下标为 `(start + queueNum) % nodeCount`。
 */
protected class MQAssignment {
    protected static func allocate(topic: String, queueNum: Int64, nodeCount: Int64, start: Int64): MQTopicAssignment {
        if (queueNum < 1) {
            throw IllegalArgumentException("queueNum must be at least 1, got ${queueNum}")
        }
        if (nodeCount < 1) {
            throw IllegalArgumentException("nodeCount must be at least 1, got ${nodeCount}")
        }
        let normalized = normalize(start, nodeCount)
        let owners = Array<Int64>(queueNum) {i => (normalized + i) % nodeCount}
        MQTopicAssignment(topic, queueNum, normalized, owners)
    }

    protected static func nextStart(start: Int64, queueNum: Int64, nodeCount: Int64): Int64 {
        if (nodeCount < 1) {
            throw IllegalArgumentException("nodeCount must be at least 1, got ${nodeCount}")
        }
        normalize(start + queueNum, nodeCount)
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
