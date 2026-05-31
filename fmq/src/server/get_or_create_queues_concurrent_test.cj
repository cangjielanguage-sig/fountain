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
public class GetOrCreateQueuesConcurrentTest {
    @TestCase
    public func testConcurrentGetOrCreateSameTopicReturnsExisting(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let qm = QueueManager(config, nodeIndex: 0)
        // 线程安全：两线程同时 getOrCreateQueues 同一新 topic
        var f1 = spawn { qm.getOrCreateQueues("/p0-1-con", 1) }
        var f2 = spawn { qm.getOrCreateQueues("/p0-1-con", 1) }
        let r1 = f1.get()
        let r2 = f2.get()
        @Assert(r1.size == 1)
        @Assert(r2.size == 1)
        @Assert(r1[0].index == r2[0].index)
    }
}
