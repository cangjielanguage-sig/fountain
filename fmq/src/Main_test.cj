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
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_mq.base.MQConfigKey

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
        Config.set([
            ("mqServer_backup", "-1"),
            (MQConfigKey.CLIENT_HOSTS, "127.0.0.1:2350"),
            ("mqServer_port", "2350"),
            ("mqServer_deadMsgThreshold", "3")
        ])
        // 配置非法 ⇒ 装配点返回 2，不进入阻塞监听
        @Assert(dispatch(["server"]) == 2)
        // 恢复
        Config.set([("mqServer_backup", "0")])
    }
}
