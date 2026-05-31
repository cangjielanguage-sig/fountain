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
public class CleanupOrphanOffsetsTest {
    @TestCase
    public func testCleanupOrphanOffsetsRemovesDeletedTopic(): Unit {
        let hosts = ArrayList<String>()
        hosts.add("n1:1")
        let config = MqConfig(mqHosts: hosts, dataDir: "/tmp")
        let dm = DeliveryManager(config, serverId: "s1")
        let tm = TopicManager(config)
        dm.setTopicManager(tm)

        // 创建 /active topic 并设置 offset
        tm.createTopic("/active", queueCount: 1)
        dm.setOffset("/active", 0, "g1", 100)

        // 为不存在的 /deleted topic 设置 offset（孤儿 offset）
        dm.setOffset("/deleted", 0, "g2", 200)

        // 调用 cleanupOrphanOffsets
        dm.cleanupOrphanOffsets()

        // /active 的 offset 应保留
        @Assert(dm.getOffset("/active", 0, "g1") == 100)

        // /deleted 的 offset 应被移除（getOffset 返回 0 表示 key 不存在）
        @Assert(dm.getOffset("/deleted", 0, "g2") == 0)
    }
}
