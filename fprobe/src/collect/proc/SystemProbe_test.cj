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

private let TCP = '''
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F91 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  1000        0 12346 1 0000000000000000 20 4 30 10 -1
'''

private let TCP6 = '''
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 22345 1 0000000000000000 100 0 0 10 0
'''

@Test
public class SystemProbe_test {
    @TestCase
    public func readsUptimeProcessCountAndTcpConnections(): Unit {
        let reader = FixtureProcReader([
            ("/proc/uptime", "12345.67 98765.43\n"),
            ("/proc/net/tcp", TCP),
            ("/proc/net/tcp6", TCP6)
        ], [("/proc", ["1", "42", "self", "thread-self", "sys", "cpuinfo", "meminfo"])])
        let probe = SystemProbe(reader)
        let data = probe.data
        @Assert(probe.kind, "system")
        @Assert(abs(data.get("uptimeSeconds").getOrThrow().asDecimal().toFloat64() - 12345.67) < 1e-6)
        @Assert(data.get("processCount").getOrThrow().asInt().toInt64(), 2)
        @Assert(data.get("tcpConnections").getOrThrow().asInt().toInt64(), 3)
    }

    @TestCase
    public func missingTcp6StillCountsTcp4(): Unit {
        let reader = FixtureProcReader([
            ("/proc/uptime", "10.0 20.0\n"),
            ("/proc/net/tcp", TCP)
        ], [("/proc", ["1"])])
        let data = SystemProbe(reader).data
        @Assert(data.get("processCount").getOrThrow().asInt().toInt64(), 1)
        @Assert(data.get("tcpConnections").getOrThrow().asInt().toInt64(), 2)
    }

    @TestCase
    public func missingUptimeThrowsCollectError(): Unit {
        let reader = FixtureProcReader([
            ("/proc/net/tcp", TCP)
        ], [("/proc", ["1"])])
        var caught = false
        try {
            SystemProbe(reader).data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("/proc/uptime"))
        }
        @Assert(caught)
    }

    @TestCase
    public func missingProcessDirectoryThrowsCollectError(): Unit {
        let reader = FixtureProcReader([
            ("/proc/uptime", "10.0 20.0\n"),
            ("/proc/net/tcp", TCP)
        ])
        var caught = false
        try {
            SystemProbe(reader).data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("/proc"))
        }
        @Assert(caught)
    }

    @TestCase
    public func missingTcpTablesThrowsCollectError(): Unit {
        let reader = FixtureProcReader([
            ("/proc/uptime", "10.0 20.0\n")
        ], [("/proc", ["1"])])
        var caught = false
        try {
            SystemProbe(reader).data
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.COLLECT)
            @Assert(e.message.contains("tcp"))
        }
        @Assert(caught)
    }
}
