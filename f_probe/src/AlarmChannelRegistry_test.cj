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
package fountain::f_probe

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class AlarmChannelRegistry_test {
    /** 注册两个渠道后可按名枚举与查找。 */
    @TestCase
    public func registerTwoChannels(): Unit {
        AlarmChannelRegistry.clear()
        AlarmChannelRegistry.registerChannel("email", {=> RegistryChannel("email")})
        AlarmChannelRegistry.registerChannel("webhook", {=> RegistryChannel("webhook")})

        let names = AlarmChannelRegistry.channels()
        @Assert(names.size, 2)
        @Assert(names.contains("email"))
        @Assert(names.contains("webhook"))
        @Assert(AlarmChannelRegistry.channel("email").getOrThrow()().replyConf(), "email")
        @Assert(AlarmChannelRegistry.channel("webhook").getOrThrow()().replyConf(), "webhook")

        AlarmChannelRegistry.clear()
    }

    /** 重名渠道被拒绝，不覆盖已登记工厂。 */
    @TestCase
    public func duplicateChannelIsRejected(): Unit {
        AlarmChannelRegistry.clear()
        AlarmChannelRegistry.registerChannel("email", {=> RegistryChannel("first")})

        var caught = false
        try {
            AlarmChannelRegistry.registerChannel("email", {=> RegistryChannel("second")})
        } catch (e: ProbeException) {
            caught = true
            @Assert(e.code, ProbeErrorCode.DUPLICATE)
            @Assert(e.message.contains("email"))
        }
        @Assert(caught)
        @Assert(AlarmChannelRegistry.channel("email").getOrThrow()().replyConf(), "first")

        AlarmChannelRegistry.clear()
    }

    /** 多线程并发注册不同渠道。 */
    @TestCase
    public func concurrentChannelRegistration(): Unit {
        AlarmChannelRegistry.clear()
        let count = 24
        let futures = ArrayList<Future<Unit>>()
        for (i in 0..count) {
            let name = "channel-${i}"
            futures.add(spawn {=> AlarmChannelRegistry.registerChannel(name, {=> RegistryChannel(name)}) })
        }
        for (future in futures) {
            future.get()
        }
        @Assert(AlarmChannelRegistry.channels().size, count)

        AlarmChannelRegistry.clear()
    }
}

class RegistryChannel <: AlarmMessageChannel {
    private let name: String

    public init(name: String) {
        this.name = name
    }

    public func send(_: String, _: Array<String>): Unit {}

    public func receive(): String {
        ""
    }

    public func replyConf(): String {
        name
    }
}
