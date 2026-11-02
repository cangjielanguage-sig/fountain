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
import fountain::f_jit.*

/**
 * 步骤级 JIT（§9.4 的第一级）。
 *
 * 分工（受 f_jit 的当前能力约束）：
 * - `kind = jit`：纯计算步骤，JIT 编译 `{ e: Event => <语句序列>; <id>_result }`，
 *   返回值由宿主包装成事件；语句序列里**不能**出现宿主类（f_jit 不把静态类当类型解析）；
 * - `tool` / `mcp`：编译成 `{ args: String => loomCallTool(...) }`；
 * - `llm`：编译成 `{ input: String => loomCallLlm(...) }`。
 *
 * 流程级 lambda 由 `LoomRunner` 原生组装（步骤闭包已经 JIT 化，
 * 流程再套一层 JIT 只增加诊断复杂度）；`CodeGen.flowSource` 只作预览/落库原文。
 */
public class LoomCompiler {
    private let compiler: Compiler

    public init() {
        let instance = Compiler(CompileOptions(DummyDiagnosticsSink()))
        // 事件谱系：编译产物需要构造 Event 的参数类型
        JitHostRegistry.configure(instance)
        // 宿主能力（LLM / 工具 / Store）：注册后 JIT 步骤可按名字直接调用
        LoomJitBridge.install(instance)
        this.compiler = instance
    }

    /**
     * 编译单个步骤；返回的闭包可直接交给 `QueuedClosureTask` 作为任务体。
     *
     * 三类步骤都走 f_jit：
     * - `jit`：整段语句序列编译；
     * - `tool` / `mcp`：编译成 `{ args: String => loomCallTool(…) }`，模板替换留给原生侧；
     * - `llm`：编译成 `{ input: String => loomCallLlm(…) }`。
     */
    public func compileStep(step: StepPlan): (Event) -> Event {
        if(step.kind == 'jit'){
            return compileJit(step)
        }
        if(step.kind == 'tool' || step.kind == 'mcp'){
            return compileTool(step)
        }
        if(step.kind == 'llm'){
            return compileLlm(step)
        }
        throw LoomException('loom step kind is not executable: ${step.kind} (${step.id})')
    }

    public func compileSteps(plan: FlowPlan): HashMap<String, (Event) -> Event> {
        plan.validate()
        let result = HashMap<String, (Event) -> Event>()
        for(item in plan.steps){
            result[item.id] = compileStep(item)
        }
        result
    }

    /** jit 步骤的编译源码：语句序列 + 结果表达式（返回 String） */
    public static func jitSourceOf(step: StepPlan): String {
        '{ e: Event =>\n${step.input}\n${step.id}_result\n}'
    }

    private func compileJit(step: StepPlan): (Event) -> Event {
        let fn = compiler.compile(jitSourceOf(step))
        { e =>
            let value = fn.call<String>([e])
            LoomHostApi.taskEvent(e, step.id, value)
        }
    }

    /** 工具步骤的编译源码：入参已渲染，调用走注册进 f_jit 的 `loomCallTool` */
    public static func toolSourceOf(step: StepPlan): String {
        '{ args: String =>\n'
            + 'let ${step.id}_out = loomCallTool(${FlowPlan.jsonQuote(step.tool)}, args)\n'
            + '${step.id}_out\n}'
    }

    /** 模型步骤的编译源码：输入已渲染，调用走注册进 f_jit 的 `loomCallLlm` */
    public static func llmSourceOf(step: StepPlan): String {
        '{ input: String =>\n'
            + 'let ${step.id}_out = loomCallLlm(${FlowPlan.jsonQuote(step.model)}, '
            + '${FlowPlan.jsonQuote(step.system)}, input)\n'
            + '${step.id}_out\n}'
    }

    private func compileTool(step: StepPlan): (Event) -> Event {
        let fn = compiler.compile(toolSourceOf(step))
        { e =>
            let args = LoomHostApi.render(step.args, e)
            let value = fn.call<String>([args])
            LoomHostApi.taskEvent(e, step.id, value)
        }
    }

    private func compileLlm(step: StepPlan): (Event) -> Event {
        let fn = compiler.compile(llmSourceOf(step))
        { e =>
            let input = LoomHostApi.render(step.input, e)
            let value = fn.call<String>([input])
            LoomHostApi.taskEvent(e, step.id, value)
        }
    }

}
