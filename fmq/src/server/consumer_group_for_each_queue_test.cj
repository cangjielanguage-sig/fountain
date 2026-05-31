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
public class ConsumerGroupForEachQueueTest {
    @TestCase
    public func testForEachQueueReturnsQueueCount(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let tm = TopicManager(config)
        let cm = ConsumerMatcher()
        let dm = DeliveryManager(config)
        let cgm = ConsumerGroupManager(tm, cm, dm)

        tm.createTopic("/p2-5-qc", queueCount: 3)
        // createGroup 应正确处理 3 队列
        let code = cgm.createGroup("/p2-5-qc", "g1")
        @Assert(code == MqErrorCode.SUCCESS)
        // 每个队列 offset 都应初始化为 0
        @Assert(cgm.getOffset("/p2-5-qc", 0, "g1") == 0)
        @Assert(cgm.getOffset("/p2-5-qc", 1, "g1") == 0)
        @Assert(cgm.getOffset("/p2-5-qc", 2, "g1") == 0)
    }
}
