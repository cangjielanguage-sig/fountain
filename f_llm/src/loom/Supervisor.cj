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
package fountain::f_llm.loom

import std.collection.*
import std.sync.*
import std.time.*
import fountain::f_data.*
import fountain::f_egraph.base.*
import fountain::f_llm.config.LLMConfig

/** Supervisor 中的一条路由：流程名 ↔ 唯一的 Supervisor 事件名 */
public class SupervisorRoute {
    public let name: String
    public let description: String
    public let event: String
    public let status: String

    public init(name: String, description: String, event: String, status: String) {
        this.name = name
        this.description = description
        this.event = event
        this.status = status
    }
}

/** 一次派发的结果：由谁执行、走哪个事件、产出是什么 */
public class SupervisorOutcome {
    public static const DISPATCHED = 'dispatched'
    public static const CREATED = 'created'
    public static const NO_USABLE = 'noUsableFlow'
    public static const CLARIFYING = 'clarifying'

    public let kind: String
    public let flow: String
    public let event: String
    public let message: String
    public let result: ?Event

    public init(kind: String, flow!: String = '', event!: String = '', message!: String = '', result!: ?Event = None) {
        this.kind = kind
        this.flow = flow
        this.event = event
        this.message = message
        this.result = result
    }
}

/**
 * 流程路由表：每个流程对应一个唯一的 Supervisor 事件名（`sv/<流程名>`）。
 *
 * 路由表在进程内，不持久化——重启时由 `LoomRegistry` 里的流程重新播种，
 * 避免「表里有、库里没有」的双份真相。
 */
public class Supervisor {
    /** Supervisor 事件前缀：与 `loom/<name>#<seq>` 的流程 tag 区分开 */
    private static let EVENT_PREFIX = 'sv/'

    private static let staticMutex: Mutex = Mutex()
    private static var installed: ?Supervisor = None

    /** 没有可用流程时的固定文案（规格里写死，便于调用方直接展示） */
    private static let NO_USABLE_MESSAGE = '没有可完成此工作的流程'

    private let mutex: Mutex = Mutex()
    private let table: ArrayList<SupervisorRoute> = ArrayList<SupervisorRoute>()

    private var serviceRef: ?LoomService = None
    private var hostRef: ?LoomHost = None
    private var chatRef: ?(String, String) -> String = None
    /** 自动新建流程的命名时钟（秒级），测试可注入固定值 **/
    private var clockRef: ?() -> Int64 = None

    public init() {
    }

    /**
     * 安装单例，并用现有流程播种路由表（启动时从存储恢复的流程由装配方传进来）。
     */
    public static func install(service: LoomService, host: LoomHost, chat: (String, String) -> String,
        flows!: ArrayList<LoomFlow> = ArrayList<LoomFlow>(), clock!: () -> Int64 = {
            => DateTime.now().toUnixTimeStamp().toSeconds()
        }): Supervisor {
        let supervisor = Supervisor()
        supervisor.serviceRef = Some(service)
        supervisor.hostRef = Some(host)
        supervisor.chatRef = Some(chat)
        supervisor.clockRef = Some(clock)
        synchronized(staticMutex) {
            installed = Some(supervisor)
        }
        for (flow in flows) {
            let _ = supervisor.register(flow.name, flow.description, status: flow.status)
        }
        supervisor
    }

    /**
     * 流程状态变化时由 `LoomService` 调过来；未安装时是纯无操作。
     *
     * 澄清态没有源码、也无法执行，不登记——它等回答补全后走 pending → compiled 再进来。
     */
    public static func tap(flow: LoomFlow): Unit {
        if (flow.status == LoomStatus.CLARIFYING) {
            return
        }
        match (current()) {
            case Some(supervisor) => let _ = supervisor.register(flow.name, flow.description, status: flow.status)
            case None => ()
        }
    }

    /** 流程删除时由 `LoomService` 调过来；未安装时是纯无操作 */
    public static func untap(name: String): Unit {
        match (current()) {
            case Some(supervisor) => let _ = supervisor.unregister(name)
            case None => ()
        }
    }

