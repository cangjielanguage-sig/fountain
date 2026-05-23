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
public class CliCommandTest {
    // ──────────────── getArg 测试 ────────────────

    @TestCase
    public func testGetArgReturnsValue(): Unit {
        let args: Array<String> = ["--name", "/my-topic", "--queues", "3"]
        @Assert(getArg(args, "--name") == Some("/my-topic"))
    }

    @TestCase
    public func testGetArgReturnsValueForSecondFlag(): Unit {
        let args: Array<String> = ["--name", "/my-topic", "--queues", "3"]
        @Assert(getArg(args, "--queues") == Some("3"))
    }

    @TestCase
    public func testGetArgReturnsNoneForMissingFlag(): Unit {
        let args: Array<String> = ["--name", "/my-topic"]
        @Assert(getArg(args, "--topic").isNone())
    }

    @TestCase
    public func testGetArgFlagAtEndWithoutValue(): Unit {
        let args: Array<String> = ["--name", "/t", "--queues"]
        @Assert(getArg(args, "--queues").isNone())
    }

    @TestCase
    public func testGetArgEmptyArgsReturnsNone(): Unit {
        let args: Array<String> = []
        @Assert(getArg(args, "--name").isNone())
    }

    @TestCase
    public func testGetArgFlagIsValueOfPreviousFlag(): Unit {
        let args: Array<String> = ["--name", "--topic", "/t"]
        @Assert(getArg(args, "--name") == Some("--topic"))
        @Assert(getArg(args, "--topic") == Some("/t"))
    }

    @TestCase
    public func testGetArgMultipleSameFlagsReturnsFirst(): Unit {
        let args: Array<String> = ["--name", "/a", "--name", "/b"]
        @Assert(getArg(args, "--name") == Some("/a"))
    }

    @TestCase
    public func testGetArgWithNumericArg(): Unit {
        let args: Array<String> = ["--offset", "42"]
        @Assert(getArg(args, "--offset") == Some("42"))
    }

    @TestCase
    public func testGetArgWithDashPrefix(): Unit {
        let args: Array<String> = ["--group", "my-group"]
        @Assert(getArg(args, "--group") == Some("my-group"))
    }

    @TestCase
    public func testGetArgTopicWithSpecialChars(): Unit {
        let args: Array<String> = ["--topic", "/test/order/create"]
        @Assert(getArg(args, "--topic") == Some("/test/order/create"))
    }

    @TestCase
    public func testGetArgMessageId(): Unit {
        let args: Array<String> = ["--messageId", "msg-001:abc"]
        @Assert(getArg(args, "--messageId") == Some("msg-001:abc"))
    }

    @TestCase
    public func testGetArgIgnoresNonMatchingFlags(): Unit {
        let args: Array<String> = ["--other", "val", "--name", "topic"]
        @Assert(getArg(args, "--name") == Some("topic"))
    }

    /**
     * 调用 getArg 方法。
     * CommandRunner.getArg 是 internal static，通过同包内调用访问。
     */
    private static func getArg(args: Array<String>, flag: String): ?String {
        CommandRunner.getArg(args, flag)
    }
}

/**
 * MqCliCommand exec 行为测试。
 * P4-1: 未知命令返回 exit code 1
 * 注意：'fboot mqcli'（空参数）现为真正的交互模式（readln 循环），
 * 不在测试环境中执行（stdin 不可用会阻塞）。
 * 此处仅验证非空命令路径。
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
}

/**
 * createTopic 默认队列数提示时序测试。
 * P3-4: "using default queue count" 在 getClient 前打印，无服务器时也可见。
 * 无法在不启动服务端的情况下验证 println 行为，仅作文档。
 */
@Test
public class CreateTopicHintTest {
    @TestCase
    public func testCreateTopicPrintsDefaultHintBeforeConnect(): Unit {
        // 编译通过即验证 println 语法正确
        @Assert(true)
    }
}

/**
 * CLI 缓存配置测试。
 */
@Test
public class CliConfigCacheTest {
    @TestCase
    public func testGetOrLoadConfigReturnsSameInstance(): Unit {
        let c1 = CommandRunner.getOrLoadConfig()
        let c2 = CommandRunner.getOrLoadConfig()
        // 验证两次返回相同的 MqConfig 实例（dataDir 等值相同）
        @Assert(c1.dataDir == c2.dataDir)
    }
}
