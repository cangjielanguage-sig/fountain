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
import std.collection.HashSet

@Test
class MQErrorCodeTest {
    @TestCase
    public func constantsAreStable(): Unit {
        @Assert(MQErrorCode.OK == 0)
        @Assert(MQErrorCode.TOPIC_NOT_EXIST == 1)
        @Assert(MQErrorCode.TOPIC_ALREADY_EXIST == 2)
        @Assert(MQErrorCode.GROUP_NOT_EXIST == 3)
        @Assert(MQErrorCode.GROUP_ALREADY_EXIST == 4)
        @Assert(MQErrorCode.INVALID_TOPIC == 5)
        @Assert(MQErrorCode.INVALID_GROUP == 6)
        @Assert(MQErrorCode.SUBSCRIBE_NOT_EXIST == 7)
        @Assert(MQErrorCode.NOT_OWNER == 8)
        @Assert(MQErrorCode.ACK_UNKNOWN == 9)
        @Assert(MQErrorCode.FILTER_UNSUPPORTED_BODY == 10)
        @Assert(MQErrorCode.INTERNAL == 11)
    }

    @TestCase
    public func messagesAreNonEmptyAndUnique(): Unit {
        let seen = HashSet<String>()
        for (code in 0..12) {
            let message = MQErrorCode.messageOf(code)
            @Assert(!message.isEmpty())
            @Assert(!seen.contains(message))
            seen.add(message)
        }
        // 未知码也给出可读文案
        @Assert(!MQErrorCode.messageOf(99).isEmpty())
    }

    @TestCase
    public func configKeyAndInternalKinds(): Unit {
        @Assert(MQConfigKey.CLIENT_HOSTS == "mqClient_hosts")
        @Assert(MQInternalKind.META_SYNC == "metaSync")
        @Assert(MQInternalKind.BACKUP == "backup")
        @Assert(MQInternalKind.STATS == "stats")
    }
}
