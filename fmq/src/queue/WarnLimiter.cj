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

import std.collection.{ArrayList, HashMap}
import std.sync.Mutex
import std.time.DateTime

/**
 * 按 key 的秒级日志限流。
 *
 * 段缺失/游标越过段末会在每次读取时重复触发；同一位置刷屏会淹没真正有用的日志，
 * 因此按 `(队列, 位置)` 记住上次输出时间，窗口内只放行一条（R3-M9）。
 */
protected class WarnLimiter {
    private let windowMs: Int64
    private let nowMs: () -> Int64
    private let lock = Mutex()
    private let last = HashMap<String, Int64>()

    init(windowMs!: Int64 = 1000,
        nowMs!: () -> Int64 = {=> DateTime.now().toUnixTimeStamp().toMilliseconds()}) {
        this.windowMs = windowMs
        this.nowMs = nowMs
    }

    /** 这次是否应当输出；窗口内的重复调用返回 `false`。 */
    func allow(key: String): Bool {
        synchronized(lock) {
            let now = nowMs()
            match (last.get(key)) {
                case Some(previous) =>
                    if (now - previous < windowMs) {
                        return false
                    }
                case None => ()
            }
            if (last.size > 1024) {
                // 键空间有界：过期项先清掉，避免长跑进程无限增长
                let expired = ArrayList<String>()
                for ((k, at) in last) {
                    if (now - at >= windowMs) {
                        expired.add(k)
                    }
                }
                for (k in expired) {
                    last.remove(k)
                }
            }
            last.add(key, now)
            true
        }
    }
}
