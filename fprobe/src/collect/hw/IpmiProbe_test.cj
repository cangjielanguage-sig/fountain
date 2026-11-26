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

private let IPMI_SDR = '''
CPU Temp         | 45 degrees C      | ok
FAN1             | 3000 RPM          | ok
PS1 Status       | 0x01              | ok
System Temp      | no reading        | ns
Intrusion        | 0x00              | ok
'''

@Test
public class IpmiProbe_test {
    private func runnerWith(result: CommandResult): FixtureCommandRunner {
        let runner = FixtureCommandRunner()
        runner.respond(["ipmitool", "sdr"], result)
        runner
    }

    @TestCase
    public func parsesTemperatureFanAndPowerSupply(): Unit {
        let runner = runnerWith(CommandResult(0, IPMI_SDR, "", false, ""))
        let readings = IpmiProbe(runner).collect()
        @Assert(readings.size, 3)

        @Assert(readings[0].sensorType, "Temperature")
        @Assert(readings[0].name, "CPU Temp")
        @Assert(readings[0].value, 45.0)
        @Assert(readings[0].unit, "C")
        @Assert(readings[0].status, "ok")
        @Assert(readings[0].available)

        @Assert(readings[1].sensorType, "Fan")
        @Assert(readings[1].value, 3000.0)
        @Assert(readings[1].unit, "RPM")

        @Assert(readings[2].sensorType, "Power Supply")
        @Assert(readings[2].name, "PS1 Status")
    }

    /** 命令模板必须是 `ipmitool sdr`，不能把带空格的 `Power Supply` 当作参数。 */
    @TestCase
    public func usesSdrCommandWithoutSpacedArgument(): Unit {
        let runner = FixtureCommandRunner()
        runner.respond(["ipmitool", "sdr"], CommandResult(0, IPMI_SDR, "", false, ""))
        @Assert(IpmiProbe(runner).collect().size, 3)
    }

    @TestCase
    public func nonZeroExitDegradesWithError(): Unit {
        let readings = IpmiProbe(runnerWith(CommandResult(1, "", "ipmi failed", false, ""))).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].error.contains("1"))
        @Assert(readings[0].error.contains("ipmi failed"))
    }

    @TestCase
    public func missingToolDegradesWithError(): Unit {
        let readings = IpmiProbe(runnerWith(CommandResult(-1, "", "", false, "无法执行命令 ipmitool: ENOENT"))).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].error.contains("ipmitool"))
        @Assert(readings[0].error.contains("ENOENT"))
    }

    @TestCase
    public func timeoutDegradesWithError(): Unit {
        let readings = IpmiProbe(runnerWith(CommandResult(-1, "", "", true, "命令执行超时（3000ms）"))).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].error.contains("超时"))
    }

    @TestCase
    public func disabledProbeReturnsNoReadings(): Unit {
        let runner = runnerWith(CommandResult(0, IPMI_SDR, "", false, ""))
        @Assert(IpmiProbe(runner, enabled: false).collect().isEmpty())
    }
}
