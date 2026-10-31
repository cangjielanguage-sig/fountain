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
package fountain::f_rule.flow

import std.collection.HashSet
import std.collection.concurrent.ConcurrentHashMap
import std.sync.{AtomicBool, AtomicInt64, Mutex}
import fountain::f_base.*
import fountain::f_collection.*
import fountain::f_egraph.base.{DummyEvent, ErrorEvent, Event, Task, TaskEvent}
import fountain::f_log.LoggerFactory
import fountain::f_ticktock.{DelayedPeriodic, DelayedTicktockTask, Ticktock}

/** 超时调度钩子；生产实现走 `f_ticktock`，测试可注入确定性调度器。 */
public interface JoinTimeoutScheduler {
    func available(): Bool
    func schedule(delay: Duration, action: () -> Unit): Bool
}

/** 一次性延迟任务：到期后只执行一次回调。 */
class JoinTimeoutTickTask <: DelayedTicktockTask {
    private let name_: String
    private let delay_: Duration
    private let action_: () -> Unit

    public init(name: String, delay: Duration, action: () -> Unit) {
        this.name_ = name
        this.delay_ = delay
        this.action_ = action
    }

    public prop delayedPeriodic: DelayedPeriodic {
        get() {
            DelayedPeriodic.FixedDelay
        }
    }

    public prop immediate: Bool {
        get() {
            false
        }
    }

    public prop delay: Duration {
        get() {
            delay_
        }
    }

    public prop once: Bool {
        get() {
            true
        }
    }

    public prop name: String {
        get() {
            name_
        }
    }

    public func execute(): Unit {
        action_()
    }
}

/** `Ticktock` 未初始化时 `available()` 为 false，`JoinTask` 据此退化为不超时。 */
class TicktockJoinScheduler <: JoinTimeoutScheduler {
    private static let seq = AtomicInt64(0)

    public func available(): Bool {
        Ticktock.getInstance(anyway: false).isSome()
    }

    public func schedule(delay: Duration, action: () -> Unit): Bool {
        match (Ticktock.getInstance(anyway: false)) {
            case Some(ticktock) =>
                ticktock.addOrReplaceDelayTask(JoinTimeoutTickTask(
                    "f_rule.join.${TicktockJoinScheduler.seq.fetchAdd(1) + 1}",
                    delay,
                    action
                ))
                true
            case None => false
        }
    }
}

/** 单个 session 的已到达分支集合；`arrived` 与元信息由 `lock` 保护。 */
class JoinBranchState {
    public let lock = Mutex()
    public let arrived = HashSet<String>()
    public var scheduled: Bool = false
    public var category: String = ""
    public var tag: String = ""
    public var ruleSetId: String = ""
    public var traceId: String = ""
}

/**
 * 多对一汇合（`doc/06-flow-orchestration.md` §4，P-06~P-09）。
 *
 * 状态键是 [RuleEnvelope] 的 session（不是 `Event.session`），因此 `AsyncFlow`
 * 在不同线程执行时也按会话隔离。同一分支重复到达幂等；到齐后立即清态，
 * 允许同一 session 发起下一轮。
 *
 * 配置 `timeout` 时，首个分支到达后通过 [JoinTimeoutScheduler] 起一次性延迟任务；
 * 到期后清态并把 `timeoutEvent`（缺省 `ErrorEvent`）交给 `timeoutSink`。调度器不可用
 * （`f_ticktock` 未初始化）时构造期记 WARN 并关闭超时，不静默丢分支状态。
 */
public class JoinTask <: Task {
    private static let log = LoggerFactory.getLogger<JoinTask>()

    private let name_: String
    private let branches_: Array<String>
    private let branchSet_: HashSet<String>
    private let output_: String
    private let timeout_: ?Duration
    private let timeoutEvent_: ?String
    private let scheduler_: ?JoinTimeoutScheduler
    private let timeoutSink_: ?(Event) -> Unit
    private let timeoutEnabled_ = AtomicBool(false)
    private let states_ = ConcurrentHashMap<String, JoinBranchState>()

