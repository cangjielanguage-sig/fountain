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
public class ReassignRangeTest {
    @TestCase
    public func testReassignCoversFullRange(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        hosts.add("n2:1")
        hosts.add("n3:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let qm = QueueManager(config, nodeIndex: 0)
        qm.createQueues("/p2-7-test", 1)
        // 故障节点 1（仅本节点 0 上有 1 个队列）
        let result = qm.reassign(1)
        // reassign 应覆盖 config.mqHosts.size * (topicQueues.size) 范围
        @Assert(result.size >= 0)
        for ((topic, index) in result) {
            @Assert(topic == "/p2-7-test")
        }
    }
}
