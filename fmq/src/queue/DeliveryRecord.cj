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
package fountain::fmq.queue

import std.time.DateTime
import fountain::f_io.LogPosition

/**
 * 一条「已扫描但未确认」的记录。
 *
 * - `owner`：当前对该位置负责的订阅（`None` = 组内任意匹配者可取）；
 * - `delivered`：是否已真正投递出去（`false` = 已分配给 owner 但尚未被取走）；
 * - `decided`：不再需要投递（已确认 / 不适用 / 已进死信），可被 `committed` 吞并。
 */
protected class DeliveryRecord {
    let position: LogPosition
    /** 该记录之后的下一位置（推进 committed 时直接用，避免重启重读已确认记录）。 */
    let next: LogPosition
    var owner: ?String
    var deliverCount: Int64
    var lastDeliverTime: DateTime
    var delivered: Bool
    var decided: Bool

    init(position: LogPosition, next: LogPosition, owner: ?String, deliverCount: Int64, lastDeliverTime: DateTime,
        delivered: Bool, decided!: Bool = false) {
        this.position = position
        this.next = next
        this.owner = owner
        this.deliverCount = deliverCount
        this.lastDeliverTime = lastDeliverTime
        this.delivered = delivered
        this.decided = decided
    }
}
