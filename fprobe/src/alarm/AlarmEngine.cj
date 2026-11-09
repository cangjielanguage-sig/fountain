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
package fountain::fprobe.alarm

import std.collection.{ArrayList, HashMap, HashSet}
import fountain::f_data.*
import fountain::fprobe.collect.{Clock, jsonToData}
import fountain::fprobe.snapshot.ProbeAgentData
import fountain::fprobe.supervisor.{NodeState, NodeStatus}

/** 每条 `(节点, 规则)` 的状态机（设计 D10）。 */
private class RuleState {
    var since: ?Int64 = None
    var firing: Bool = false
    var lastSentAt: ?Int64 = None
}

/**
 * 告警评估引擎。
 *
 * 每个 tick 接收一批节点状态，逐条规则做 `DataPath` 取值与比较；`forSeconds`
 * 用状态机累计连续满足时长，冷却期内不重复发送，恢复时按配置发送恢复事件。
 */
public class AlarmEngine {
    private let rules: Array<AlarmRule>
    private let clock: Clock
    private let onEvent: (AlarmEvent) -> Unit
    private let cooldownMs: Int64
    private let recoverNotify: Bool
    private let missingThreshold: Int64
    private let expectKinds: Array<String>
    private let states = HashMap<String, RuleState>()
    private let mutedUntil = HashMap<String, Int64>()
    private let missing = MissingDataTracker()

    public init(rules: Array<AlarmRule>, clock: Clock, onEvent: (AlarmEvent) -> Unit,
        cooldownMs!: Int64 = 300000, recoverNotify!: Bool = true,
        missingThreshold!: Int64 = 2, expectKinds!: Array<String> = []) {
        this.rules = rules
        this.clock = clock
        this.onEvent = onEvent
        this.cooldownMs = cooldownMs
        this.recoverNotify = recoverNotify
        this.missingThreshold = missingThreshold
        this.expectKinds = expectKinds
    }

    /** 静音某条规则直到给定时间；静音只影响发送，不影响状态机推进。 */
    public func mute(rule: String, untilMs: Int64): Unit {
        let previous = match (mutedUntil.get(rule)) {
            case Some(value) => value
            case None => 0
        }
        if (untilMs > previous) {
            mutedUntil[rule] = untilMs
        }
    }

    /** 评估一批节点状态。 */
    public func evaluate(nodes: Array<NodeState>): Unit {
        let now = clock.nowMs()
        let batchNodes = HashSet<String>()
        let currentMissing = HashSet<String>()

        for (state in nodes) {
            batchNodes.add(state.node)
            evaluateMissing(state, now, currentMissing)
        }

        for (original in missing.collectRecovered(batchNodes, currentMissing)) {
            if (recoverNotify) {
                emit(AlarmEvent(AlarmEventType.RECOVERY, original.node, original.rule, original.kind,
                    original.level, None<Float64>, original.threshold, now,
                    '${original.message}，已恢复'))
            }
        }

        for (state in nodes) {
            if (state.status == NodeStatus.ONLINE) {
                evaluateRules(state, now, currentMissing)
            }
        }
    }

    private func evaluateMissing(state: NodeState, now: Int64, current: HashSet<String>): Unit {
        if (state.status == NodeStatus.OFFLINE) {
            if (state.consecutiveFailures >= missingThreshold) {
                let key = '${state.node}|node'
                current.add(key)
                let event = AlarmEvent(AlarmEventType.NODE_UNREACHABLE, state.node, "", "", "critical",
                    None<Float64>, 0.0, now,
                    '节点 ${state.node} 连续 ${state.consecutiveFailures} 次拉取失败，不可达')
                if (missing.raise(key, event)) {
                    emit(event)
                }
            }
            return
        }

        let snapshot = match (state.snapshot) {
            case Some(value) => value
            case None => return
        }

        for (kind in expectKinds) {
            var found = false
            for (agent in snapshot.agents) {
                if (agent.kind == kind) {
                    found = true
                    break
                }
            }
            if (!found) {
                let key = '${state.node}|kind|${kind}'
                current.add(key)
                let event = AlarmEvent(AlarmEventType.KIND_MISSING, state.node, "", kind, "warning",
                    None<Float64>, 0.0, now, '节点 ${state.node} 缺少监控项 ${kind}')
                if (missing.raise(key, event)) {
                    emit(event)
                }
            }
        }

        for (agent in snapshot.agents) {
            if (!agent.error.isEmpty()) {
                let key = '${state.node}|error|${agent.kind}'
                current.add(key)
                let event = AlarmEvent(AlarmEventType.PROBE_ERROR, state.node, "", agent.kind, "warning",
                    None<Float64>, 0.0, now,
                    '节点 ${state.node} 的监控项 ${agent.kind} 采集失败: ${agent.error}')
                if (missing.raise(key, event)) {
                    emit(event)
                }
            }
        }
    }

