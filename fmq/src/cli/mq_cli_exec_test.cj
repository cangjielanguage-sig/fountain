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
package fountain::fmq.cli

import std.unittest.*
import std.unittest.testmacro.*

/**
 * CLI 命令单元测试。
 * 测试 getArg 参数解析和 runCommand 命令分发逻辑。
 * 不依赖 MQ 服务端连接。
 */

@Test
public class MqCliExecTest {
    @TestCase
    public func testUnknownCommandReturnsExitCode1(): Unit {
        let exitCode = SubCommandMediator.exec("mqcli", ["badcommand"])
        @Assert(exitCode == 1)
    }

    @TestCase
    public func testHelpCommandReturnsExitCode0(): Unit {
        let exitCode = SubCommandMediator.exec("mqcli", ["help"])
        @Assert(exitCode == 0)
    }

    /**
     * P4: 验证空参数不崩溃（CLI 交互模式过滤后可能产生空 Array）。
     */
    @TestCase
    public func testRunCommandEmptyArgs(): Unit {
        let result = MqCliCommand.runCommand([])
        @Assert(!result)
    }

    /**
     * P2-1: 引号感知参数解析 — 简单空格分隔。
     */
    @TestCase
    public func testParseArgsSimple(): Unit {
        let result = MqCliCommand.parseArgs("createTopic --name /test --queues 4")
        @Assert(result.size == 6)
        @Assert(result[0] == "createTopic")
        @Assert(result[1] == "--name")
        @Assert(result[2] == "/test")
        @Assert(result[3] == "--queues")
        @Assert(result[4] == "4")
    }

    /**
     * P2-1: 引号感知参数解析 — 双引号内含空格。
     */
    @TestCase
    public func testParseArgsDoubleQuoted(): Unit {
        let result = MqCliCommand.parseArgs("createTopic --name \"/topic with spaces\"")
        @Assert(result.size == 4)
        @Assert(result[2] == "/topic with spaces")
    }

    /**
     * P2-1: 引号感知参数解析 — 单引号内含空格。
     */
    @TestCase
    public func testParseArgsSingleQuoted(): Unit {
        let result = MqCliCommand.parseArgs("createTopic --name '/topic with spaces'")
        @Assert(result.size == 4)
        @Assert(result[2] == "/topic with spaces")
    }

    /**
     * P2-1: 引号感知参数解析 — 连续空格和只有空格的输入。
     */
    @TestCase
    public func testParseArgsWhitespace(): Unit {
        let result = MqCliCommand.parseArgs("  createTopic   --name  /test  ")
        @Assert(result.size == 4)
        @Assert(result[0] == "createTopic")
        @Assert(result[1] == "--name")
        @Assert(result[2] == "/test")
        @Assert(MqCliCommand.parseArgs("   ").size == 0)
    }

    /**
     * P2-1: 引号感知参数解析 — 混合引号和非引号参数。
     */
    @TestCase
    public func testParseArgsMixedQuoted(): Unit {
        let result = MqCliCommand.parseArgs("resetOffset --topic \"/order/test\" --group mygroup --offset 100")
        @Assert(result.size == 8)
        @Assert(result[2] == "/order/test")
        @Assert(result[4] == "mygroup")
        @Assert(result[6] == "100")
    }
}
