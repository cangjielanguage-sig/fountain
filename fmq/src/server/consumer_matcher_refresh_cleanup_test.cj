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

/**
 * P3-1: refresh() 清理 roundRobinIndex 中已过期 group 的条目。
 */
@Test
public class ConsumerMatcherRefreshCleanupTest {
    @TestCase
    public func testRefreshRemovesStaleRoundRobinIndex(): Unit {
        // heartbeatIntervalSec=0 → timeout=0，注册后立即视为过期
        let matcher = ConsumerMatcher(heartbeatIntervalSec: 0)
        // 注册 3 个不同 group 的消费者，推进 RR 索引
        let r1 = ConsumerRegistration(consumerId: "c1", groupId: "g1",
            matchModeStr: "Exact:/test", labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let r2 = ConsumerRegistration(consumerId: "c2", groupId: "g2",
            matchModeStr: "Exact:/test", labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        let r3 = ConsumerRegistration(consumerId: "c3", groupId: "g3",
            matchModeStr: "Exact:/test", labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(r1)
        matcher.register(r2)
        matcher.register(r3)
        // matchTopic 推进 g1/g2/g3 的 roundRobinIndex
        matcher.matchTopic("/test")
        // 所有 consumer 已过期（timeout=0），refresh 应清理全部
        matcher.refresh()
        // refresh 后 matchTopic 应无匹配
        let result = matcher.matchTopic("/test")
        @Assert(result.size == 0)
    }

    @TestCase
    public func testRefreshKeepsActiveGroupRoundRobinIndex(): Unit {
        let matcher = ConsumerMatcher(heartbeatIntervalSec: 3600)  // 1h timeout
        let r1 = ConsumerRegistration(consumerId: "active", groupId: "keep",
            matchModeStr: "Exact:/keep", labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())
        matcher.register(r1)
        matcher.matchTopic("/keep")
        // 使用过期 consumer 确保有被清理的对象
        let r2 = ConsumerRegistration(consumerId: "expired", groupId: "drop",
            matchModeStr: "Exact:/drop", labels: None, dataFilter: None,
            lastHeartbeat: DateTime.fromUnixTimeStamp(Duration.second * 0))  // epoch=0
        matcher.register(r2)
        matcher.refresh()
        // "drop" group 的 consumer 应被清除，但 "keep" group 应保留
        let result = matcher.matchTopic("/keep")
        @Assert(result.size == 1)
        if (let Some(consumerId) <- result.get("keep")) {
            @Assert(consumerId == "active")
        }
    }
}
