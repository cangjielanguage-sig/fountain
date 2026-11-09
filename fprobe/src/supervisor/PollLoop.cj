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
package fountain::fprobe.supervisor

import std.collection.ArrayList
import std.sync.{AtomicBool, AtomicInt64}
import fountain::fprobe.collect.Clock
import fountain::fprobe.snapshot.ProbeSnapshot

/**
 * supervisor 对单个节点的拉取抽象。
 *
 * 生产实现包裹 `NodeRpcTransport`；用例注入脚本化替身，不打开真实端口。
 */
public interface NodeSource {
    prop name: String

    func collect(): ProbeSnapshot
}

/** 单节点一次拉取的结果；失败时 `snapshot` 为 `None`，由 `tick()` 决定保留旧值。 */
private class CollectOutcome {
    let node: String
    let snapshot: ?ProbeSnapshot
    let error: String

    init(node: String, snapshot: ?ProbeSnapshot, error: String) {
        this.node = node
        this.snapshot = snapshot
        this.error = error
    }

    func ok(): Bool {
        snapshot.isSome()
    }
}

/**
 * 多节点拉取循环（设计 D9 / spec「拉取循环」）。
 *
 * 每个 tick 对每个节点**一次** `collect()`，用 `spawn` 并发执行后收敛结果：
 * - 单节点失败只累加该节点的连续失败计数，其它节点照常更新；
 * - 失败不清空上一次成功的快照；
 * - 连续失败达到 `missingThreshold` 发不可达事件，恢复发恢复事件；
 * - 告警评估异常被隔离，不影响后续 tick。
 */
public class PollLoop {
    private let sources: Array<NodeSource>
    private let store: NodeStateStore
    private let clock: Clock
    private let intervalMs: Int64
    private let missingThreshold: Int64
    private let onEvent: (NodeEvent) -> Unit
    private let evaluator: (Array<NodeState>) -> Unit
    private let running = AtomicBool(true)
    private let ticks = AtomicInt64(0)

    public init(sources: Array<NodeSource>, store: NodeStateStore, clock: Clock, intervalMs: Int64,
        missingThreshold: Int64, onEvent: (NodeEvent) -> Unit, evaluator: (Array<NodeState>) -> Unit) {
        this.sources = sources
        this.store = store
        this.clock = clock
        this.intervalMs = intervalMs
        this.missingThreshold = missingThreshold
        this.onEvent = onEvent
        this.evaluator = evaluator
    }

    /** 常驻循环：每 `intervalMs` 一个 tick，直到 [stop]。 */
    public func run(): Unit {
        while (running.load()) {
            tick()
            clock.wait(intervalMs)
        }
    }

    /** 停止常驻循环；当前 tick 会完成后再退出。 */
    public func stop(): Unit {
        running.store(false)
    }

    /** 循环是否仍在运行；退出钩子用它断言 `stop()` 已生效。 */
    public func isRunning(): Bool {
        running.load()
    }

    /** 已完成的 tick 数。 */
    public func tickCount(): Int64 {
        ticks.load()
    }

    /** 执行一轮拉取、状态更新与告警评估。 */
    public func tick(): Unit {
        let now = clock.nowMs()
        let futures = Array<Future<CollectOutcome>>(sources.size) {i =>
            let source = sources[i]
            spawn {=> collectOne(source, now)}
        }

        let states = ArrayList<NodeState>()
        for (future in futures) {
            let outcome = future.get()
            let previous = store.get(outcome.node)
            let previousFailures = match (previous) {
                case Some(state) => state.consecutiveFailures
                case None => 0
            }
            let retained = match (previous) {
                case Some(state) => state.snapshot
                case None => None<ProbeSnapshot>
            }
            let snapshot = match (outcome.snapshot) {
                case Some(value) => Some(value)
                case None => retained
            }
            let failures = if (outcome.ok()) {
                0
            } else {
                previousFailures + 1
            }
            let status = if (outcome.ok()) {
                NodeStatus.ONLINE
            } else {
                NodeStatus.OFFLINE
            }
            let state = NodeState(outcome.node, status, failures, snapshot, outcome.error, now)
            store.update(state)
            states.add(state)

            if (!outcome.ok() && failures == missingThreshold) {
                publish(NodeEvent(NodeEventType.UNREACHABLE, outcome.node, failures, now,
                    '节点 ${outcome.node} 连续 ${failures} 次拉取失败，不可达'))
            }
            if (outcome.ok() && previousFailures >= missingThreshold) {
                publish(NodeEvent(NodeEventType.RECOVERED, outcome.node, 0, now,
                    '节点 ${outcome.node} 已恢复（此前连续失败 ${previousFailures} 次）'))
            }
        }

        ticks.fetchAdd(1)
        let batch = states.toArray()
        try {
            evaluator(batch)
        } catch (e: Exception) {
            eprintln('fprobe supervisor: 告警评估失败: ${e.message}')
        } catch (e: Error) {
            eprintln('fprobe supervisor: 告警评估失败: ${e.message}')
        }
    }

    private func collectOne(source: NodeSource, at: Int64): CollectOutcome {
        try {
            CollectOutcome(source.name, Some(source.collect()), "")
        } catch (e: Exception) {
            CollectOutcome(source.name, None<ProbeSnapshot>, e.message)
        } catch (e: Error) {
            CollectOutcome(source.name, None<ProbeSnapshot>, e.message)
        }
    }

    private func publish(event: NodeEvent): Unit {
        try {
            onEvent(event)
        } catch (e: Exception) {
            eprintln('fprobe supervisor: 节点事件发布失败: ${e.message}')
        } catch (e: Error) {
            eprintln('fprobe supervisor: 节点事件发布失败: ${e.message}')
        }
    }
}
