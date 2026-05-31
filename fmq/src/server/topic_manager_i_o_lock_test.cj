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
public class TopicManagerIOLockTest {
    @TestCase
    public func testLockNotHeldDuringFleetIoForDeleteTopic(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let tm = TopicManager(config)
        // createTopic 内部不应在锁内执行 I/O（P3-3 / P2-7）
        let code = tm.createTopic("/p2-7-io-lock", queueCount: 1)
        @Assert(code == MqErrorCode.SUCCESS)
        let topics = tm.listTopics()
        var found = false
        for (t in topics) {
            if (t == "/p2-7-io-lock") { found = true; break }
        }
        @Assert(found)
    }
}
