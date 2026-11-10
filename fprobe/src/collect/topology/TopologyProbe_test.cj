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
package fountain::fprobe.collect.topology

import std.unittest.*
import std.unittest.testmacro.*
import fountain::fprobe.collect.hw.{CommandResult, FixtureCommandRunner, SnmpDevice}

private let IF_A = '''
.1.3.6.1.2.1.2.2.1.2.1 = STRING: eth0
.1.3.6.1.2.1.2.2.1.2.2 = STRING: eth1
'''

private let IF_B = '''
.1.3.6.1.2.1.2.2.1.2.1 = STRING: eth0
'''

private let LLDP_A = '''
.1.0.8802.1.1.2.1.4.1.1.7.0.1.1 = STRING: eth0
.1.0.8802.1.1.2.1.4.1.1.9.0.1.1 = STRING: swB
'''

private let LLDP_B = '''
.1.0.8802.1.1.2.1.4.1.1.7.0.1.1 = STRING: eth0
.1.0.8802.1.1.2.1.4.1.1.9.0.1.1 = STRING: swA
'''

@Test
public class TopologyProbe_test {
    private func runner(): FixtureCommandRunner {
        let runner = FixtureCommandRunner()
        runner.respond(["snmpbulkwalk", "-v2c", "-c", "public", "10.0.0.1", IF_MIB_WALK_OID],
            CommandResult(0, IF_A, "", false, ""))
        runner.respond(["snmpbulkwalk", "-v2c", "-c", "public", "10.0.0.1", LLDP_MIB_WALK_OID],
            CommandResult(0, LLDP_A, "", false, ""))
        runner.respond(["snmpbulkwalk", "-v2c", "-c", "public", "10.0.0.2", IF_MIB_WALK_OID],
            CommandResult(0, IF_B, "", false, ""))
        runner.respond(["snmpbulkwalk", "-v2c", "-c", "public", "10.0.0.2", LLDP_MIB_WALK_OID],
            CommandResult(0, LLDP_B, "", false, ""))
        runner
    }

    private func devices(): Array<SnmpDevice> {
        [SnmpDevice("swA", "10.0.0.1", "public"), SnmpDevice("swB", "10.0.0.2", "public")]
    }

    @TestCase
    public func buildsDevicesAndDeduplicatesUndirectedLink(): Unit {
        let data = TopologyProbe(runner(), devices()).data
        let deviceList = data.get("devices").getOrThrow().asArray()
        @Assert(deviceList.size, 2)
        @Assert(deviceList[0].asObject().get("name").getOrThrow().asString().value, "swA")
        let ports = deviceList[0].asObject().get("ports").getOrThrow().asArray()
        @Assert(ports.size, 2)
        @Assert(ports[0].asString().value, "eth0")

        let links = data.get("links").getOrThrow().asArray()
        @Assert(links.size, 1)
        let link = links[0].asObject()
        @Assert(link.get("from").getOrThrow().asString().value, "swA")
        @Assert(link.get("to").getOrThrow().asString().value, "swB")
        @Assert(link.get("localPort").getOrThrow().asString().value, "eth0")
        @Assert(link.get("remotePort").getOrThrow().asString().value, "eth0")
        @Assert(data.get("error").getOrThrow().asString().value.isEmpty())
    }

    @TestCase
    public func emptyConfigurationReturnsError(): Unit {
        let data = TopologyProbe(FixtureCommandRunner(), []).data
        @Assert(data.get("devices").getOrThrow().asArray().isEmpty())
        @Assert(data.get("links").getOrThrow().asArray().isEmpty())
        @Assert(data.get("error").getOrThrow().asString().value.contains("probe_snmpDevices"))
    }

    @TestCase
    public func toolFailureIsReportedWithoutThrowing(): Unit {
        let data = TopologyProbe(FixtureCommandRunner(),
            [SnmpDevice("swA", "10.0.0.1", "public")]).data
        @Assert(data.get("links").getOrThrow().asArray().isEmpty())
        @Assert(!data.get("error").getOrThrow().asString().value.isEmpty())
    }
}
