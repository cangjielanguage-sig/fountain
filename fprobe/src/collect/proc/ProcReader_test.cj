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

@Test
public class ProcReader_test {
    @TestCase
    public func fixtureReturnsConfiguredContent(): Unit {
        let reader = FixtureProcReader([
            ("/proc/stat", "cpu  1 2 3"),
            ("/proc/loadavg", "0.10 0.20 0.30 1/100 1")
        ])
        @Assert(reader.read("/proc/stat"), Some("cpu  1 2 3"))
        @Assert(reader.read("/proc/loadavg"), Some("0.10 0.20 0.30 1/100 1"))
    }

    @TestCase
    public func fixtureReturnsNoneForMissingPath(): Unit {
        let reader = FixtureProcReader([("/proc/stat", "cpu")])
        @Assert(reader.read("/proc/meminfo").isNone())
    }

    @TestCase
    public func realReaderReadsExistingFile(): Unit {
        let content = RealProcReader().read("/proc/sys/kernel/hostname")
        @Assert(content.isSome())
        @Assert(!content.getOrThrow().trimAscii().isEmpty())
    }

    @TestCase
    public func realReaderReturnsNoneForMissingFile(): Unit {
        let content = RealProcReader().read("/proc/definitely-not-exists-fprobe")
        @Assert(content.isNone())
    }

    @TestCase
    public func unsupportedReaderThrowsCollectError(): Unit {
        var caught = false
        try {
            UnsupportedProcReader().read("/proc/stat")
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("unsupported"))
        }
        @Assert(caught)
    }

    @TestCase
    public func factorySelectsRealReaderOnLinux(): Unit {
        let content = createProcReader().read("/proc/sys/kernel/hostname")
        @Assert(content.isSome())
    }
}
