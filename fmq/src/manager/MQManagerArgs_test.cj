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
package fountain::fmq.manager

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config

@Test
class MQManagerArgsTest {
    @TestCase
    public func serverCanAppearBeforeOrAfterCommand(): Unit {
        let before = MQManagerArgs.parse(["--server=h:1", "registerTopic", "/t", "2"]).getOrThrow()
        let after = MQManagerArgs.parse(["registerTopic", "/t", "2", "--server=h:1"]).getOrThrow()
        @Assert(before.server == "h:1")
        @Assert(after.server == "h:1")
        @Assert(before.command == "registerTopic")
        @Assert(after.command == "registerTopic")
        @Assert(before.operands == ["/t", "2"])
        @Assert(after.operands == ["/t", "2"])
    }

    @TestCase
    public func defaultServerUsesConfiguredPort(): Unit {
        // 配置是全局状态：用例结束后必须回到「键不存在」，否则会影响其它用例（A24）
        let previous = Config.getString("mqServer_port")
        try {
            Config.set([("mqServer_port", "2350")])
            let args = MQManagerArgs.parse(["listTopics"]).getOrThrow()
            @Assert(args.server == "127.0.0.1:2350")
        } finally {
            match (previous) {
                case Some(text) => Config.set([("mqServer_port", text)])
                case None => Config.remove("mqServer_port")
            }
        }
    }

    @TestCase
    public func operandCountIsValidated(): Unit {
        @Assert(MQManagerArgs.parse(["registerTopic", "/t"]).isNone())
        @Assert(MQManagerArgs.parse(["listTopics", "extra"]).isNone())
        @Assert(MQManagerArgs.parse(["deleteTopic"]).isNone())
        @Assert(MQManagerArgs.parse(["registerSubscriber", "/t"]).isNone())
        @Assert(MQManagerArgs.parse(["listSubscribeGroups"]).isNone())
        @Assert(MQManagerArgs.parse(["registerTopic", "/t", "2", "delaying=1s", "extra"]).isNone())
        @Assert(MQManagerArgs.parse(["stats", "/t", "extra"]).isNone())
        @Assert(MQManagerArgs.parse(["bogus"]).isNone())
        @Assert(MQManagerArgs.parse(["--help"]).isNone())
    }

    /** 帮助文本与子命令表一致：恰好 7 个子命令（R4-G9）。 */
    @TestCase
    public func helpListsSevenSubcommands(): Unit {
        let text = MQManagerArgs.helpText()
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

    @TestCase
    public func sixSubcommandsParse(): Unit {
        @Assert(MQManagerArgs.parse(["registerTopic", "/t", "2"]).isSome())
        @Assert(MQManagerArgs.parse(["deleteTopic", "/t"]).isSome())
        @Assert(MQManagerArgs.parse(["registerSubscriber", "/t", "g"]).isSome())
        @Assert(MQManagerArgs.parse(["deleteSubscribeGroup", "/t", "g"]).isSome())
        @Assert(MQManagerArgs.parse(["listTopics"]).isSome())
        @Assert(MQManagerArgs.parse(["listSubscribeGroups", "/t"]).isSome())
        @Assert(MQManagerArgs.parse(["stats"]).isSome())
        @Assert(MQManagerArgs.parse(["stats", "/t"]).isSome())
        @Assert(MQManagerArgs.parse(["registerTopic", "/t", "2", "delaying=1m1s"]).isSome())
    }

    @TestCase
    public func helpTextListsCommandsAndServer(): Unit {
        let text = MQManagerArgs.helpText()
        for (command in ["registerTopic", "deleteTopic", "registerSubscriber", "deleteSubscribeGroup",
            "listTopics", "listSubscribeGroups", "stats", "delaying="]) {
            @Assert(text.contains(command))
        }
        @Assert(text.contains("--server"))
    }
}
