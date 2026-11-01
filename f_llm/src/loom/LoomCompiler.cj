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
 * - `tool` / `mcp` / `llm`：不走 JIT，直接用宿主原生闭包调 `LoomHostApi`
 *   （工具/模型的入参是对象、返回是字符串，JIT 化没有收益，反而要注册一堆宿主类型）。
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
        this.compiler = instance
    }

    /** 编译单个步骤；返回的闭包可直接交给 `QueuedClosureTask` 作为任务体 */
    public func compileStep(step: StepPlan): (Event) -> Event {
        if(step.kind == 'jit'){
            return compileJit(step)
        }
        return { e => nativeStep(step, e) }
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
            TaskEvent(category: e.category, tag: e.tag, name: step.id, data: value)
        }
    }

    /** 工具/模型步骤：宿主原生执行，模板替换与调用都交给 `LoomHostApi` */
    private static func nativeStep(step: StepPlan, e: Event): Event {
        let value = if(step.kind == 'tool' || step.kind == 'mcp'){
            let args = LoomHostApi.render(step.args, e)
            LoomHostApi.callTool(step.tool, args)
        }else{
            let input = LoomHostApi.render(step.input, e)
            LoomHostApi.callLlm(step.model, step.system, input)
        }
        TaskEvent(category: e.category, tag: e.tag, name: step.id, data: value)
    }
}
