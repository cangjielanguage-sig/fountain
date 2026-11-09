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

import std.sync.AtomicInt64
import std.time.DateTime

/**
 * 采集运行时的时钟抽象。
 *
 * 预热需要「等待一小段时间」而用例不能真的睡 200ms，因此把读取时间与等待
 * 一起抽象出来；`FakeClock` 的 `wait` 直接推进虚拟时间。
 */
public interface Clock {
    func nowMs(): Int64

    func wait(ms: Int64): Unit
}

/** 生产实现：系统毫秒时间戳 + 真实休眠。 */
public class SystemClock <: Clock {
    public init() {}

    public func nowMs(): Int64 {
        DateTime.now().toUnixTimeStamp().toMilliseconds()
    }

    public func wait(ms: Int64): Unit {
        if (ms > 0) {
            sleep(Duration.millisecond * ms)
        }
    }
}

/** 用例替身：`wait` 前进虚拟时间，不阻塞。 */
public class FakeClock <: Clock {
    private let current: AtomicInt64

    public init() {
        this(0)
    }

    public init(startMs: Int64) {
        this.current = AtomicInt64(startMs)
    }

    public func nowMs(): Int64 {
        current.load()
    }

    public func wait(ms: Int64): Unit {
        advance(ms)
    }

    /** 直接推进虚拟时间。 */
    public func advance(ms: Int64): Unit {
        if (ms > 0) {
            current.fetchAdd(ms)
        }
    }
}
