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

import fountain::fprobe.alarm.AlarmEvent
import fountain::fprobe.supervisor.NodeState
import fountain::fprobe.tui.HistorySource

/** 智能体触发方式。 */
public enum LlmTrigger <: Equatable<LlmTrigger> {
    | ALARM
    | INTERVAL
    | BOTH

    public operator func ==(other: LlmTrigger): Bool {
        match ((this, other)) {
            case (ALARM, ALARM) | (INTERVAL, INTERVAL) | (BOTH, BOTH) => true
            case _ => false
        }
    }

    public static func parse(value: String): LlmTrigger {
        match (value.trimAscii().toAsciiLower()) {
            case "interval" => INTERVAL
            case "both" => BOTH
            case _ => ALARM
        }
    }

    public func includesAlarm(): Bool {
        this == ALARM || this == BOTH
    }

    public func includesInterval(): Bool {
        this == INTERVAL || this == BOTH
    }
}

/**
 * 智能体编排（spec「开关与触发」「LLM 故障隔离」）。
 *
 * 关闭时不构造提示词、不调用模型；模型异常/空响应只记录 ERROR，不影响调用方
 * 的拉取、告警与报告。
 */
public class ProbeAdvisor {
    private let enabled: Bool
    private let trigger: LlmTrigger
    private let client: LlmClient
    private let onAdvice: (LlmAdvice) -> Unit
    private let historyPoints: Int64
    private let logError: (String) -> Unit

    public init(enabled: Bool, trigger: LlmTrigger, client: LlmClient,
        onAdvice!: (LlmAdvice) -> Unit = {_ => ()}, historyPoints!: Int64 = 20,
        logError!: (String) -> Unit = {message => eprintln(message)}) {
        this.enabled = enabled
        this.trigger = trigger
        this.client = client
        this.onAdvice = onAdvice
        this.historyPoints = historyPoints
        this.logError = logError
    }

    public func analyzeAlarm(event: AlarmEvent, states: Array<NodeState>, history: HistorySource): Unit {
        if (!enabled || !trigger.includesAlarm()) {
            return
        }
        analyze(states, [event], history)
    }

    public func analyzeInterval(states: Array<NodeState>, history: HistorySource,
        events!: Array<AlarmEvent> = []): Unit {
        if (!enabled || !trigger.includesInterval()) {
            return
        }
        analyze(states, events, history)
    }

    private func analyze(states: Array<NodeState>, events: Array<AlarmEvent>,
        history: HistorySource): Unit {
        let prompt = PromptBuilder.build(states, events, history, historyPoints: historyPoints)
        try {
            let text = client.chat(prompt)
            if (text.trimAscii().isEmpty()) {
                logError("LLM 返回空内容，本次分析跳过")
                return
            }
            onAdvice(AdviceParser.parse(text))
        } catch (e: Exception) {
            logError('LLM 调用失败: ${e.message}')
        } catch (e: Error) {
            logError('LLM 调用失败: ${e.message}')
        }
    }
}
