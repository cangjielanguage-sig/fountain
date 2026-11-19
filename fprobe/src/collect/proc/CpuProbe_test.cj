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

import std.math.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_probe.{ProbeErrorCode, ProbeException}

private let CPU_FRAME_1 = '''
cpu  100 0 100 800 0 0 0 0 0 0
cpu0 50 0 50 400 0 0 0 0 0 0
cpu1 50 0 50 400 0 0 0 0 0 0
'''

private let CPU_FRAME_2 = '''
cpu  160 0 140 880 20 0 0 0 0 0
cpu0 80 0 70 440 10 0 0 0 0 0
cpu1 80 0 70 440 10 0 0 0 0 0
'''

private let CPU_LOADAVG = '0.50 1.25 2.75 1/123 456\n'

@Test
public class CpuProbe_test {
    @TestCase
    public func firstFrameOnlyEstablishesBaseline(): Unit {
        let reader = FixtureProcReader([
            ("/proc/stat", CPU_FRAME_1),
            ("/proc/loadavg", CPU_LOADAVG)
        ])
        let probe = CpuProbe(reader)
        let data = probe.data
        @Assert(probe.kind, "cpu")
        @Assert(data.get("usagePercent").getOrThrow().asDecimal().toFloat64() == 0.0)
        @Assert(data.get("iowaitPercent").getOrThrow().asDecimal().toFloat64() == 0.0)
        @Assert(data.get("load1").getOrThrow().asDecimal().toFloat64() == 0.50)
        @Assert(data.get("load5").getOrThrow().asDecimal().toFloat64() == 1.25)
        @Assert(data.get("load15").getOrThrow().asDecimal().toFloat64() == 2.75)
        @Assert(data.get("cores").getOrThrow().asInt().toInt64(), 2)
    }

    /** 总时间片 +200、idle +80、iowait +20 ⇒ usage 50%，iowait 10%。 */
    @TestCase
    public func secondFrameComputesUsageAndIowait(): Unit {
        let reader = FixtureProcReader([
            ("/proc/stat", CPU_FRAME_1),
            ("/proc/loadavg", CPU_LOADAVG)
        ])
        let probe = CpuProbe(reader)
        probe.data
        reader.set("/proc/stat", CPU_FRAME_2)
        let data = probe.data
        @Assert(abs(data.get("usagePercent").getOrThrow().asDecimal().toFloat64() - 50.0) < 1e-9)
        @Assert(abs(data.get("iowaitPercent").getOrThrow().asDecimal().toFloat64() - 10.0) < 1e-9)
        @Assert(data.get("cores").getOrThrow().asInt().toInt64(), 2)
    }

    @TestCase
    public func missingStatThrowsCollectError(): Unit {
        let reader = FixtureProcReader([("/proc/loadavg", CPU_LOADAVG)])
        var caught = false
        try {
            CpuProbe(reader).data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("/proc/stat"))
        }
        @Assert(caught)
    }

    @TestCase
    public func malformedStatThrowsCollectError(): Unit {
        let reader = FixtureProcReader([
            ("/proc/stat", "cpu not-a-number\n"),
            ("/proc/loadavg", CPU_LOADAVG)
        ])
        var caught = false
        try {
            CpuProbe(reader).data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
        }
        @Assert(caught)
    }
}
