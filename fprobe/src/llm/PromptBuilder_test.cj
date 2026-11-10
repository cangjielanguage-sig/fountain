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
package fountain::fprobe.llm

import std.unittest.*
import std.unittest.testmacro.*
import fountain::fprobe.alarm.{AlarmEvent, AlarmEventType}
import fountain::fprobe.snapshot.{ProbeAgentData, ProbeSnapshot}
import fountain::fprobe.supervisor.{NodeState, NodeStatus}

/** 16.1：节点摘要 + 告警 + 最近 N 点。 */
@Test
public class PromptBuilder_test {
    @TestCase
    public func promptContainsNodeThresholdAndHistory(): Unit {
        let snapshot = ProbeSnapshot("web1", "host1", 1000,
            [ProbeAgentData("cpu", "", "{\"usagePercent\":87.5}", 1000, "")])
        let state = NodeState("web1", NodeStatus.ONLINE, 0, Some(snapshot), "", 1000)
        let event = AlarmEvent(AlarmEventType.FIRING, "web1", "cpu-high", "cpu", "critical",
            Some(87.5), 80.0, 1000, "CPU 过高")
        let history = LlmFakeHistory()
        history.set("web1", "cpu.usagePercent", Array<Float64>(20) {i => Float64(i)})

        let prompt = PromptBuilder.build([state], [event], history, historyPoints: 20)

        @Assert(prompt.contains("web1"))
        @Assert(prompt.contains("87.5"))
        @Assert(prompt.contains("80"))
        @Assert(prompt.contains("cpu-high"))
        @Assert(prompt.contains("critical"))
        @Assert(prompt.contains("(共 20 点)"))
        @Assert(prompt.contains("\"summary\""))
        @Assert(prompt.contains("\"solutions\""))
    }

    @TestCase
    public func emptyHistoryIsReportedWithoutFakePoints(): Unit {
        let state = NodeState("db1", NodeStatus.OFFLINE, 3, None<ProbeSnapshot>, "timeout", 1000)
        let prompt = PromptBuilder.build([state], [], LlmFakeHistory(), historyPoints: 20)

        @Assert(prompt.contains("db1"))
        @Assert(prompt.contains("离线"))
        @Assert(!prompt.contains("(共 0 点)"))
    }
}
