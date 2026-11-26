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

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import fountain::fprobe.alarm.{AlarmEvent, AlarmEventType}
import fountain::fprobe.snapshot.ProbeSnapshot
import fountain::fprobe.supervisor.{NodeState, NodeStatus}

private let VALID_ADVICE = "{\"summary\":\"需要处理\",\"problems\":[\"CPU 高\"],\"solutions\":[]}"

private func alarmEvent(): AlarmEvent {
    AlarmEvent(AlarmEventType.FIRING, "web1", "cpu-high", "cpu", "critical",
        Some(90.0), 80.0, 1000, "CPU 过高")
}

private func onlineState(): NodeState {
    NodeState("web1", NodeStatus.ONLINE, 0, Some(ProbeSnapshot("web1", "host", 1000, [])), "", 1000)
}

private class AdviceSink {
    let summaries = ArrayList<String>()
}

/** 16.3：开关、触发方式与 LLM 故障隔离。 */
@Test
public class ProbeAdvisor_test {
    @TestCase
    public func disabledAdvisorNeverCallsLlm(): Unit {
        let llm = FakeLlm(defaultResponse: VALID_ADVICE)
        let sink = AdviceSink()
        let advisor = ProbeAdvisor(false, LlmTrigger.ALARM, llm,
            onAdvice: {advice => sink.summaries.add(advice.summary)}, logError: {_ => ()})

        advisor.analyzeAlarm(alarmEvent(), [onlineState()], LlmFakeHistory())
        advisor.analyzeInterval([onlineState()], LlmFakeHistory())

        @Assert(llm.calls, 0)
        @Assert(sink.summaries.isEmpty())
    }

    @TestCase
    public func alarmTriggerOnlyRunsForAlarms(): Unit {
        let llm = FakeLlm(defaultResponse: VALID_ADVICE)
        let advisor = ProbeAdvisor(true, LlmTrigger.ALARM, llm, logError: {_ => ()})

        advisor.analyzeInterval([onlineState()], LlmFakeHistory())
        @Assert(llm.calls, 0)
        advisor.analyzeAlarm(alarmEvent(), [onlineState()], LlmFakeHistory())
        @Assert(llm.calls, 1)
    }

    @TestCase
    public func intervalTriggerOnlyRunsForInterval(): Unit {
        let llm = FakeLlm(defaultResponse: VALID_ADVICE)
        let advisor = ProbeAdvisor(true, LlmTrigger.INTERVAL, llm, logError: {_ => ()})

        advisor.analyzeAlarm(alarmEvent(), [onlineState()], LlmFakeHistory())
        @Assert(llm.calls, 0)
        advisor.analyzeInterval([onlineState()], LlmFakeHistory())
        @Assert(llm.calls, 1)
    }

    @TestCase
    public func bothTriggerRunsBoth(): Unit {
        let llm = FakeLlm(defaultResponse: VALID_ADVICE)
        let advisor = ProbeAdvisor(true, LlmTrigger.BOTH, llm, logError: {_ => ()})

        advisor.analyzeAlarm(alarmEvent(), [onlineState()], LlmFakeHistory())
        advisor.analyzeInterval([onlineState()], LlmFakeHistory())
        @Assert(llm.calls, 2)
    }

    @TestCase
    public func llmFailureIsLoggedAndDoesNotBlockNextAttempt(): Unit {
        let llm = FakeLlm(defaultResponse: VALID_ADVICE)
        llm.fail = true
        let errors = ArrayList<String>()
        let sink = AdviceSink()
        let advisor = ProbeAdvisor(true, LlmTrigger.BOTH, llm,
            onAdvice: {advice => sink.summaries.add(advice.summary)},
            logError: {message => errors.add(message)})

        advisor.analyzeAlarm(alarmEvent(), [onlineState()], LlmFakeHistory())
        advisor.analyzeAlarm(alarmEvent(), [onlineState()], LlmFakeHistory())

        @Assert(llm.calls, 2)
        @Assert(sink.summaries.isEmpty())
        @Assert(errors.size, 2)
        @Assert(errors[0].contains("llm down"))
    }

    @TestCase
    public func emptyResponseIsTreatedAsFailure(): Unit {
        let llm = FakeLlm(defaultResponse: "   ")
        let errors = ArrayList<String>()
        let sink = AdviceSink()
        let advisor = ProbeAdvisor(true, LlmTrigger.ALARM, llm,
            onAdvice: {advice => sink.summaries.add(advice.summary)},
            logError: {message => errors.add(message)})

        advisor.analyzeAlarm(alarmEvent(), [onlineState()], LlmFakeHistory())

        @Assert(sink.summaries.isEmpty())
        @Assert(errors.size, 1)
        @Assert(errors[0].contains("空"))
    }
}
