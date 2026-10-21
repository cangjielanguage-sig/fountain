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
package fountain::fmq.metrics

import std.sync.{AtomicBool, AtomicInt64}
import std.unittest.*
import std.unittest.testmacro.*

@Test
class MQMetricsTest {
    /** 删除主题/组会清空全部计数器，含三个跳过计数（R4-G4）。 */
    @TestCase
    public func removeTopicAndGroupClearAllCounters(): Unit {
        let metrics = MQMetrics()
        metrics.incDelivered("/t", "g")
        metrics.incAcked("/t", "g")
        metrics.incRedelivered("/t", "g")
        metrics.incDeadLettered("/t", "g")
        metrics.incSkippedUnreadable("/t", "g")
        metrics.incSkippedNoMatch("/t", "g")
        metrics.incSkippedUnsupported("/t", "g")
        metrics.incDelivered("/t", "h")
        @Assert(metrics.size == 8)

        metrics.removeGroup("/t", "g")
        @Assert(metrics.size == 1)
        @Assert(metrics.deliveredOf("/t", "g") == 0)
        @Assert(metrics.skippedUnreadableOf("/t", "g") == 0)
        @Assert(metrics.skippedNoMatchOf("/t", "g") == 0)
        @Assert(metrics.skippedUnsupportedOf("/t", "g") == 0)
        @Assert(metrics.deliveredOf("/t", "h") == 1)

        metrics.removeTopic("/t")
        @Assert(metrics.size == 0)
        @Assert(metrics.deliveredOf("/t", "h") == 0)
    }

    /** 自增与删除主题/组并发：不得抛异常，也不得让计数路径中断（R4-G4）。 */
    @TestCase
    public func concurrentBumpAndRemoveDoesNotThrow(): Unit {
        let metrics = MQMetrics()
        let stop = AtomicBool(false)
        let done = AtomicInt64(0)
        let errors = AtomicInt64(0)
        for (w in 0..4) {
            spawn {
                for (i in 0..300) {
                    try {
                        metrics.incDelivered("/t", "g${w}")
                        metrics.incAcked("/t", "g${w}")
                        metrics.incSkippedNoMatch("/t", "g${w}")
                    } catch (_: Exception) {
                        errors.fetchAdd(1)
                    }
                }
                done.fetchAdd(1)
            }
        }
        // 与自增并发删除
        for (_ in 0..200) {
            try {
                metrics.removeTopic("/t")
                metrics.removeGroup("/t", "g0")
            } catch (_: Exception) {
                errors.fetchAdd(1)
            }
        }
        var waited = 0
        while (done.load() < 4 && waited < 500) {
            sleep(Duration.millisecond * 10)
            waited++
        }
        @Assert(done.load() == 4)
        @Assert(errors.load() == 0)
        metrics.removeTopic("/t")
        @Assert(metrics.size == 0)
    }

    /** 读取与删除并发：读取只走单 key 查询，不抛遍历异常（R4-G4）。 */
    @TestCase
    public func concurrentReadAndRemoveDoesNotThrow(): Unit {
        let metrics = MQMetrics()
        let errors = AtomicInt64(0)
        let done = AtomicInt64(0)
        for (w in 0..4) {
            spawn {
                for (_ in 0..300) {
                    try {
                        metrics.deliveredOf("/t", "g")
                        metrics.skippedUnsupportedOf("/t", "g")
                    } catch (_: Exception) {
                        errors.fetchAdd(1)
                    }
                }
                done.fetchAdd(1)
            }
        }
        for (_ in 0..200) {
            try {
                metrics.incDelivered("/t", "g")
                metrics.removeTopic("/t")
            } catch (_: Exception) {
                errors.fetchAdd(1)
            }
        }
        var waited = 0
        while (done.load() < 4 && waited < 500) {
            sleep(Duration.millisecond * 10)
            waited++
        }
        @Assert(done.load() == 4)
        @Assert(errors.load() == 0)
    }
}
