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
package fountain::fmq.config

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_config.Config
import fountain::f_mq.base.MQConfigKey

@Test
class MQConfigTest {
    /**
     * 配置是进程级全局状态，用例必须串行读写；这里放在同一个用例里逐段验证，
     * 避免并行 worker 互相覆盖。
     */
    @TestCase
    public func allConfigSemantics(): Unit {
        // ---- 默认值 ----
        Config.set([
            (MQConfig.PORT, "2350"),
            (MQConfig.ACK_TIMEOUT, "10s"),
            (MQConfig.DEAD_MSG_THRESHOLD, "3"),
            (MQConfig.DEAD_MSG_TTL, "72h"),
            (MQConfig.SEGMENTED_LOG_DIR, "/var/log/fmq/segmentedLogs"),
            (MQConfig.DEAD_MSG_DIR, "/var/log/fmq/deadMsgs"),
            (MQConfig.SEGMENTED_LOG_MAX_SIZE, "1G"),
            (MQConfig.SEGMENTED_LOG_TTL, "72h"),
            (MQConfig.BACKUP, "0"),
            (MQConfigKey.CLIENT_HOSTS, "127.0.0.1:2350")
        ])
        @Assert(MQConfig.port == 2350)
        @Assert(MQConfig.ackTimeout == Duration.second * 10)
        @Assert(MQConfig.deadMsgThreshold == 3)
        @Assert(MQConfig.deadMsgTTL == Duration.hour * 72)
        @Assert(MQConfig.segmentedLogDir == "/var/log/fmq/segmentedLogs")
        @Assert(MQConfig.deadMsgDir == "/var/log/fmq/deadMsgs")
        @Assert(MQConfig.segmentedLogMaxSize == 1_073_741_824)
        @Assert(MQConfig.segmentedLogTTL == Duration.hour * 72)
        @Assert(MQConfig.backup == 0)
        @Assert(MQConfig.nodes == ["127.0.0.1:2350"])
        @Assert(MQConfig.selfIndex == 0)
        MQConfig.validate()

        // ---- 逐项覆盖 ----
        Config.set([
            (MQConfig.PORT, "2401"),
            (MQConfig.ACK_TIMEOUT, "500ms"),
            (MQConfig.DEAD_MSG_THRESHOLD, "7"),
            (MQConfig.DEAD_MSG_TTL, "5h"),
            (MQConfig.SEGMENTED_LOG_DIR, "/tmp/logs"),
            (MQConfig.DEAD_MSG_DIR, "/tmp/dead"),
            (MQConfig.SEGMENTED_LOG_MAX_SIZE, "2M"),
            (MQConfig.SEGMENTED_LOG_TTL, "3h"),
            (MQConfig.BACKUP, "2"),
            (MQConfigKey.CLIENT_HOSTS, "h1:2400, h2:2401")
        ])
        @Assert(MQConfig.port == 2401)
        @Assert(MQConfig.ackTimeout == Duration.millisecond * 500)
        @Assert(MQConfig.deadMsgThreshold == 7)
        @Assert(MQConfig.deadMsgTTL == Duration.hour * 5)
        @Assert(MQConfig.segmentedLogDir == "/tmp/logs")
        @Assert(MQConfig.deadMsgDir == "/tmp/dead")
        @Assert(MQConfig.segmentedLogMaxSize == 2 * 1024 * 1024)
        @Assert(MQConfig.segmentedLogTTL == Duration.hour * 3)
        @Assert(MQConfig.backup == 2)
        @Assert(MQConfig.nodes.size == 2)
        @Assert(MQConfig.selfIndex == 1)

        var message = ""

        // ---- 非法显式值必须报错，不能静默回落（A63） ----
        Config.set([(MQConfig.SEGMENTED_LOG_MAX_SIZE, "not-a-size")])
        message = ""
        try {
            MQConfig.validate()
        } catch (e: MQConfigException) {
            message = e.message
        }
        @Assert(message.contains("not a byte size"))
        Config.set([(MQConfig.SEGMENTED_LOG_MAX_SIZE, "1G")])

        Config.set([(MQConfig.PORT, "abc")])
        message = ""
        try {
            MQConfig.validate()
        } catch (e: MQConfigException) {
            message = e.message
        }
        @Assert(message.contains("not a valid port"))
        Config.set([(MQConfig.PORT, "2401")])

        // ---- 负数 backup ----
        Config.set([(MQConfig.BACKUP, "-1")])
        try {
            MQConfig.validate()
        } catch (e: MQConfigException) {
            message = e.message
        }
        @Assert(message.contains("negative"))

        // ---- 缺少节点表 ----
        Config.set([(MQConfig.BACKUP, "0"), (MQConfigKey.CLIENT_HOSTS, "")])
        message = ""
        try {
            MQConfig.validate()
        } catch (e: MQConfigException) {
            message = e.message
        }
        @Assert(message.contains(MQConfigKey.CLIENT_HOSTS))

        // ---- 端口不在节点表 ----
        Config.set([(MQConfig.PORT, "9999"), (MQConfigKey.CLIENT_HOSTS, "h1:2350,h2:2351")])
        message = ""
        try {
            MQConfig.validate()
        } catch (e: MQConfigException) {
            message = e.message
        }
        @Assert(message.contains("is not in"))

        // ---- 端口重复 ----
        Config.set([(MQConfig.PORT, "2350"), (MQConfigKey.CLIENT_HOSTS, "h1:2350,h2:2350")])
        message = ""
        try {
            MQConfig.validate()
        } catch (e: MQConfigException) {
            message = e.message
        }
        @Assert(message.contains("duplicate"))

        // ---- 非本机端口重复也必须拒绝 ----
        Config.set([(MQConfig.PORT, "2350"), (MQConfigKey.CLIENT_HOSTS, "h1:2350,h2:2351,h3:2351")])
        message = ""
        try {
            MQConfig.validate()
        } catch (e: MQConfigException) {
            message = e.message
        }
        @Assert(message.contains("duplicate"))

        // ---- 阈值为 0 ----
        Config.set([(MQConfig.PORT, "2350"), (MQConfigKey.CLIENT_HOSTS, "h1:2350"),
            (MQConfig.DEAD_MSG_THRESHOLD, "0")])
        message = ""
        try {
            MQConfig.validate()
        } catch (e: MQConfigException) {
            message = e.message
        }
        @Assert(message.contains("at least 1"))

        // ---- 各项 0 / 负值都拒绝启动（A54/A63） ----
        let zeroCases = [
            (MQConfig.ACK_TIMEOUT, "0s"),
            (MQConfig.SEGMENTED_LOG_MAX_SIZE, "0"),
            (MQConfig.SEGMENTED_LOG_TTL, "0s"),
            (MQConfig.DEAD_MSG_TTL, "-1h"),
            (MQConfig.TOMBSTONE_TTL, "0s"),
            (MQConfig.ANTI_ENTROPY_INTERVAL, "0s")
        ]
        for ((key, value) in zeroCases) {
            Config.set([
                (MQConfig.PORT, "2350"),
                (MQConfigKey.CLIENT_HOSTS, "h1:2350"),
                (MQConfig.ACK_TIMEOUT, "10s"),
                (MQConfig.SEGMENTED_LOG_MAX_SIZE, "1M"),
                (MQConfig.SEGMENTED_LOG_TTL, "72h"),
                (MQConfig.DEAD_MSG_TTL, "72h"),
                (MQConfig.TOMBSTONE_TTL, "7d"),
                (MQConfig.ANTI_ENTROPY_INTERVAL, "30s"),
                (key, value)
            ])
            var rejected = false
            try {
                MQConfig.validate()
            } catch (_: MQConfigException) {
                rejected = true
            }
            @Assert(rejected)
        }

        // ---- 非法 host:port ----
        Config.set([
            (MQConfig.PORT, "2350"),
            (MQConfigKey.CLIENT_HOSTS, "h1:0"),
            (MQConfig.ACK_TIMEOUT, "10s"),
            (MQConfig.SEGMENTED_LOG_MAX_SIZE, "1M"),
            (MQConfig.SEGMENTED_LOG_TTL, "72h"),
            (MQConfig.DEAD_MSG_TTL, "72h"),
            (MQConfig.TOMBSTONE_TTL, "7d"),
            (MQConfig.ANTI_ENTROPY_INTERVAL, "30s")
        ])
        message = ""
        try {
            MQConfig.validate()
        } catch (e: MQConfigException) {
            message = e.message
        }
        @Assert(message.contains("invalid node"))

        // ---- backup 超过节点数 ----
        Config.set([
            (MQConfig.PORT, "2350"),
            (MQConfigKey.CLIENT_HOSTS, "h1:2350,h2:2351,h3:2352"),
            (MQConfig.BACKUP, "3")
        ])
        message = ""
        try {
            MQConfig.validate()
        } catch (e: MQConfigException) {
            message = e.message
        }
        @Assert(message.contains("exceeds node count"))

        // ---- 合法边界通过 ----
        Config.set([
            (MQConfig.PORT, "2350"),
            (MQConfigKey.CLIENT_HOSTS, "h1:2350,h2:2351,h3:2352"),
            (MQConfig.BACKUP, "2"),
            (MQConfig.ACK_TIMEOUT, "1ms"),
            (MQConfig.SEGMENTED_LOG_MAX_SIZE, "1M"),
            (MQConfig.SEGMENTED_LOG_TTL, "72h"),
            (MQConfig.DEAD_MSG_TTL, "72h"),
            (MQConfig.TOMBSTONE_TTL, "7d"),
            (MQConfig.ANTI_ENTROPY_INTERVAL, "30s"),
            (MQConfig.DEAD_MSG_THRESHOLD, "1")
        ])
        MQConfig.validate()
        @Assert(MQConfig.segmentedLogMaxSize == 1024 * 1024)
        @Assert(MQConfig.ackTimeout == Duration.millisecond)

        // ---- 帮助文本 ----
        let text = MQConfig.helpText()
        for (key in [MQConfig.PORT, MQConfig.ACK_TIMEOUT, MQConfig.DEAD_MSG_THRESHOLD, MQConfig.DEAD_MSG_TTL,
            MQConfig.SEGMENTED_LOG_DIR, MQConfig.DEAD_MSG_DIR, MQConfig.SEGMENTED_LOG_MAX_SIZE,
            MQConfig.SEGMENTED_LOG_TTL, MQConfig.BACKUP, MQConfigKey.CLIENT_HOSTS]) {
            @Assert(text.contains(key))
        }
    }
}
