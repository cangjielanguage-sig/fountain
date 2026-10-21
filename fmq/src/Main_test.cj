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

import std.collection.ArrayList
import std.fs.*
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_mq.base.MQConfigKey
import fountain::fmq.server.MQServer
import fountain::fmq.test.TestDirs

@Test
class MainTest {
    @TestCase
    public func topLevelHelpReturnsZero(): Unit {
        @Assert(dispatch(["--help"]) == 0)
        @Assert(dispatch(["-h"]) == 0)
    }

    /** `server` 与 `manager` 都走可注入工厂，方便断言「调用一次 + 返回码透传」（A68）。 */
    @TestCase
    public func dispatchWithInjectedFactories(): Unit {
        let serverCalls = AtomicInt64(0)
        let managerCalls = AtomicInt64(0)
        let seenArgs = ArrayList<String>()
        let code = dispatchWith(
            {=>
                serverCalls.fetchAdd(1)
                7
            },
            {args =>
                managerCalls.fetchAdd(1)
                for (arg in args) {
                    seenArgs.add(arg)
                }
                9
            },
            ["server"])
        @Assert(code == 7)
        @Assert(serverCalls.load() == 1)
        @Assert(managerCalls.load() == 0)

        let managerCode = dispatchWith(
            {=>
                serverCalls.fetchAdd(1)
                7
            },
            {args =>
                managerCalls.fetchAdd(1)
                for (arg in args) {
                    seenArgs.add(arg)
                }
                9
            },
            ["manager", "listTopics", "--server=127.0.0.1:1"])
        @Assert(managerCode == 9)
        @Assert(managerCalls.load() == 1)
        @Assert(serverCalls.load() == 1)
        @Assert(seenArgs.toArray() == ["listTopics", "--server=127.0.0.1:1"])

        // 配置参数前置时仍能识别子命令（A69）
        let serverCalled = AtomicInt64(0)
        let prefixed = dispatchWith(
            {=>
                serverCalled.fetchAdd(1)
                3
            },
            {_ => 4},
            ["--mqServer_port=2400", "server"])
        @Assert(prefixed == 3)
        @Assert(serverCalled.load() == 1)
    }

    @TestCase
    public func noArgumentsOrUnknownCommandReturnsTwo(): Unit {
        @Assert(dispatch([]) == 2)
        @Assert(dispatch(["bogus"]) == 2)
    }

    @TestCase
    public func serverAndManagerHelpReturnZero(): Unit {
        @Assert(dispatch(["server", "--help"]) == 0)
        @Assert(dispatch(["manager", "--help"]) == 0)
        @Assert(dispatch(["manager", "registerTopic", "--help"]) == 0)
    }

    @TestCase
    public func invalidManagerArgumentsReturnTwo(): Unit {
        // 缺队列数
        @Assert(dispatch(["manager", "registerTopic", "/t"]) == 2)
        // listTopics 多给参数
        @Assert(dispatch(["manager", "listTopics", "extra"]) == 2)
        // 未知子命令
        @Assert(dispatch(["manager", "bogus"]) == 2)
    }

    @TestCase
    public func serverStartupValidationFailureReturnsTwo(): Unit {
        let sandbox = ConfigSandbox(["mqServer_backup", MQConfigKey.CLIENT_HOSTS, "mqServer_port",
            "mqServer_deadMsgThreshold"])
        try {
            Config.set([
                ("mqServer_backup", "-1"),
                (MQConfigKey.CLIENT_HOSTS, "127.0.0.1:2350"),
                ("mqServer_port", "2350"),
                ("mqServer_deadMsgThreshold", "3")
            ])
            // 配置非法 ⇒ 装配点返回 2，不进入阻塞监听
            @Assert(dispatch(["server"]) == 2)
        } finally {
            sandbox.close()
        }
    }

    /** 启动顺序：装配 → 安装退出钩子 → 阻塞运行；装配失败时后两步都不执行（A68）。 */
    @TestCase
    public func serverInstallsExitHooksBeforeRun(): Unit {
        let root = TestDirs.of("main", "run_server")
        if (exists(root)) {
            remove(root, recursive: true)
        }
        Directory.create(root, recursive: true)
        let sandbox = ConfigSandbox(["mqServer_port", MQConfigKey.CLIENT_HOSTS,
            "mqServer_segmentedLogDir", "mqServer_deadMsgDir", "mqServer_backup"])
        try {
            Config.set([
                ("mqServer_port", "29555"),
                (MQConfigKey.CLIENT_HOSTS, "127.0.0.1:29555"),
                ("mqServer_segmentedLogDir", "${root}/logs"),
                ("mqServer_deadMsgDir", "${root}/dead"),
                ("mqServer_backup", "0")
            ])
            let order = ArrayList<String>()
            let code = runServerWith(
                {=>
                    order.add("create")
                    MQServer()
                },
                {_ => order.add("hooks")},
                {server =>
                    order.add("run")
                    server.close()
                    0
                })
            @Assert(code == 0)
            @Assert(order.toArray() == ["create", "hooks", "run"])

            // 装配失败：返回 2，钩子与运行都不发生
            let failures = ArrayList<String>()
            let failed = runServerWith(
                {=> throw Exception("assembly boom")},
                {_ => failures.add("hooks")},
                {_ =>
                    failures.add("run")
                    0
                })
            @Assert(failed == 2)
            @Assert(failures.size == 0)
        } finally {
            sandbox.close()
            if (exists(root)) {
                remove(root, recursive: true)
            }
        }
    }
}


/**
 * 配置沙箱：记录键的「存在性与值」，结束时原样恢复（存在则写回，不存在则删除）。
 *
 * 配置是进程级全局状态，用例之间必须互不残留（A24）。
 */
private class ConfigSandbox <: Resource {
    private let saved = ArrayList<(String, ?String)>()

    init(keys: Array<String>) {
        for (key in keys) {
            saved.add((key, Config.getString(key)))
        }
    }

    public func isClosed(): Bool {
        false
    }

    public func close(): Unit {
        for ((key, value) in saved) {
            match (value) {
                case Some(text) => Config.set([(key, text)])
                case None => Config.remove(key)
            }
        }
    }
}

