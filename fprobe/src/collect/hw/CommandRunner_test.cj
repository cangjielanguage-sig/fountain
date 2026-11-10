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
package fountain::fprobe.collect.hw

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_probe.{ProbeErrorCode, ProbeException}

@Test
public class CommandRunner_test {
    @TestCase
    public func successfulCommandCarriesStdout(): Unit {
        let result = FProcessRunner().run(["/bin/echo", "hello"], timeoutMs: 2000)
        @Assert(result.exitCode == 0)
        @Assert(!result.timedOut)
        @Assert(result.stdout.trimAscii() == "hello")
        @Assert(result.stderr.isEmpty())
        @Assert(result.error.isEmpty())
        @Assert(result.succeeded())
    }

    @TestCase
    public func nonZeroExitCodeIsReported(): Unit {
        let result = FProcessRunner().run(["/bin/false"], timeoutMs: 2000)
        @Assert(result.exitCode != 0)
        @Assert(!result.timedOut)
        @Assert(!result.succeeded())
    }

    @TestCase
    public func timeoutIsReportedWithoutHanging(): Unit {
        let result = FProcessRunner().run(["/bin/sleep", "2"], timeoutMs: 100)
        @Assert(result.timedOut)
        @Assert(!result.succeeded())
    }

    @TestCase
    public func missingToolIsReportedAsError(): Unit {
        let result = FProcessRunner().run(["/definitely/not/a/command"], timeoutMs: 2000)
        @Assert(!result.error.isEmpty())
        @Assert(!result.succeeded())
    }

    @TestCase
    public func whitespaceArgumentIsRejected(): Unit {
        var caught = false
        try {
            FProcessRunner().run(["/bin/echo", "a b"], timeoutMs: 1000)
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("a b"))
        }
        @Assert(caught)
    }

    @TestCase
    public func emptyCommandIsRejected(): Unit {
        var caught = false
        try {
            FProcessRunner().run([], timeoutMs: 1000)
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
        }
        @Assert(caught)
    }
}
