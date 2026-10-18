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
package fountain::f_mq.base.model

import fountain::f_data.*
import fountain::f_data.macros.*

/**
 * 客户端消费到的一条消息。
 *
 * `segmentedIndex` / `segmentedOffset` 是该消息在服务端段日志中的位置，`ack` 时原样回传。
 */
@DataAssist[props fields]
public class MQMessage {
    /** 订阅的 topic */
    private var topic: String = ''
    /** 消息 tags */
    private var tags: Array<String> = []
    /** 消息内容；`None` 表示 BODY 为 `DataNone` */
    private var body: ?DataAny = None
    /** 消息在 SegmentedLog 的段索引 */
    private var segmentedIndex: Int64 = 0
    /** 段内偏移 */
    private var segmentedOffset: Int64 = 0

    public init() {}

    public init(topic: String, tags: Array<String>, body: ?DataAny, segmentedIndex: Int64, segmentedOffset: Int64) {
        this.topic = topic
        this.tags = tags
        this.body = body
        this.segmentedIndex = segmentedIndex
        this.segmentedOffset = segmentedOffset
    }

    /**
     * 把 BODY 转换为 `T`。
     *
     * - 支持基本类型与 `@DataAssist` 类（`convert` 同时覆盖两条路径）；
     * - BODY 为空或类型不匹配时返回 `None`，不抛异常。
     */
    public func get<T>(): ?T where T <: DataFields<T> {
        match (body) {
            case Some(x) => convert<T>(x.data)
            case _ => None<T>
        }
    }
}