    public static func current(): Option<Supervisor> {
        var value: ?Supervisor = None
        synchronized(staticMutex) {
            value = installed
        }
        value
    }

    public static func reset(): Unit {
        synchronized(staticMutex) {
            installed = None
        }
    }

    /**
     * 接收一段描述：交给模型选流程，命中就派发执行。
     *
     * 选路阶段任何异常（模型不可用、返回非法 JSON）都按「没有可用流程」处理——
     * 选路失败不该让调用方拿到异常；派发阶段的执行失败则原样抛出。
     */
    public func dispatch(prompt: String): SupervisorOutcome {
        let service = match (serviceRef) {
            case Some(value) => value
            case None => return SupervisorOutcome(SupervisorOutcome.NO_USABLE, message: NO_USABLE_MESSAGE)
        }
        let host = match (hostRef) {
            case Some(value) => value
            case None => return SupervisorOutcome(SupervisorOutcome.NO_USABLE, message: NO_USABLE_MESSAGE)
        }
        let chat = match (chatRef) {
            case Some(value) => value
            case None => return SupervisorOutcome(SupervisorOutcome.NO_USABLE, message: NO_USABLE_MESSAGE)
        }
        let candidates = routable()
        var reply = ''
        try {
            reply = chat('', routerPrompt(prompt, candidates))
        } catch (e: Exception) {
            return SupervisorOutcome(SupervisorOutcome.NO_USABLE, message: NO_USABLE_MESSAGE)
        }
        let chosen = match (pickFlow(reply, candidates)) {
            case Some(name) => name
            case None => return onNoUsable(prompt, service, host)
        }
        // 路由表可能落后于流程库（比如刚被改回 pending）：派发前再确认一次
        if (service.status(chosen) != LoomStatus.COMPILED) {
            return SupervisorOutcome(SupervisorOutcome.NO_USABLE, message: NO_USABLE_MESSAGE)
        }
        let event = Supervisor.eventName(chosen)
        let result = service.executeNow(chosen, host,
            StartEvent(category: 'supervisor', tag: chosen, name: event, data: prompt))
        SupervisorOutcome(SupervisorOutcome.DISPATCHED, flow: chosen, event: event, result: Some(result))
    }

    /**
     * 没有可用流程时的两种处置：直接返回固定文案，或按配置自动编排一条新流程并执行。
     *
     * 自动新建只在 `llm_loomOnNoUsable=true`（且 Supervisor 已开启）时发生——
     * 开关判定放在 `LLMConfig.loomOnNoUsable()` 里，这里不重复判断。
     */
    private func onNoUsable(prompt: String, service: LoomService, host: LoomHost): SupervisorOutcome {
        if (!LLMConfig.loomOnNoUsable()) {
            return SupervisorOutcome(SupervisorOutcome.NO_USABLE, message: NO_USABLE_MESSAGE)
        }
        let name = nextFlowName(service)
        var preview: ?LoomResult = None
        try {
            preview = Some(service.execute(LoomRequest(name, prompt, dryRun: false)))
        } catch (e: Exception) {
            preview = None
        }
        let created = match (preview) {
            case Some(value) => value
            case None => return SupervisorOutcome(SupervisorOutcome.NO_USABLE, message: NO_USABLE_MESSAGE)
        }
        // 需要澄清：不登记、不执行，把问题交回调用方
        if (created.status == LoomStatus.CLARIFYING) {
            return SupervisorOutcome(SupervisorOutcome.CLARIFYING, flow: name, message: '需要补充信息后才能创建流程')
        }
        let _ = service.confirmFlow(name)
        let _ = register(name, prompt, status: service.status(name))
        let event = Supervisor.eventName(name)
        let result = service.executeNow(name, host,
            StartEvent(category: 'supervisor', tag: name, name: event, data: prompt))
        SupervisorOutcome(SupervisorOutcome.CREATED, flow: name, event: event, result: Some(result))
    }

