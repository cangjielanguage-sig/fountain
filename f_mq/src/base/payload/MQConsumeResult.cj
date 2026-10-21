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
 * `CONSUME` 的响应载荷；`record` 为空数组表示「本次没有消息」。
 *
 * `queueIndex` 标明记录来自主题下的哪个队列：每个队列是独立的段日志，位置
 * `(segmentedIndex, segmentedOffset)` 只在队列内唯一，ACK 必须连同队列身份一起回传。
 */
@DataAssist[props fields]
public class MQConsumeResult {
    private var queueIndex: Int64 = 0
    private var segmentedIndex: Int64 = 0
    private var segmentedOffset: Int64 = 0
    private var record: MQBlob = MQBlob()

    public init() {}

    public init(queueIndex: Int64, segmentedIndex: Int64, segmentedOffset: Int64, record: Array<Byte>) {
        this.queueIndex = queueIndex
        this.segmentedIndex = segmentedIndex
        this.segmentedOffset = segmentedOffset
        this.record = MQBlob(record)
    }

    public init(queueIndex: Int64, segmentedIndex: Int64, segmentedOffset: Int64, record: MQBlob) {
        this.queueIndex = queueIndex
        this.segmentedIndex = segmentedIndex
        this.segmentedOffset = segmentedOffset
        this.record = record
    }

    public func hasMessage(): Bool {
        !record.isEmpty()
    }
}
