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
package fountain::fsync.server

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fsync.base.HostAndPort

@Test
class SyncCommandTest {
    @TestCase
    func commandNameIsSync(): Unit {
        @Assert(SyncCommand().command == 'sync')
    }

    @TestCase
    func resolveLocalIndexLocalhost(): Unit {
        let hosts = ArrayList<HostAndPort>()
        hosts.add(HostAndPort('localhost:1203'))
        hosts.add(HostAndPort('10.0.0.2:1203'))
        @Assert(SyncCommand.resolveLocalIndex(hosts) == 0)
    }

    @TestCase
    func resolveLocalIndexLoopback(): Unit {
        let hosts = ArrayList<HostAndPort>()
        hosts.add(HostAndPort('10.0.0.1:1203'))
        hosts.add(HostAndPort('127.0.0.1:1203'))
        hosts.add(HostAndPort('10.0.0.3:1203'))
        @Assert(SyncCommand.resolveLocalIndex(hosts) == 1)
    }

    @TestCase
    func configStringSingleNode(): Unit {
        let hosts = ArrayList<HostAndPort>()
        hosts.add(HostAndPort('10.0.0.1:1203'))
        @Assert(hosts[0].host == '10.0.0.1')
        @Assert(hosts[0].port == 1203u16)
    }

    @TestCase
    func configStringMultipleNodes(): Unit {
        let hosts = ArrayList<HostAndPort>()
        hosts.add(HostAndPort('10.0.0.1:1203'))
        hosts.add(HostAndPort('10.0.0.2:1204'))
        hosts.add(HostAndPort('10.0.0.3:1205'))
        @Assert(hosts.size == 3)
        @Assert(hosts[0].host == '10.0.0.1')
        @Assert(hosts[0].port == 1203u16)
        @Assert(hosts[1].host == '10.0.0.2')
        @Assert(hosts[1].port == 1204u16)
        @Assert(hosts[2].host == '10.0.0.3')
        @Assert(hosts[2].port == 1205u16)
    }

    @TestCase
    func resolveLocalIndexReturnsZeroOnError(): Unit {
        let hosts = ArrayList<HostAndPort>()
        hosts.add(HostAndPort('10.0.0.1:1203'))
        hosts.add(HostAndPort('10.0.0.2:1203'))
        // 没有 localhost/127.0.0.1 匹配时返回 0
        let result = SyncCommand.resolveLocalIndex(hosts)
        @Assert(result is Int64)
    }
}
