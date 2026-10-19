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
package fountain::fmq.meta

import std.unittest.*
import std.unittest.testmacro.*

@Test
class MQFileNamesTest {
    @TestCase
    public func escapesReservedCharacters(): Unit {
        @Assert(MQFileNames.escape("/order") == "%2Forder")
        @Assert(MQFileNames.escape("") == "%00")
        @Assert(MQFileNames.escape("a.b-c_1") == "a.b-c_1")
        @Assert(MQFileNames.escape("/a b") == "%2Fa%20b")
    }

    @TestCase
    public func encodingIsReversible(): Unit {
        for (name in ["/order", "/a_b", "/a/b", "", "订单/创建", "/a b", "%2F"]) {
            @Assert(MQFileNames.unescape(MQFileNames.escape(name)) == name)
        }
    }

    @TestCase
    public func encodingHasNoCollision(): Unit {
        @Assert(MQFileNames.escape("/a_b") != MQFileNames.escape("/a/b"))
    }

    @TestCase
    public func pathLayoutMatchesSpec(): Unit {
        @Assert(MQFileNames.topicFile("/order") == "topics/%2Forder.meta")
        @Assert(MQFileNames.groupFile("/order", "") == "groups/%2Forder/%00.meta")
        @Assert(MQFileNames.groupFile("/order", "grp1") == "groups/%2Forder/grp1.meta")
        @Assert(MQFileNames.cursorFile("/order", 3, "") == "offsets/%2Forder/3/%00.cursor")
        @Assert(MQFileNames.queueDir("/logs", "/t", 0) == "/logs/%2Ft/0")
    }
}
