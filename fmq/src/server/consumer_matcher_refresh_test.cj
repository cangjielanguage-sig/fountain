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
public class ConsumerMatcherRefreshTest {
    @TestCase
    public func testRefreshRemovesStaleRegistrations(): Unit {
        let cm = ConsumerMatcher(heartbeatIntervalSec: 1)  // 超时 = 3s
        let reg = ConsumerRegistration(
            consumerId: "stale-consumer", groupId: "stale-group",
            matchModeStr: "Exact:/test",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now() - Duration.second * 10)  // 10s 前 → 过期
        cm.register(reg)
        @Assert(cm.matchTopic("/test").size == 1)
        cm.refresh()
        @Assert(cm.matchTopic("/test").size == 0)
    }

    @TestCase
    public func testRefreshKeepsActiveRegistrations(): Unit {
        let cm = ConsumerMatcher(heartbeatIntervalSec: 5)  // 超时 = 15s
        let reg = ConsumerRegistration(
            consumerId: "active-consumer", groupId: "active-group",
            matchModeStr: "Exact:/test",
            labels: None, dataFilter: None,
            lastHeartbeat: DateTime.now())  // 刚心跳
        cm.register(reg)
        cm.refresh()
        @Assert(cm.matchTopic("/test").size == 1)
    }
}
