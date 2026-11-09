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

private let NET_DEV_1 = '''
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 1000 100 0 0 0 0 0 0 2000 200 0 0 0 0 0 0
    lo: 5 1 0 0 0 0 0 0 5 1 0 0 0 0 0 0
'''

private let NET_DEV_2 = '''
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 6000 200 1 2 0 0 0 0 12000 400 0 0 0 0 0 0
    lo: 15 3 0 0 0 0 0 0 15 3 0 0 0 0 0 0
'''

private let SNMP_1 = '''
Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 0 0 0 0 0 1000 2000 20 0 0 0
'''

private let SNMP_2 = '''
Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
Tcp: 1 200 120000 -1 0 0 0 0 0 2000 3000 30 0 0 0
'''

@Test
public class NetworkProbe_test {
    private func reader(): FixtureProcReader {
        FixtureProcReader([
            ("/proc/net/dev", NET_DEV_1),
            ("/proc/net/snmp", SNMP_1),
            ("/sys/class/net/eth0/speed", "100\n")
        ])
    }

    @TestCase
    public func firstFrameOnlyEstablishesBaseline(): Unit {
        let now = [1000]
        let probe = NetworkProbe(reader(), [], {=> now[0]})
        let sample = probe.data
        let interfaces = sample.get("interfaces").getOrThrow().asArray()
        @Assert(interfaces.size, 2)
        let eth0 = interfaces[0].asObject()
        @Assert(eth0.get("name").getOrThrow().asString().value, "eth0")
        @Assert(eth0.get("rxBytes").getOrThrow().asInt().toInt64(), 1000)
        @Assert(eth0.get("rxBytesPerSec").getOrThrow().asDecimal().toFloat64(), 0.0)
    }

    @TestCase
    public func secondFrameComputesRatesAndPercentages(): Unit {
        let now = [1000]
        let reader = reader()
        let probe = NetworkProbe(reader, [], {=> now[0]})
        probe.data

        reader.set("/proc/net/dev", NET_DEV_2)
        reader.set("/proc/net/snmp", SNMP_2)
        now[0] = 2000
        let sample = probe.data
        let interfaces = sample.get("interfaces").getOrThrow().asArray()
        let eth0 = interfaces[0].asObject()

        @Assert(abs(eth0.get("rxBytesPerSec").getOrThrow().asDecimal().toFloat64() - 5000.0) < 1e-9)
        @Assert(abs(eth0.get("txBytesPerSec").getOrThrow().asDecimal().toFloat64() - 10000.0) < 1e-9)
        @Assert(abs(eth0.get("bandwidthPercent").getOrThrow().asDecimal().toFloat64() - 0.08) < 1e-6)
        @Assert(abs(eth0.get("dropPercent").getOrThrow().asDecimal().toFloat64() - 2.0 / 3.0) < 1e-9)
        @Assert(abs(eth0.get("errorPercent").getOrThrow().asDecimal().toFloat64() - 1.0 / 3.0) < 1e-9)
        @Assert(abs(eth0.get("tcpRetransPercent").getOrThrow().asDecimal().toFloat64() - 1.0) < 1e-9)
    }

    @TestCase
    public func whitelistFiltersInterfaces(): Unit {
        let now = [1000]
        let probe = NetworkProbe(reader(), ["eth0"], {=> now[0]})
        let interfaces = probe.data.get("interfaces").getOrThrow().asArray()
        @Assert(interfaces.size, 1)
        @Assert(interfaces[0].asObject().get("name").getOrThrow().asString().value, "eth0")
    }

    @TestCase
    public func missingSpeedKeepsBandwidthZero(): Unit {
        let now = [1000]
        let reader = FixtureProcReader([
            ("/proc/net/dev", NET_DEV_1),
            ("/proc/net/snmp", SNMP_1)
        ])
        let probe = NetworkProbe(reader, [], {=> now[0]})
        let interfaces = probe.data.get("interfaces").getOrThrow().asArray()
        @Assert(interfaces[0].asObject().get("bandwidthPercent").getOrThrow().asDecimal().toFloat64(), 0.0)
    }

    @TestCase
    public func malformedDevLineFailsProbe(): Unit {
        let now = [1000]
        let reader = FixtureProcReader([
            ("/proc/net/dev", '''
  eth0: 1 2
'''),
            ("/proc/net/snmp", SNMP_1)
        ])
        var caught = false
        try {
            NetworkProbe(reader, [], {=> now[0]}).data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("/proc/net/dev"))
        }
        @Assert(caught)
    }
}