    /**
     * @param name 任务名
     * @param branches 期望到达的分支事件名；全集到齐才继续
     * @param output 到齐后发出的事件名
     * @param timeout 可选超时
     * @param timeoutEvent 超时事件名，缺省发 `ErrorEvent`
     * @param scheduler 超时调度器；缺省走 `f_ticktock`
     * @param timeoutSink 超时事件出口；由 `RuleSetFlow` 接到 `flow.emit`
     */
    public init(name!: String, branches!: Array<String>, output!: String,
        timeout!: ?Duration = None, timeoutEvent!: ?String = None,
        scheduler!: ?JoinTimeoutScheduler = None, timeoutSink!: ?(Event) -> Unit = None) {
        this.name_ = name
        this.branches_ = branches
        this.branchSet_ = HashSet<String>(branches)
        this.output_ = output
        this.timeout_ = timeout
        this.timeoutEvent_ = timeoutEvent
        this.timeoutSink_ = timeoutSink
        let chosen = match (scheduler) {
            case Some(found) => found
            case None => TicktockJoinScheduler()
        }
        this.scheduler_ = Some(chosen)
        match (timeout) {
            case Some(_) =>
                if (chosen.available()) {
                    timeoutEnabled_.store(true)
                } else {
                    JoinTask.log.warn(
                        "JoinTask '${name_}' 配置了超时，但 f_ticktock 不可用；已退化为不超时"
                    )
                }
            case None => ()
        }
    }

    public prop name: String {
        get() {
            name_
        }
    }

    public prop acceptableEvents: Array<String> {
        get() {
            branches_
        }
    }

    public prop producingEvents: Array<String> {
        get() {
            [output_]
        }
    }

    /** 超时是否生效；调度器不可用或调度失败后为 false。 */
    public prop timeoutEnabled: Bool {
        get() {
            timeoutEnabled_.load()
        }
    }

    /** 当前持有状态的 session 数；到齐或超时后应归零。 */
    public func size(): Int64 {
        states_.size
    }

    public func exec(e: Event): Event {
        let envelope = RuleEnvelope.from(e)
        if (!branchSet_.contains(e.name)) {
            return DummyEvent.instance
        }
        let state = states_.computeIfAbsent(envelope.session) { JoinBranchState() }
        var complete = false
        var shouldSchedule = false
        synchronized(state.lock) {
            state.arrived.add(e.name)
            if (state.arrived.size == 1 && timeoutEnabled_.load() && !state.scheduled) {
                state.scheduled = true
                state.category = e.category
                state.tag = e.tag
                state.ruleSetId = envelope.ruleSetId
                state.traceId = envelope.traceId
                shouldSchedule = true
            }
            if (state.arrived.size == branchSet_.size) {
                state.arrived.clear()
                complete = true
            }
        }
        if (shouldSchedule && !complete) {
            scheduleTimeout(envelope.session)
        }
        if (!complete) {
            return DummyEvent.instance
        }
        let _ = states_.remove(envelope.session)
        TaskEvent(
            category: e.category,
            tag: e.tag,
            name: output_,
            data: RuleEnvelope(
                session: envelope.session,
                ruleSetId: envelope.ruleSetId,
                payload: "joined",
                traceId: envelope.traceId
            ),
            session: envelope.session
        )
    }

    private func scheduleTimeout(session: String): Unit {
        match ((scheduler_, timeout_)) {
            case (Some(scheduler), Some(delay)) =>
                let accepted = scheduler.schedule(delay, { => expire(session) })
                if (!accepted) {
                    timeoutEnabled_.store(false)
                    JoinTask.log.warn(
                        "JoinTask '${name_}' 注册超时任务失败（f_ticktock 未初始化）；已退化为不超时"
                    )
                }
            case _ => ()
        }
    }

    private func expire(session: String): Unit {
        let removed = match (states_.remove(session)) {
            case Some(state) => state
            case None => return
        }
        var category = ""
        var tag = ""
        var ruleSetId = ""
        var traceId = ""
        synchronized(removed.lock) {
            category = removed.category
            tag = removed.tag
            ruleSetId = removed.ruleSetId
            traceId = removed.traceId
            removed.arrived.clear()
        }
        let event = match (timeoutEvent_) {
            case Some(output) => TaskEvent(
                category: category,
                tag: tag,
                name: output,
                data: RuleEnvelope(session: session, ruleSetId: ruleSetId,
                    payload: "timeout", traceId: traceId),
                session: session
            )
            case None => ErrorEvent(
                category: category,
                tag: tag,
                message: "JoinTask '${name_}' 等待分支超时",
                session: session
            )
        }
        match (timeoutSink_) {
            case Some(sink) => sink(event)
            case None => ()
        }
    }
}
