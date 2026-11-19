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
package fountain::fprobe

import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 子命令分发只依赖可注入的工厂，启动路径与参数解析可分别验证。
 */
@Test
public class Main_test {
    @TestCase
    public func helpReturnsZeroWithoutStartingAnything(): Unit {
        let calls = AtomicInt64(0)
        @Assert(dispatchWith({=>
                calls.fetchAdd(1)
                7
            }, {_ =>
                calls.fetchAdd(1)
                8
            }, ["--help"]) == 0)
        @Assert(dispatchWith({=>
                calls.fetchAdd(1)
                7
            }, {_ =>
                calls.fetchAdd(1)
                8
            }, ["-h"]) == 0)
        @Assert(calls.load() == 0)
    }

    @TestCase
    public func agentDispatchCallsFactoryOnce(): Unit {
        let agentCalls = AtomicInt64(0)
        let supervisorCalls = AtomicInt64(0)
        let code = dispatchWith({=>
                agentCalls.fetchAdd(1)
                7
            }, {_ =>
                supervisorCalls.fetchAdd(1)
                8
            }, ["agent"])
        @Assert(code == 7)
        @Assert(agentCalls.load() == 1)
        @Assert(supervisorCalls.load() == 0)
    }

    @TestCase
    public func supervisorDispatchPassesResidentFlag(): Unit {
        let agentCalls = AtomicInt64(0)
        let supervisorCalls = AtomicInt64(0)
        let residentCalls = AtomicInt64(0)
        let code = dispatchWith({=>
                agentCalls.fetchAdd(1)
                7
            }, {resident =>
                supervisorCalls.fetchAdd(1)
                if (resident) {
                    residentCalls.fetchAdd(1)
                }
                8
            }, ["supervisor", "resident"])
        @Assert(code == 8)
        @Assert(agentCalls.load() == 0)
        @Assert(supervisorCalls.load() == 1)
        @Assert(residentCalls.load() == 1)

        let normalResident = AtomicInt64(0)
        let normal = dispatchWith({=> 7}, {resident =>
                if (resident) {
                    normalResident.fetchAdd(1)
                }
                8
            }, ["supervisor"])
        @Assert(normal == 8)
        @Assert(normalResident.load() == 0)
    }

    @TestCase
    public func missingOrUnknownCommandReturnsTwo(): Unit {
        let calls = AtomicInt64(0)
        @Assert(dispatchWith({=>
                calls.fetchAdd(1)
                7
            }, {_ =>
                calls.fetchAdd(1)
                8
            }, []) == 2)
        @Assert(dispatchWith({=>
                calls.fetchAdd(1)
                7
            }, {_ =>
                calls.fetchAdd(1)
                8
            }, ["bogus"]) == 2)
        @Assert(calls.load() == 0)
    }

    @TestCase
    public func subcommandHelpReturnsZeroWithoutStartingAnything(): Unit {
        let calls = AtomicInt64(0)
        @Assert(dispatchWith({=>
                calls.fetchAdd(1)
                7
            }, {_ =>
                calls.fetchAdd(1)
                8
            }, ["agent", "--help"]) == 0)
        @Assert(dispatchWith({=>
                calls.fetchAdd(1)
                7
            }, {_ =>
                calls.fetchAdd(1)
                8
            }, ["supervisor", "--help"]) == 0)
        @Assert(calls.load() == 0)
    }

    @TestCase
    public func optionsBeforeCommandAreTolerated(): Unit {
        let agentCalls = AtomicInt64(0)
        let code = dispatchWith({=>
                agentCalls.fetchAdd(1)
                3
            }, {_ => 8}, ["--probe_port=12325", "agent"])
        @Assert(code == 3)
        @Assert(agentCalls.load() == 1)
    }
}
