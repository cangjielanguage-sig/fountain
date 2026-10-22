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
package fountain::fmq

import std.unittest.*
import std.unittest.testmacro.*

@Test
class MQUsageTest {
    @TestCase
    public func rootMentionsBothSubcommands(): Unit {
        let text = MQUsage.root()
        @Assert(text.contains("server"))
        @Assert(text.contains("manager"))
    }

    @TestCase
    public func serverHelpListsEveryConfigItem(): Unit {
        let text = MQUsage.serverHelp()
        @Assert(text.contains("mqServer_port"))
        @Assert(text.contains("mqServer_ackTimeout"))
        @Assert(text.contains("mqServer_deadMsgThreshold"))
        @Assert(text.contains("mqServer_deadMsgTTL"))
        @Assert(text.contains("mqServer_segmentedLogDir"))
        @Assert(text.contains("mqServer_deadMsgDir"))
        @Assert(text.contains("mqServer_segmentedLogMaxSize"))
        @Assert(text.contains("mqServer_segmentedLogTTL"))
        @Assert(text.contains("mqServer_backup"))
        @Assert(text.contains("mqClient_hosts"))
        @Assert(text.contains("metas/"))
    }

    @TestCase
    public func managerHelpListsAllSubcommands(): Unit {
        let text = MQUsage.managerHelp()
        for (command in ["registerTopic", "deleteTopic", "registerSubscriber", "deleteSubscribeGroup",
            "listTopics", "listSubscribeGroups", "stats", "delaying="]) {
            @Assert(text.contains(command))
        }
        @Assert(text.contains("--server"))

        // 恰好 7 个子命令行：漏掉 stats 或重复列出都会失败（R4-G9）
        let commands = ["registerTopic", "deleteTopic", "registerSubscriber", "deleteSubscribeGroup",
            "listTopics", "listSubscribeGroups", "stats"]
        var counted = 0
        for (line in text.split("\n")) {
            let trimmed = line.trimAscii()
            for (command in commands) {
                if (trimmed.startsWith(command)) {
                    counted++
                }
            }
        }
        @Assert(counted == 7)
    }
}
