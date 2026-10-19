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
 * 死信条目：自描述，包含原始记录与来源上下文。
 *
 * 自描述是为了避免「裸字节 + 外部元数据」脱节；同一套 codec 即可读取。
 */
@DataAssist[props fields]
public class MQDeadLetterMessage {
    private var topic: String = ''
    private var queueIndex: Int64 = 0
    private var subscribeGroup: String = ''
    private var segmentedIndex: Int64 = 0
    private var segmentedOffset: Int64 = 0
    private var deliverCount: Int64 = 0
    private var deadTime: DateTime = DateTime.now()
    private var record: Array<Byte> = []

    public init() {}

    public init(topic: String, queueIndex: Int64, subscribeGroup: String, segmentedIndex: Int64,
        segmentedOffset: Int64, deliverCount: Int64, deadTime: DateTime, record: Array<Byte>) {
        this.topic = topic
        this.queueIndex = queueIndex
        this.subscribeGroup = subscribeGroup
        this.segmentedIndex = segmentedIndex
        this.segmentedOffset = segmentedOffset
        this.deliverCount = deliverCount
        this.deadTime = deadTime
        this.record = record
    }
}
