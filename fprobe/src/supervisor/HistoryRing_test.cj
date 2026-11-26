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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_probe.{ProbeErrorCode, ProbeException}

/** 9.3：容量固定，超过容量丢弃最旧点，顺序保持「旧 → 新」。 */
@Test
public class HistoryRing_test {
    @TestCase
    public func appendBeyondCapacityDropsOldest(): Unit {
        let ring = HistoryRing(60)
        for (i in 0..60) {
            ring.append(Float64(i))
        }
        @Assert(ring.size(), 60)
        @Assert(ring.latest().getOrThrow(), 59.0)

        ring.append(60.0)
        @Assert(ring.size(), 60)
        let values = ring.values()
        @Assert(values.size, 60)
        @Assert(values[0], 1.0)
        @Assert(values[59], 60.0)
        @Assert(ring.latest().getOrThrow(), 60.0)
    }

    @TestCase
    public func emptyRingHasNoPoint(): Unit {
        let ring = HistoryRing(60)
        @Assert(ring.size(), 0)
        @Assert(ring.latest().isNone())
        @Assert(ring.values().isEmpty())
    }

    @TestCase
    public func invalidCapacityIsRejected(): Unit {
        var caught = false
        try {
            HistoryRing(0)
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.CONFIG)
            @Assert(e.message.contains("capacity"))
        }
        @Assert(caught)
    }
}
