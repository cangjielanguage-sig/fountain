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

private let SNMP_WALK = '''
.1.3.6.1.4.1.2021.13.16.2.1.2.1 = STRING: CPU Temp
.1.3.6.1.4.1.2021.13.16.2.1.3.1 = INTEGER: 45
.1.3.6.1.4.1.2021.13.16.2.1.3.2 = INTEGER: 2200
'''

@Test
public class SnmpProbe_test {
    private func device(): SnmpDevice {
        SnmpDevice("sw1", "10.0.0.1", "public")
    }

    private func runnerWith(result: CommandResult): FixtureCommandRunner {
        let runner = FixtureCommandRunner()
        runner.respond(["snmpbulkwalk", "-v2c", "-c", "public", "10.0.0.1", SNMP_SENSOR_OID], result)
        runner
    }

    @TestCase
    public func parsesWalkOutput(): Unit {
        let runner = runnerWith(CommandResult(0, SNMP_WALK, "", false, ""))
        let readings = SnmpProbe(runner, [device()]).collect()
        @Assert(readings.size, 3)
        @Assert(readings[0].device, "sw1")
        @Assert(readings[0].value, "CPU Temp")
        @Assert(readings[0].oid.endsWith(".2021.13.16.2.1.2.1"))
        @Assert(readings[1].value, "45")
        @Assert(readings[2].value, "2200")
        @Assert(readings[0].available)
    }

    @TestCase
    public func nonZeroExitDegradesWithError(): Unit {
        let readings = SnmpProbe(runnerWith(CommandResult(2, "", "timeout: no response", false, "")), [device()]).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].error.contains("2"))
        @Assert(readings[0].error.contains("no response"))
    }

    @TestCase
    public func missingToolDegradesWithError(): Unit {
        let readings = SnmpProbe(runnerWith(CommandResult(-1, "", "", false, "无法执行命令 snmpbulkwalk: ENOENT")),
            [device()]).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].error.contains("snmpbulkwalk"))
    }

    @TestCase
    public func timeoutDegradesWithError(): Unit {
        let readings = SnmpProbe(runnerWith(CommandResult(-1, "", "", true, "命令执行超时（3000ms）")), [device()]).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].error.contains("超时"))
    }

    @TestCase
    public func oneDeviceFailureDoesNotHideAnother(): Unit {
        let runner = FixtureCommandRunner()
        runner.respond(["snmpbulkwalk", "-v2c", "-c", "public", "10.0.0.1", SNMP_SENSOR_OID],
            CommandResult(0, SNMP_WALK, "", false, ""))
        runner.respond(["snmpbulkwalk", "-v2c", "-c", "private", "10.0.0.2", SNMP_SENSOR_OID],
            CommandResult(1, "", "auth failed", false, ""))
        let readings = SnmpProbe(runner, [device(), SnmpDevice("sw2", "10.0.0.2", "private")]).collect()
        @Assert(readings.size, 4)
        @Assert(readings[0].available)
        @Assert(!readings[3].available)
        @Assert(readings[3].device, "sw2")
    }

    /** community 含空白会破坏参数数组边界，必须在拼命令前拒绝。 */
    @TestCase
    public func communityWithWhitespaceIsRejected(): Unit {
        let readings = SnmpProbe(FixtureCommandRunner(), [SnmpDevice("sw1", "10.0.0.1", "pub lic")]).collect()
        @Assert(readings.size, 1)
        @Assert(!readings[0].available)
        @Assert(readings[0].error.contains("community"))
    }

    @TestCase
    public func emptyDevicesProduceNoReadings(): Unit {
        @Assert(SnmpProbe(FixtureCommandRunner(), []).collect().isEmpty())
    }
}
