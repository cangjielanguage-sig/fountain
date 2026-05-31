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
public class ConsumerMatcherCacheTest {
    @TestCase
    public func testCompiledPatternsClearedWhenFull(): Unit {
        let cm = ConsumerMatcher()
        // 注册超过 MAX_COMPILED_PATTERNS (1000) 的唯一 Glob 模式
        // 验证不抛异常即可
        for (i in 0..1050) {
            let reg = ConsumerRegistration(
                consumerId: "c${i}", groupId: "g${i}",
                matchModeStr: "Glob:/test/pattern_${i}/*",
                labels: None, dataFilter: None,
                lastHeartbeat: DateTime.now())
            cm.register(reg)
        }
        // 触发大量 glob 匹配 - 验证不抛异常
        let result = cm.matchTopic("/test/pattern_999/x")
        @Assert(result.size == 1)
    }
}
