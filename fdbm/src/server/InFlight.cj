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
package fountain::fdbm.server

import std.sync.{AtomicInt64, Condition, Mutex}
import std.time.MonoTime
import fountain::f_log.LoggerFactory

/**
 * 在途请求计数（设计 §10.3）：优雅停止时先等它归零，再关会话与连接池。
 *
 * `enter` / `leave` 必须成对（`FdbmHandler` 用 `finally` 保证）；`await` 在归零时返回 `true`，
 * 超时返回 `false` 并记 WARN（停止流程继续，不把进程卡死）。
 */
protected struct InFlight {
    private static let logger = LoggerFactory.getLogger('fountain::fdbm.server.InFlight')
    private static let mutex = Mutex()
    private static let counter = AtomicInt64(0)
    private static let condition = synchronized(mutex) {
        mutex.condition()
    }

    public static func enter(): Unit {
        counter.fetchAdd(1)
    }

    public static func leave(): Unit {
        synchronized(mutex) {
            if (counter.fetchAdd(-1) <= 1) {
                condition.notifyAll()
            }
        }
    }

    public static func count(): Int64 {
        counter.load()
    }

    public static func await(timeout: Duration): Bool {
        synchronized(mutex) {
            if (counter.load() == 0) {
                return true
            }
            let start = MonoTime.now()
            while (counter.load() > 0) {
                let remaining = timeout - (MonoTime.now() - start)
                if (remaining <= Duration.Zero) {
                    logger.warn('still ${counter.load()} request(s) in flight after ${timeout}; continuing shutdown')
                    return false
                }
                if (!condition.wait(timeout: remaining) && counter.load() > 0) {
                    logger.warn('still ${counter.load()} request(s) in flight after ${timeout}; continuing shutdown')
                    return false
                }
            }
            true
        }
    }
}
