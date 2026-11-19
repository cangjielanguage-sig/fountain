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
package fountain::fprobe.supervisor

import std.collection.ArrayList
import fountain::f_probe.{ProbeErrorCode, ProbeException}

/**
 * 固定容量的历史窗口（设计 D9 / spec「历史窗口」）。
 *
 * 点按时间顺序追加，超过容量时丢弃最旧点；`values()` 总按「旧 → 新」返回，
 * TUI 图表与报告直接消费该顺序。
 *
 * 单写者模型：由拉取线程追加，同一时刻只允许一个写者；读取方拿到的是副本。
 */
public class HistoryRing {
    public let capacity: Int64
    private let points = ArrayList<Float64>()

    public init(capacity: Int64) {
        if (capacity < 1) {
            throw ProbeException(ProbeErrorCode.CONFIG,
                "history ring capacity must be >= 1, got ${capacity}")
        }
        this.capacity = capacity
    }

    /** 追加一个点；容量已满时先丢弃最旧点。 */
    public func append(value: Float64): Unit {
        if (points.size >= capacity) {
            points.remove(at: 0)
        }
        points.add(value)
    }

    /** 当前点数，不超过容量。 */
    public func size(): Int64 {
        points.size
    }

    /** 历史副本，顺序为「旧 → 新」。 */
    public func values(): Array<Float64> {
        points.toArray()
    }

    /** 最新点；空窗口返回 `None`（不伪造 0 值）。 */
    public func latest(): ?Float64 {
        if (points.isEmpty()) {
            return None<Float64>
        }
        Some(points[points.size - 1])
    }
}
