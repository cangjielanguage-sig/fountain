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
package fountain::fprobe.runtime

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_probe.{ProbeErrorCode, ProbeException}
import fountain::f_config.Config
import fountain::fprobe.channel.ChannelMessage
import fountain::fprobe.llm.{ActionWhitelist, LlmAdvice, LlmSolution, ReplyDecision}

/** 装配层的纯函数：建议格式化、回复解析、主指标提取、渠道构建。 */
@Test
public class SupervisorRuntime_test {
    @TestCase
    public func adviceMessageCarriesProblemsSolutionsAndReplyHint(): Unit {
        let advice = LlmAdvice("磁盘将满", ["根分区 95%"],
            [LlmSolution("清理日志", "mute", "低"), LlmSolution("扩容", "none", "高")])
        let text = SupervisorRuntime.formatAdvice(advice)
        @Assert(text.contains("磁盘将满"))
        @Assert(text.contains("根分区 95%"))
        @Assert(text.contains("[mute] 清理日志"))
        @Assert(text.contains("回复格式"))
    }

    @TestCase
    public func approveReplyRunsWhitelistedAction(): Unit {
        let muted = ArrayList<(String, Int64)>()
        let whitelist = ActionWhitelist(mute: {rule: String, until: Int64 => muted.add((rule, until))}, nowMs: {=> 1000}, muteSeconds: 600)
        SupervisorRuntime.handleReply(ChannelMessage("m1", "ops@example.com", "同意", "同意 mute cpu-high"),
            whitelist)
        @Assert(muted.size, 1)
        @Assert(muted[0][0], "cpu-high")
        @Assert(muted[0][1], 601000)
    }

    @TestCase
    public func rejectReplyDoesNotRunAction(): Unit {
        let muted = ArrayList<(String, Int64)>()
        let whitelist = ActionWhitelist(mute: {rule: String, until: Int64 => muted.add((rule, until))}, nowMs: {=> 1000}, muteSeconds: 600)
        SupervisorRuntime.handleReply(ChannelMessage("m2", "ops@example.com", "拒绝", "拒绝 mute cpu-high"),
            whitelist)
        @Assert(muted.isEmpty())
    }

    @TestCase
    public func unrecognizedReplyIsIgnored(): Unit {
        let muted = ArrayList<(String, Int64)>()
        let whitelist = ActionWhitelist(mute: {rule: String, until: Int64 => muted.add((rule, until))}, nowMs: {=> 1000}, muteSeconds: 600)
        SupervisorRuntime.handleReply(ChannelMessage("m3", "ops@example.com", "", "随便聊聊"), whitelist)
        @Assert(muted.isEmpty())
    }

    @TestCase
    public func metricExtractorReadsPrimaryValuePerKind(): Unit {
        @Assert(MetricExtractor.primary("cpu", '{"usagePercent":12.5}').getOrThrow(), 12.5)
        @Assert(MetricExtractor.primary("disk", '{"mounts":[{"usedPercent":88.0}]}')
            .getOrThrow(), 88.0)
        @Assert(MetricExtractor.primary("unknown", "{}").isNone())
    }

    @TestCase
    public func unknownChannelFailsDispatcherConstruction(): Unit {
        Config.set([("probe_alarmChannels", "no-such-channel")])
        var threw = false
        try {
            SupervisorRuntime.buildDispatcher()
        } catch (e: ProbeException) {
            threw = true
            @Assert(e.code, ProbeErrorCode.CONFIG)
        }
        @Assert(threw)
        Config.set([("probe_alarmChannels", "email")])
    }
}
