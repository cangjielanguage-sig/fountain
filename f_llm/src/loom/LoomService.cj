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
import fountain::f_egraph.base.*

/** `loomExecute` 的返回：要么是预览，要么是澄清问题 */
public class LoomResult {
    public let status: String
    public let name: String
    public let planJson: String
    public let stepSources: HashMap<String, String>
    public let flowSource: String
    public let questions: ArrayList<ClarifyQuestion>

    public init(status: String, name: String, planJson!: String = '',
        stepSources!: HashMap<String, String> = HashMap<String, String>(), flowSource!: String = '',
        questions!: ArrayList<ClarifyQuestion> = ArrayList<ClarifyQuestion>()) {
        this.status = status
        this.name = name
        this.planJson = planJson
        this.stepSources = stepSources
        this.flowSource = flowSource
        this.questions = questions
    }

    public prop needsClarification: Bool {
        get() {
            status == 'clarifying'
        }
    }
}

/**
 * loom 的编排入口（§9.6「预览 → 确认 → 编译」）。
 *
 * - `confirm=false`：只调 Planner + CodeGen，落 `pending`，返回闭包原文（不编译）；
 * - `confirm=true`：按 name 取已存的 pending，编译步骤闭包，成功后标 `compiled`；
 * - 澄清：Planner 返回 `need_clarification` 时存 `clarifying`，不生成源码。
 *
 * 与工具层解耦：`LoomFunctions` 只是本类的薄封装，业务侧也可直接调用。
 */
public class LoomService {
    private let planner: Planner
    private let registry: LoomRegistry
    private let compiler: LoomCompiler

    public init(planner: Planner, registry: LoomRegistry, compiler!: ?LoomCompiler = None) {
        this.planner = planner
        this.registry = registry
        this.compiler = match (compiler) {
            case Some(value) => value
            case None => LoomCompiler()
        }
    }

    public func execute(request: LoomRequest, confirm!: Bool = false): LoomResult {
        if (confirm) {
            return confirmFlow(request.name)
        }
        let planned = planner.plan(request)
        if (planned.status == 'need_clarification') {
            let flow = LoomFlow(request.name, description: request.description)
            flow.mark(LoomStatus.CLARIFYING)
            flow.round = planned.round
            flow.questionsJson = questionsJson(planned.questions)
            flow.tools = join(request.tools)
            flow.mcps = join(request.mcps)
            registry.put(flow)
            // Supervisor 开启时同步登记（未安装则是无操作）
            Supervisor.tap(flow)
            return LoomResult('clarifying', request.name, questions: planned.questions)
        }
        let plan = planned.plan.getOrThrow()
        let generated = CodeGen.generate(plan)
        let flow = LoomFlow(request.name, description: request.description)
        flow.planJson = generated.planJson
        flow.flowSource = generated.flowSource
        flow.stepSources = generated.stepSources
        flow.round = plan.round
        flow.tools = join(request.tools)
        flow.mcps = join(request.mcps)
        flow.mark(LoomStatus.PENDING)
        registry.put(flow)
        // Supervisor 开启时同步登记（未安装则是无操作）
        Supervisor.tap(flow)
        LoomResult('pending', request.name, planJson: flow.planJson, stepSources: flow.stepSources,
            flowSource: flow.flowSource)
    }

    /** 编译已存的 pending 流程；失败保持 pending 并抛错（源码已可复现） */
    public func confirmFlow(name: String): LoomResult {
        let flow = match (registry.get(name)) {
            case Some(value) => value
            case None => throw LoomException('loom flow not found: ${name}')
        }
        let plan = Planner.parse(flow.planJson, LoomBootstrap.requestOf(flow))
        let target = plan.plan.getOrThrow()
        compiler.compileSteps(target)
        flow.mark(LoomStatus.COMPILED)
        registry.put(flow)
        // 编译成功即可被路由到（状态由 tap 一并带过去）
        Supervisor.tap(flow)
        LoomResult('compiled', name, planJson: flow.planJson, stepSources: flow.stepSources, flowSource: flow.flowSource)
    }

    /** 编译成功后可立即执行一次（§9.6 的「可选立即执行」） */
    public func executeNow(name: String, host: LoomHost, input: Event, parallel!: Bool = false): Event {
        let flow = match (registry.get(name)) {
            case Some(value) => value
            case None => throw LoomException('loom flow not found: ${name}')
        }
        if (flow.status != LoomStatus.COMPILED) {
            throw LoomException('loom flow is not compiled: ${name} (status=${flow.status})')
        }
        let planned = Planner.parse(flow.planJson, LoomBootstrap.requestOf(flow))
        let plan = planned.plan.getOrThrow()
        // 计划声明或调用方显式要求，任一为真就并发；默认同步
        LoomRunner(compiler: compiler).run(plan, host, input, parallel: plan.parallel || parallel)
    }

    public func delete(name: String): Bool {
        let removed = registry.remove(name)
        // 流程没了，路由也要摘掉，否则派发会指向一个不存在的流程
        Supervisor.untap(name)
        removed
    }

    public func status(name: String): String {
        match (registry.get(name)) {
            case Some(flow) => flow.status
            case None => ''
        }
    }

    private static func join(values: Array<String>): String {
        var text = ''
        for (item in values) {
            if (!text.isEmpty()) {
                text += ','
            }
            text += item
        }
        text
    }

    private static func questionsJson(questions: ArrayList<ClarifyQuestion>): String {
        var text = '['
        for (index in 0..questions.size) {
            if (index > 0) {
                text += ','
            }
            let item = questions[index]
            text += '{\"id\":${FlowPlan.jsonQuote(item.id)},\"question\":'
            text += '${FlowPlan.jsonQuote(item.question)},\"blocking\":${item.blocking}}'
        }
        text + ']'
    }
}
