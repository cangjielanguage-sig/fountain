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
package fountain::f_svg

/** 动画时钟；`now()` 返回文档时间（秒）。 */
public interface SvgClock {
    func now(): Float64
}

/** 手动时钟：用于确定性采样。 */
public class SvgManualClock <: SvgClock {
    public var time: Float64
    private var enabled = true

    public init(time!: Float64 = 0.0) {
        this.time = time
    }

    public func now(): Float64 {
        this.time
    }

    public func stop(): Unit {
        this.enabled = false
    }

    public func start(): Unit {
        this.enabled = true
    }
}
