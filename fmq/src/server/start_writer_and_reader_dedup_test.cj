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
public class StartWriterAndReaderDedupTest {
    @TestCase
    public func testSecondStartWritersForTopicDoesNotCrash(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp/fmq_p2-2-dup", heartbeatIntervalSec: 1)
        let rm = ReplicationManager(config)
        let qm = QueueManager(config, nodeIndex: 0)
        qm.setReplicationManager(rm)
        // 创建队列
        let queues = qm.createQueues("/p2-2-dup", 1)
        @Assert(queues.size == 1)
        // 启动 writers
        qm.startWritersForTopic("/p2-2-dup")
        let writer = qm.getWriterForQueue(queues[0])
        @Assert(writer.isSome())
        // P2-2: 第二次 startWritersForTopic — 应跳过已存在的 writer（不崩溃）
        qm.startWritersForTopic("/p2-2-dup")
        qm.close()
    }
}
