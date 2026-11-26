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
import fountain::f_data.*

/**
 * `hardware` 监控项：把 IPMI / SNMP / SMART 三组读数合成一个 JSON 对象。
 *
 * 用例只依赖 `FixtureCommandRunner`，不调用真实 ipmitool/snmpbulkwalk/smartctl。
 */
@Test
public class HardwareProbe_test {
    @TestCase
    public func kindIsHardware(): Unit {
        let probe = HardwareProbe(IpmiProbe(FixtureCommandRunner(), enabled: false), SnmpProbe(
            FixtureCommandRunner(), []), SmartProbe(FixtureCommandRunner(), []))
        @Assert(probe.kind, "hardware")
    }

    /** 三组读数都在，且各自带上设备标识。 */
    @TestCase
    public func aggregatesAllThreeSources(): Unit {
        let runner = FixtureCommandRunner()
        runner.respond(["ipmitool", "sdr"],
            CommandResult(0, "CPU Temp | 45 degrees C | ok\nPS1 Status | 0x01 | ok\n", "", false, ""))
        runner.respond(["snmpbulkwalk", "-v2c", "-c", "public", "10.0.0.2", SNMP_SENSOR_OID],
            CommandResult(0, '${SNMP_SENSOR_OID}.1 = STRING: "fan1"\n${SNMP_SENSOR_OID}.2 = INTEGER: 3200\n',
                "", false, ""))
        runner.respond(["smartctl", "-A", "-j", "/dev/sda"],
            CommandResult(0, '{"model_name":"Disk A","smart_status":{"passed":true},"temperature":{"current":38}}',
                "", false, ""))

        let probe = HardwareProbe(IpmiProbe(runner, enabled: true), SnmpProbe(runner,
            [SnmpDevice("sw1", "10.0.0.2", "public")]), SmartProbe(runner, ["/dev/sda"]))
        let data = probe.data

        let ipmi = match (data.get("ipmi")) {
            case Some(value) => value.asArray()
            case None => throw Exception("ipmi missing")
        }
        @Assert(ipmi.size > 0)

        let snmp = match (data.get("snmp")) {
            case Some(value) => value.asArray()
            case None => throw Exception("snmp missing")
        }
        @Assert(snmp.size > 0)

        let smart = match (data.get("smart")) {
            case Some(value) => value.asArray()
            case None => throw Exception("smart missing")
        }
        @Assert(smart.size, 1)
    }

    /** 未启用 IPMI 时不执行命令，数组为空而不是报错。 */
    @TestCase
    public func disabledSourcesProduceEmptyArrays(): Unit {
        let probe = HardwareProbe(IpmiProbe(FixtureCommandRunner(), enabled: false), SnmpProbe(
            FixtureCommandRunner(), []), SmartProbe(FixtureCommandRunner(), []))
        let data = probe.data
        let ipmi = data.get("ipmi").getOrThrow {Exception("ipmi missing")}.asArray()
        let snmp = data.get("snmp").getOrThrow {Exception("snmp missing")}.asArray()
        let smart = data.get("smart").getOrThrow {Exception("smart missing")}.asArray()
        @Assert(ipmi.size, 0)
        @Assert(snmp.size, 0)
        @Assert(smart.size, 0)
    }

    /** 工具不可用降级：读数保留但标记 available=false，不抛出。 */
    @TestCase
    public func missingToolIsMarkedUnavailable(): Unit {
        let probe = HardwareProbe(IpmiProbe(FixtureCommandRunner(), enabled: true), SnmpProbe(
            FixtureCommandRunner(), []), SmartProbe(FixtureCommandRunner(), ["/dev/sda"]))
        let data = probe.data
        let ipmi = data.get("ipmi").getOrThrow {Exception("ipmi missing")}.asArray()
        @Assert(ipmi.size, 1)
        let first = ipmi[0].asObject()
        @Assert(first.get("available").getOrThrow {Exception("available missing")}.asBool().value, false)
    }
}
