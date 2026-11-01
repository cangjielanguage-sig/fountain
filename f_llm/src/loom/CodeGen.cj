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

/**
 * 生成期的运行时宿主：生成的步骤源码只依赖这四个方法。
 *
 * 具体实现由 `LoomRunner`（执行）与测试替身提供；把它抽成接口是为了让
 * 「生成的源码」与「宿主实现」解耦，CodeGen 本身保持纯函数、可单测。
 */
public interface LoomHost {
    /** 把 `{step.output}` 模板替换成上一步结果 */
    func render(template: String, e: Event): String
    /** 调用已注册的工具（FunctionMediator / MCP） */
    func callTool(name: String, argsJson: String): String
    /** 调用 LLM */
    func callLlm(model: String, system: String, input: String): String
}

/** 生成产物：计划 JSON + 每步源码 + 流程源码（都不编译，供预览/落库） */
public class GeneratedFlow {
    public let planJson: String
    public let stepSources: HashMap<String, String>
    public let flowSource: String

    public init(planJson: String, stepSources: HashMap<String, String>, flowSource: String) {
        this.planJson = planJson
        this.stepSources = stepSources
        this.flowSource = flowSource
    }
}

/**
 * 计划 → 仓颉源码（§9.4 的两级 JIT 的第一半）。
 *
 * 这里只生成**闭包原文**，不编译：编译失败时要把原文原样返回给开发者定位。
 * 步骤体固定形参 `e: Event`、返回 `Event`；流程体无参，步骤通过 `LoomHostApi` 调宿主。
 */
public class CodeGen {
    private init() {
    }

    public static func generate(plan: FlowPlan, category!: String = 'loom'): GeneratedFlow {
        plan.validate()
        let steps = HashMap<String, String>()
        for(item in plan.steps){
            steps[item.id] = stepSource(item)
        }
        GeneratedFlow(plan.toJson(), steps, flowSource(plan, category: category))
    }

    /** 单个步骤的语句序列（形参 `e: Event`，返回 `Event`） */
    public static func stepSource(step: StepPlan): String {
        var text = '// step ${step.id} (${step.kind})\n'
        if(step.kind == 'tool' || step.kind == 'mcp'){
            text += 'let ${step.id}_args = LoomHostApi.render(${jsonQuote(step.args)}, e)\n'
            text += 'let ${step.id}_out = LoomHostApi.callTool(${jsonQuote(step.tool)}, ${step.id}_args)\n'
        }else if(step.kind == 'llm'){
            text += 'let ${step.id}_in = LoomHostApi.render(${jsonQuote(step.input)}, e)\n'
            text += 'let ${step.id}_out = LoomHostApi.callLlm(${jsonQuote(step.model)}, '
            text += '${jsonQuote(step.system)}, ${step.id}_in)\n'
        }else{
            // jit / http：素材由计划里的 input 语句片段给出，原样内联
            text += '${step.input}\n'
            text += 'let ${step.id}_out = ${step.id}_result\n'
        }
        text += 'LoomHostApi.taskEvent(e, ${jsonQuote(step.id)}, '
        text += '${step.id}_out)'
        text
    }

    /**
     * 流程级源码：无参 lambda，步骤体通过 `LoomHostApi` 调宿主。
     *
     * 有异步步骤用 `AsyncFlow`，否则 `ImmediateFlow`（§9.5：jit 默认同步，其余默认异步）。
     */
    public static func flowSource(plan: FlowPlan, category!: String = 'loom'): String {
        let async = hasAsync(plan)
        let flowType = if(async){ 'AsyncFlow' }else{ 'ImmediateFlow' }
        let first = firstStep(plan)
        var text = '// loom flow: ${plan.name}\n'
        text += '{ =>\n'
        text += '    let flow = ${flowType}(category: ${jsonQuote(category)}, tag: ${jsonQuote(plan.name)})\n'
        if(!first.isEmpty()){
            text += '    flow.registerStart(category: ${jsonQuote(category)}, tag: ${jsonQuote(plan.name)}, '
            text += 'eventName: ${jsonQuote(first)})\n'
        }
        for(item in plan.steps){
            text += '    flow.registerTask(${jsonQuote(item.id)}, { e =>\n'
            for(line in stepSource(item).split('\n')){
                text += '        ${line}\n'
            }
            text += '    })\n'
        }
        text += '    flow.registerEnd(category: ${jsonQuote(category)}, tag: ${jsonQuote(plan.name)})\n'
        text += '    flow.start("")\n'
        text += '    flow.get()\n'
        text += '}'
        text
    }

    /** 有显式 async=true，或 auto 且不是纯计算的 jit */
    public static func hasAsync(plan: FlowPlan): Bool {
        for(item in plan.steps){
            if(item.async == 'true'){
                return true
            }
            if(item.async == 'auto' && item.kind != 'jit'){
                return true
            }
        }
        false
    }

    /** 没有入边的第一个步骤（起点） */
    private static func firstStep(plan: FlowPlan): String {
        let targets = HashMap<String, Bool>()
        for(edge in plan.edges){
            targets[edge.to] = true
        }
        for(item in plan.steps){
            if(!targets.contains(item.id)){
                return item.id
            }
        }
        if(plan.steps.size > 0){
            return plan.steps[0].id
        }
        ''
    }

    private static func jsonQuote(text: String): String {
        FlowPlan.jsonQuote(text)
    }
}