    /** 自动新建流程的名字：`auto-<秒级时间戳>`，撞名就顺延 `-2`、`-3`… */
    private func nextFlowName(service: LoomService): String {
        let now = match (clockRef) {
            case Some(value) => value()
            case None => DateTime.now().toUnixTimeStamp().toSeconds()
        }
        let base = 'auto-${now}'
        var candidate = base
        var index = 2
        while (!service.status(candidate).isEmpty()) {
            candidate = '${base}-${index}'
            index++
        }
        candidate
    }

    /** 选路提示词：名称 / 描述 / 事件名三件套 + 需求原文 */
    private static func routerPrompt(prompt: String, candidates: ArrayList<SupervisorRoute>): String {
        var text = '你是流程调度员。判断下面的需求应由哪个流程完成；没有把握时返回空。\n可用流程：\n'
        if (candidates.isEmpty()) {
            text += '（当前没有可执行的流程）\n'
        } else {
            for (route in candidates) {
                text += '- 名称：${route.name}\n  描述：${route.description}\n  事件：${route.event}\n'
            }
        }
        text += '\n需求：${prompt}\n只输出 JSON：{\"flow\":\"<名称>\"}；没有合适的流程输出 {\"flow\":\"\"}'
        text
    }

    /** 解析模型的选路结果；非 JSON、缺字段、空名、不在候选内一律视为「没选中」 */
    private static func pickFlow(reply: String, candidates: ArrayList<SupervisorRoute>): Option<String> {
        let trimmed = Planner.stripFence(reply)
        if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
            return None
        }
        var name = ''
        try {
            let args = JsonValue.fromStr(trimmed).asObject()
            match (args.get('flow')) {
                case Some(value) => match (value as JsonString) {
                    case Some(text) => name = text.value
                    case None => name = ''
                }
                case None => name = ''
            }
        } catch (e: Exception) {
            return None
        }
        if (name.trimAscii().isEmpty()) {
            return None
        }
        for (route in candidates) {
            if (route.name == name) {
                return Some(name)
            }
        }
        None
    }

    /** 流程名 → Supervisor 事件名；纯派生，天然唯一且随改名同步 */
    public static func eventName(name: String): String {
        EVENT_PREFIX + name
    }

    /**
     * 登记一条路由；同名流程幂等（描述与状态按最新一次更新）。
     *
     * @throws LoomException 流程名为空
     */
    public func register(name: String, description: String, status!: String = LoomStatus.COMPILED): ?SupervisorRoute {
        if (name.trimAscii().isEmpty()) {
            throw LoomException('loom supervisor route name must not be blank')
        }
        let route = SupervisorRoute(name, description, Supervisor.eventName(name), status)
        synchronized(mutex) {
            var found = -1
            for (index in 0..table.size) {
                if (table[index].name == name) {
                    found = index
                    break
                }
            }
            if (found >= 0) {
                table[found] = route
            } else {
                table.add(route)
            }
        }
        Some(route)
    }

    public func unregister(name: String): Bool {
        var removed = false
        synchronized(mutex) {
            var found = -1
            for (index in 0..table.size) {
                if (table[index].name == name) {
                    found = index
                    break
                }
            }
            if (found >= 0) {
                table.remove(at: found)
                removed = true
            }
        }
        removed
    }

    /** 全量路由（含未编译流程），供观测与初始化后检查 */
    public func routes(): ArrayList<SupervisorRoute> {
        let copy = ArrayList<SupervisorRoute>()
        synchronized(mutex) {
            for (route in table) {
                copy.add(route)
            }
        }
        copy
    }

    /** 选路候选：只把可执行的流程交给模型 */
    public func routable(): ArrayList<SupervisorRoute> {
        let copy = ArrayList<SupervisorRoute>()
        synchronized(mutex) {
            for (route in table) {
                if (route.status == LoomStatus.COMPILED) {
                    copy.add(route)
                }
            }
        }
        copy
    }

    public func eventOf(name: String): Option<String> {
        var event: Option<String> = None
        synchronized(mutex) {
            for (route in table) {
                if (route.name == name) {
                    event = Some(route.event)
                    break
                }
            }
        }
        event
    }
}
