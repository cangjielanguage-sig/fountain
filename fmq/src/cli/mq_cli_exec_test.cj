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
}
