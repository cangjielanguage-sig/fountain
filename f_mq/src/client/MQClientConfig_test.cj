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
package fountain::f_mq.client

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_mq.base.MQConfigKey
import fountain::f_mq.exception.MQConnectionException

@Test
class MQClientConfigTest {
    /** 配置是进程级全局状态：用例结束后必须还原，避免污染同一进程里的其它用例（A24）。 */
    private static func withHosts(value: String, body: () -> Unit): Unit {
        let previous = Config.getString(MQConfigKey.CLIENT_HOSTS)
        try {
            Config.set([(MQConfigKey.CLIENT_HOSTS, value)])
            body()
        } finally {
            match (previous) {
                case Some(text) => Config.set([(MQConfigKey.CLIENT_HOSTS, text)])
                // 恢复「不存在」必须删除键：设成空串会留下 Some("")
                case None => Config.remove(MQConfigKey.CLIENT_HOSTS)
            }
        }
    }

    @TestCase
    public func configKeepsOrderAndTrimsSpaces(): Unit {
        withHosts("127.0.0.1:2350, 127.0.0.1:2351") {
            let hosts = MQClientConfig.hosts
            @Assert(hosts == ["127.0.0.1:2350", "127.0.0.1:2351"])
        }
    }

    /** 配置缺失（空值）必须报出配置项名（A24）。 */
    @TestCase
    public func emptyConfigThrowsWithKeyName(): Unit {
        withHosts("") {
            var message = ""
            try {
                MQClientConfig.hosts
            } catch (e: MQConnectionException) {
                message = e.message
            }
            @Assert(message.contains(MQConfigKey.CLIENT_HOSTS))
        }
    }

    /** 非法 `host:port` 不得被静默跳过（A24）。 */
    @TestCase
    public func invalidEntryIsRejected(): Unit {
        withHosts("127.0.0.1:2350,not-a-host") {
            var message = ""
            try {
                MQClientConfig.hosts
            } catch (e: MQConnectionException) {
                message = e.message
            }
            @Assert(message.contains("not-a-host"))
        }
        withHosts("127.0.0.1:99999") {
            var threw = false
            try {
                MQClientConfig.hosts
            } catch (_: MQConnectionException) {
                threw = true
            }
            @Assert(threw)
        }
    }

    /** 修改前键不存在时，用例结束后键必须重新消失，而不是留下空串（A24）。 */
    @TestCase
    public func configIsRemovedWhenAbsentBeforeTest(): Unit {
        Config.remove(MQConfigKey.CLIENT_HOSTS)
        withHosts("10.0.0.1:1") {
            @Assert(Config.getString(MQConfigKey.CLIENT_HOSTS) == Some("10.0.0.1:1"))
        }
        @Assert(Config.getString(MQConfigKey.CLIENT_HOSTS).isNone())
    }

    /** 用例之间不得互相残留配置（A24）。 */
    @TestCase
    public func configIsRestoredAfterTest(): Unit {
        let before = Config.getString(MQConfigKey.CLIENT_HOSTS)
        withHosts("10.0.0.1:1") {
            @Assert(Config.getString(MQConfigKey.CLIENT_HOSTS) == Some("10.0.0.1:1"))
        }
        @Assert(Config.getString(MQConfigKey.CLIENT_HOSTS) == before)
    }
}
