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
package fountain::f_mq.base

import std.unittest.*
import std.unittest.testmacro.*

@Test
class MQHostTest {
    @TestCase
    public func acceptsValidEntry(): Unit {
        let parsed = MQHost.parseHost("127.0.0.1:2350").getOrThrow()
        @Assert(parsed[0] == "127.0.0.1")
        @Assert(parsed[1] == 2350)
        // 前后空格被去掉
        let trimmed = MQHost.parseHost("  localhost:8080  ").getOrThrow()
        @Assert(trimmed[0] == "localhost")
        @Assert(trimmed[1] == 8080)
    }

    @TestCase
    public func rejectsInvalidEntry(): Unit {
        @Assert(MQHost.parseHost("").isNone())
        @Assert(MQHost.parseHost("localhost").isNone())
        @Assert(MQHost.parseHost(":2350").isNone())
        @Assert(MQHost.parseHost("localhost:").isNone())
        @Assert(MQHost.parseHost("localhost:0").isNone())
        @Assert(MQHost.parseHost("localhost:70000").isNone())
        @Assert(MQHost.parseHost("a:b:c").isNone())
    }
}
