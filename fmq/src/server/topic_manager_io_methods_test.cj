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
public class TopicManagerIoMethodsTest {
    @TestCase
    public func testDeleteTopicWorksWithoutFleet(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let tm = TopicManager(config)
        tm.createTopic("/p2-7-del", queueCount: 1)
        // deleteTopic 不应在锁内执行 I/O（P2-7），无 fleet 时正常工作
        let code = tm.deleteTopic("/p2-7-del")
        @Assert(code == MqErrorCode.SUCCESS)
        @Assert(tm.getTopicMeta("/p2-7-del").isNone())
    }

    @TestCase
    public func testAddRemoveGroupWorksWithoutFleet(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let tm = TopicManager(config)
        tm.createTopic("/p2-7-grp", queueCount: 1)
        // addConsumerGroup 不应在锁内执行 I/O（P2-7）
        let code1 = tm.addConsumerGroup("/p2-7-grp", "g1")
        @Assert(code1 == MqErrorCode.SUCCESS)
        // removeConsumerGroup 同理
        let code2 = tm.removeConsumerGroup("/p2-7-grp", "g1")
        @Assert(code2 == MqErrorCode.SUCCESS)
        // group 应已被移除
        let groups = tm.getConsumerGroups("/p2-7-grp")
        var found = false
        for (g in groups) {
            if (g == "g1") { found = true; break }
        }
        @Assert(!found)
    }
}