    private func evaluateRules(state: NodeState, now: Int64, current: HashSet<String>): Unit {
        let snapshot = match (state.snapshot) {
            case Some(value) => value
            case None => return
        }

        for (rule in rules) {
            var agent: ?ProbeAgentData = None
            for (candidate in snapshot.agents) {
                if (candidate.kind == rule.kind) {
                    agent = Some(candidate)
                }
            }
            match (agent) {
                case None =>
                    let key = '${state.node}|kind|${rule.kind}'
                    current.add(key)
                    let event = AlarmEvent(AlarmEventType.KIND_MISSING, state.node, rule.name, rule.kind,
                        rule.level, None<Float64>, rule.threshold, now,
                        '节点 ${state.node} 缺少监控项 ${rule.kind}（规则 ${rule.name}）')
                    if (missing.raise(key, event)) {
                        emit(event)
                    }
                case Some(data) =>
                    if (data.error.isEmpty()) {
                        match (valueOf(rule, data.dataJson)) {
                            case Some(value) => applyRule(rule, state.node, value, now)
                            case None => ()
                        }
                    }
            }
        }
    }

    private func valueOf(rule: AlarmRule, dataJson: String): ?Float64 {
        let root = match (jsonToData(dataJson)) {
            case Some(value) => value
            case None => return None<Float64>
        }

        var maximum: ?Float64 = None
        try {
            for (item in DataPath.solid(rule.path).get(root)) {
                match (item) {
                    case real: DataReal =>
                        let value = real.toFloat64()
                        maximum = match (maximum) {
                            case Some(current) => if (value > current) {
                                Some(value)
                            } else {
                                Some(current)
                            }
                            case None => Some(value)
                        }
                    case _ => ()
                }
            }
        } catch (_: Exception) {
            return None<Float64>
        }
        maximum
    }

    private func applyRule(rule: AlarmRule, node: String, value: Float64, now: Int64): Unit {
        let op = match (AlarmOp.parse(rule.op)) {
            case Some(value) => value
            case None => return
        }
        let key = '${node}|${rule.name}'
        let state = stateOf(key)
        let matched = op.matches(value, rule.threshold)

        if (matched) {
            if (state.since.isNone()) {
                state.since = Some(now)
            }
            let since = state.since.getOrThrow()
            let elapsed = now - since
            if (!state.firing && elapsed >= rule.forSeconds * 1000) {
                if (!isMuted(rule.name, now) && cooldownElapsed(state, now)) {
                    state.firing = true
                    state.lastSentAt = Some(now)
                    emit(AlarmEvent(AlarmEventType.FIRING, node, rule.name, rule.kind, rule.level,
                        Some(value), rule.threshold, now,
                        '${rule.name} 命中：${rule.kind} ${rule.path} 当前值 ${value}'))
                }
            }
        } else {
            let wasFiring = state.firing
            state.firing = false
            state.since = None
            if (wasFiring && !isMuted(rule.name, now) && recoverNotify) {
                emit(AlarmEvent(AlarmEventType.RECOVERY, node, rule.name, rule.kind, rule.level,
                    Some(value), rule.threshold, now,
                    '${rule.name} 已恢复：${rule.kind} ${rule.path} 当前值 ${value}'))
            }
        }
    }

    private func stateOf(key: String): RuleState {
        match (states.get(key)) {
            case Some(value) => value
            case None =>
                let created = RuleState()
                states[key] = created
                created
        }
    }

    private func cooldownElapsed(state: RuleState, now: Int64): Bool {
        match (state.lastSentAt) {
            case Some(last) => now - last >= cooldownMs
            case None => true
        }
    }

    private func isMuted(rule: String, now: Int64): Bool {
        match (mutedUntil.get(rule)) {
            case Some(until) => now < until
            case None => false
        }
    }

    private func emit(event: AlarmEvent): Unit {
        try {
            onEvent(event)
        } catch (_: Exception) {
            ()
        } catch (_: Error) {
            ()
        }
    }
}
