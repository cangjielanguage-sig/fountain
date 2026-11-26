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
package fountain::fprobe.collect

/**
 * 单调计数器差分工具。
 *
 * 每个计数器实例对应一个指标；首次采样只建立基线，时间未推进时返回 None，
 * 计数回绕（当前值小于上次值）按 0 增量处理，避免出现负速率。
 */
public class IntervalCounter {
    private var hasBaseline = false
    private var lastValue: Int64 = 0
    private var lastTimestampMs: Int64 = 0

    public init() {}

    /** 返回自上次采样以来的每秒增量；无法计算时返回 None。 */
    public func update(current: Int64, nowMs: Int64): ?Float64 {
        if (!hasBaseline) {
            hasBaseline = true
            lastValue = current
            lastTimestampMs = nowMs
            return None<Float64>
        }

        let elapsedMs = nowMs - lastTimestampMs
        if (elapsedMs <= 0) {
            return None<Float64>
        }

        var delta = current - lastValue
        if (delta < 0) {
            delta = 0
        }
        lastValue = current
        lastTimestampMs = nowMs
        Float64(delta) * 1000.0 / Float64(elapsedMs)
    }
}
