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
public class SlaveOfSyncQueueTest {
    @TestCase
    public func testStartAllSyncThreadsAfterSlaveRegistration(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:7201")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp/fmq_p2-3_sync", heartbeatIntervalSec: 1)
        let rm = ReplicationManager(config)
        let qm = QueueManager(config, nodeIndex: 0)
        qm.setReplicationManager(rm)
        // 先创建队列和 writer
        let queues = qm.createQueues("/p2-3-topic", 1)
        qm.startWritersForTopic("/p2-3-topic")
        // 模拟 SLAVEOF：注册 slave 后调用 startAllSyncThreads
        // 此时没有实际的奴隶节点（hosts 只含本节点），应不崩溃
        qm.startAllSyncThreads()
        @Assert(queues.size == 1)
        qm.close()
    }
}
