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
package fountain::f_concurrent

import std.sync.AtomicBool
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class ExecutorPoolTest {
    @TestCase
    public func slowTaskLeavesAnotherWorkerAvailable(): Unit {
        let pool = Executors<Bool>(executors: 2)
        let limiter = UnlimitedRateLimiter<Unit>()
        let started = AtomicBool(false)
        let released = AtomicBool(false)
        try {
            let slow = pool.call(limiter) {
                started.store(true)
                let deadline = MonoTime.now() + Duration.second * 2
                while (!released.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
                Some(released.load())
            }
            let deadline = MonoTime.now() + Duration.second * 2
            while (!started.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            @Assert(started.load())
            let fast = pool.call(limiter) { released.store(true); Some(true) }
            @Assert(fast.get())
            @Assert(slow.get())
        } finally {
            released.store(true)
            pool.shutdown()
        }
    }
}
