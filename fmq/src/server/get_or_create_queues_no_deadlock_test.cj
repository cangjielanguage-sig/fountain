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
package fountain::fmq.server

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_data.base.*
import std.sync.{AtomicInt64, AtomicBool}
import std.fs.*
import std.fs.removeIfExists


@Test
public class GetOrCreateQueuesNoDeadlockTest {
    @TestCase
    public func testGetOrCreateQueuesWithReplicationManagerDoesNotDeadlock(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp", heartbeatIntervalSec: 1)
        let rm = ReplicationManager(config)
        let qm = QueueManager(config, nodeIndex: 0)
        qm.setReplicationManager(rm)
        // P2-2: 若 startWriterAndReader 在锁内重入 synchronized(lock)，此处会死锁
        let result = qm.getOrCreateQueues("/p2-2-nodl", 1)
        @Assert(result.size == 1)
        qm.close()
    }
}
