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
package fountain::fprobe.collect.proc

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_probe.{ProbeErrorCode, ProbeException}

private let MEMINFO = '''
MemTotal:       16000000 kB
MemFree:         4000000 kB
MemAvailable:   10000000 kB
Buffers:          500000 kB
Cached:          3000000 kB
SwapTotal:       2000000 kB
SwapFree:        1500000 kB
'''

@Test
public class MemoryProbe_test {
    @TestCase
    public func readsAllFieldsAndComputesUsedFromAvailable(): Unit {
        let probe = MemoryProbe(FixtureProcReader([("/proc/meminfo", MEMINFO)]))
        let data = probe.data
        @Assert(probe.kind, "memory")
        @Assert(data.get("totalBytes").getOrThrow().asInt().toInt64(), 16000000 * 1024)
        // used = total - available，而不是 total - free
        @Assert(data.get("usedBytes").getOrThrow().asInt().toInt64(), 6000000 * 1024)
        @Assert(data.get("availableBytes").getOrThrow().asInt().toInt64(), 10000000 * 1024)
        @Assert(data.get("freeBytes").getOrThrow().asInt().toInt64(), 4000000 * 1024)
        @Assert(data.get("cachedBytes").getOrThrow().asInt().toInt64(), 3000000 * 1024)
        @Assert(data.get("buffersBytes").getOrThrow().asInt().toInt64(), 500000 * 1024)
        @Assert(data.get("swapTotalBytes").getOrThrow().asInt().toInt64(), 2000000 * 1024)
        @Assert(data.get("swapUsedBytes").getOrThrow().asInt().toInt64(), 500000 * 1024)
        @Assert(data.get("swapFreeBytes").getOrThrow().asInt().toInt64(), 1500000 * 1024)
    }

    @TestCase
    public func missingTotalThrowsCollectError(): Unit {
        let probe = MemoryProbe(FixtureProcReader([
            ("/proc/meminfo", "MemFree: 100 kB\nMemAvailable: 50 kB\n")
        ]))
        var caught = false
        try {
            probe.data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("MemTotal"))
        }
        @Assert(caught)
    }

    @TestCase
    public func missingAvailableThrowsCollectError(): Unit {
        let probe = MemoryProbe(FixtureProcReader([
            ("/proc/meminfo", "MemTotal: 100 kB\nMemFree: 50 kB\n")
        ]))
        var caught = false
        try {
            probe.data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("MemAvailable"))
        }
        @Assert(caught)
    }
}
