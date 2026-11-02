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

import fountain::f_egraph.base.*

/**
 * 运行期入口：一段任务描述 →（指定模型拆解）→ 步骤闭包 → 流程 → 可重复执行的程序。
 *
 * 用法：
 *
 * ```cangjie
 * let agent = LoomAgent({ system, user => deepseek(system, user) }, plannerModel: 'deepseek-flash')
 * let program = agent.compile('为…生成评分提示词', name: 'prompt-design')
 * let result = program.run(host, StartEvent(...))
 * ```
 *
 * 与 `LoomService` 的区别：`LoomService` 面向「预览 → 确认 → 落库」的交互流程，
 * 本类面向「拿到描述就地编译、就地执行」，不落库。
 */
public class LoomAgent {
    private let chat: (String, String, String) -> String
    private let plannerModel: String
    private let compiler: LoomCompiler

    /** 开发者指定的编排提示词；为空时用内置的 `Prompts.PLANNER_SYSTEM` */
    private let instructions: String

    public init(chat: (String, String, String) -> String, plannerModel!: String = '',
                instructions!: String = '') {
        this.chat = chat
        this.plannerModel = plannerModel
        this.instructions = instructions
        this.compiler = LoomCompiler()
    }

    /**
     * 拆解并编译。
     *
     * @param description 自然语言任务描述
     * @param name 流程名（为空时用 `loom-<序号>`）
     * @throws LoomException 计划非法、或模型返回澄清请求
     */
    public func compile(description: String, name!: String = ''): LoomProgram {
        let flowName = if(name.isEmpty()){ 'loom-${LoomAgent.nextSeq()}' }else{ name }
        let request = LoomRequest(flowName, description, model: plannerModel)
        let planned = Planner({ system, user => chat(plannerModel, system, user) },
                              systemPrompt: instructions).plan(request)
        if(planned.status == 'need_clarification'){
            throw LoomException('loom agent needs clarification: ${description}')
        }
        let plan = planned.plan.getOrThrow()
        plan.validate()

        let generated = CodeGen.generate(plan)
        let steps = compiler.compileSteps(plan)
        LoomProgram(plan, generated, steps, compiler)
    }

    private static let seqMutex = Mutex()
    private static var seq: Int64 = 0

    private static func nextSeq(): Int64 {
        let box = AgentSeqBox()
        synchronized(seqMutex){
            seq++
            box.value = seq
        }
        box.value
    }
}

class AgentSeqBox {
    public var value: Int64 = 0
}

/** 已编译的流程：持有计划、源码、每步的 JIT 闭包，可重复执行 */
public class LoomProgram {
    public let plan: FlowPlan
    public let flowSource: String
    public let stepSources: HashMap<String, String>
    private let steps: HashMap<String, (Event) -> Event>
    private let compiler: LoomCompiler

    public init(plan: FlowPlan, generated: GeneratedFlow,
                steps: HashMap<String, (Event) -> Event>, compiler: LoomCompiler) {
        this.plan = plan
        this.flowSource = generated.flowSource
        this.stepSources = generated.stepSources
        this.steps = steps
        this.compiler = compiler
    }

    public prop name: String {
        get() {
            plan.name
        }
    }

    /** 步骤数量（= 计划里的步骤数） */
    public prop stepCount: Int64 {
        get() {
            Int64(steps.size)
        }
    }

    /**
     * 执行流程。
     *
     * 每个步骤都是 `f_jit` 编译出的闭包（`JitFunction` 调用），按计划的边由 Flow 组织；
     * `flowSource` 是同一份流程的可读源码，用于审计与落库。
     */
    public func run(host: LoomHost, input: Event, parallel!: Bool = false): Event {
        LoomRunner(compiler: compiler).runCompiled(plan, steps, host, input,
                                                  parallel: parallel)
    }
}
