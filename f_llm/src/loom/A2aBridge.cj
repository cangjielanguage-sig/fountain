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

import fountain::f_a2a.*
import fountain::f_data.*
import fountain::f_llm.config.LLMConfig
import fountain::f_log.*

/**
 * Supervisor 的 A2A 适配器：把 `dispatch(prompt)` 的结果翻译成任务终态。
 *
 * 协议概念只留在这一层，`Supervisor` 本身仍然「只认自然语言、只回自己的 outcome」。
 */
public class SupervisorAgent <: A2aExecutor {
    private let dispatch: (String) -> SupervisorOutcome

    /** 生产用法：走全局 Supervisor */
    public init() {
        this.dispatch = { prompt =>
            match (Supervisor.current()) {
                case Some(supervisor) => supervisor.dispatch(prompt)
                case None => SupervisorOutcome(SupervisorOutcome.NO_USABLE,
                    message: 'loom supervisor is not installed')
            }
        }
    }

    /** 测试用法：注入 dispatch */
    init(dispatch: (String) -> SupervisorOutcome) {
        this.dispatch = dispatch
    }

    public func execute(task: A2aTask, message: A2aMessage): A2aExecutionResult {
        SupervisorAgent.map(dispatch(message.text()))
    }

    /**
     * outcome → A2A 状态。
     *
     * `noUsableFlow` 映射成 `failed` 而不是「协议拒绝」：这不是「代理拒绝执行」，
     * 而是「当前没有能干的流程」，客户端换个说法重试更自然。
     */
    public static func map(outcome: SupervisorOutcome): A2aExecutionResult {
        let text = if (!outcome.message.isEmpty()) {
            outcome.message
        } else {
            outcome.flow
        }
        if (outcome.kind == SupervisorOutcome.DISPATCHED || outcome.kind == SupervisorOutcome.CREATED) {
            return A2aExecutionResult.done(text)
        }
        if (outcome.kind == SupervisorOutcome.CLARIFYING) {
            return A2aExecutionResult.input(text)
        }
        A2aExecutionResult.failed(text)
    }
}

/** 开启 A2A 服务：默认关闭，装配后按 `llm_a2aEnabled` 触发一次 */
public class LoomA2a {
    private static let mutex = Mutex()
    private static var started = false
    private static var lastServer: ?A2aServer = None

    private init() {
    }

    /** 开关关闭时什么都不做；返回是否注册了服务 */
    public static func startIfEnabled(card!: ?A2aAgentCard = None,
                                      executor!: ?A2aExecutor = None): Bool {
        if (!LLMConfig.a2aEnabled()) {
            return false
        }
        synchronized(mutex) {
            if (started) {
                return true
            }
            started = true
        }
        let chosenCard = match (card) {
            case Some(value) => value
            case None => defaultCard()
        }
        let chosenExecutor: A2aExecutor = match (executor) {
            case Some(value) => value
            case None => SupervisorAgent()
        }
        let server = A2aServer(chosenCard, chosenExecutor)
        server.register()
        synchronized(mutex) {
            lastServer = Some(server)
        }
        LoggerFactory.getLogger<LoomA2a>().info('loom a2a enabled: ${chosenCard.url}')
        true
    }

    /** 最近一次注册的服务（测试与运维自查） */
    public static func server(): ?A2aServer {
        synchronized(mutex) {
            lastServer
        }
    }

    /** 测试用：复位「已启动」标志（不注销已注册的方法） */
    public static func reset(): Unit {
        synchronized(mutex) {
            started = false
            lastServer = None
        }
    }

    public static func defaultCard(): A2aAgentCard {
        A2aAgentCard(name: 'loom-supervisor', description: 'loom 流程调度智能体',
            url: 'http://127.0.0.1/rpc/a2a')
    }
}

/** Supervisor 侧的 A2A 客户端：只补「发一句话、取回正文」这件 f_llm 关心的事 */
public class LoomA2aClient {
    private let send: (String, String) -> A2aTask

    public init() {
        this.send = { url, text =>
            let client = A2aClient(url)
            let parts = ArrayList<A2aPart>()
            parts.add(A2aPart(text: text))
            try {
                client.send(A2aMessage(parts: parts))
            } finally {
                client.close()
            }
        }
    }

    /** 测试用法：注入发送函数 */
    init(send: (String, String) -> A2aTask) {
        this.send = send
    }

    /** 发一句话，返回对方任务的第一个文本产物 */
    public func ask(url: String, text: String): String {
        let task = send(url, text)
        for (artifact in task.artifacts) {
            for (part in artifact.parts) {
                if (part.kind == 'text' && !part.text.isEmpty()) {
                    return part.text
                }
            }
        }
        throw LoomException('a2a ask returned no text: task=${task.id}, status=${task.status}')
    }
}
