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

private let SMART_JSON = '''
{"device":{"name":"/dev/sda","info_name":"/dev/sda"},
 "model_name":"Samsung SSD 870",
 "smart_status":{"passed":true},
 "temperature":{"current":35}}
'''

private let SMART_TEXT = '''
smartctl 7.0 2020-12-30 r5155 [x86_64-linux] (local build)
Device Model:     ST1000DM003-1CH162
SMART overall-health self-assessment test result: PASSED
Current Drive Temperature: 37 C
'''

@Test
public class SmartProbe_test {
    private func runnerWith(result: CommandResult): FixtureCommandRunner {
        let runner = FixtureCommandRunner()
        runner.respond(["smartctl", "-A", "-j", "/dev/sda"], result)
        runner
    }

    @TestCase
    public func parsesJsonOutput(): Unit {
        let readings = SmartProbe(runnerWith(CommandResult(0, SMART_JSON, "", false, "")), ["/dev/sda"]).collect()
        @Assert(readings.size, 1)
        @Assert(readings[0].device, "/dev/sda")
        @Assert(readings[0].model, "Samsung SSD 870")
        @Assert(readings[0].health, "PASSED")
        @Assert(readings[0].temperatureCelsius, 35.0)
        @Assert(readings[0].available)
        @Assert(readings[0].error.isEmpty())
    }

    @TestCase
    public func fallsBackToTextWhenJsonIsUnavailable(): Unit {
        let readings = SmartProbe(runnerWith(CommandResult(0, SMART_TEXT, "", false, "")), ["/dev/sda"]).collect()
        @Assert(readings.size, 1)
        @Assert(readings[0].model, "ST1000DM003-1CH162")
        @Assert(readings[0].health, "PASSED")
        @Assert(readings[0].temperatureCelsius, 37.0)
        @Assert(readings[0].available)
        @Assert(readings[0].error.contains("降级"))
    }

    @TestCase
    public func nonZeroExitWithoutOutputDegradesWithError(): Unit {
        let readings = SmartProbe(runnerWith(CommandResult(4, "", "device open failed", false, "")), ["/dev/sda"]).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].error.contains("4"))
        @Assert(readings[0].error.contains("device open failed"))
    }

    @TestCase
    public func missingToolDegradesWithError(): Unit {
        let readings = SmartProbe(runnerWith(CommandResult(-1, "", "", false, "无法执行命令 smartctl: ENOENT")),
            ["/dev/sda"]).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].error.contains("smartctl"))
    }

    @TestCase
    public func timeoutDegradesWithError(): Unit {
        let readings = SmartProbe(runnerWith(CommandResult(-1, "", "", true, "命令执行超时（3000ms）")), ["/dev/sda"]).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].error.contains("超时"))
    }

    /** 设备路径必须限制在 `/dev` 下且不含 shell 元字符。 */
    @TestCase
    public func dangerousDevicePathIsRejected(): Unit {
        let readings = SmartProbe(FixtureCommandRunner(), ["/dev/sda; rm -rf /"]).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].device, "/dev/sda; rm -rf /")
        @Assert(readings[0].error.contains("非法"))
    }

    @TestCase
    public func emptyDevicesProduceNoReadings(): Unit {
        @Assert(SmartProbe(FixtureCommandRunner(), []).collect().isEmpty())
    }
}
