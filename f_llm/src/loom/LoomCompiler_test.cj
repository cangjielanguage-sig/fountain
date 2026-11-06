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
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_egraph.base.*

@Test
class LoomCompiler_test {
    private func input(): Event {
        TaskEvent(category: 'c', tag: 't', name: 'in', data: 'in')
    }

    @TestCase
    func testCompilesJitStep(): Unit {
        let step = StepPlan('s1', 'jit')
        step.input = 'let s1_result = "computed"'

        let compiled = LoomCompiler().compileStep(step)
        let out = compiled(input())
        @Expect(out.name, 's1')
        match(out){
            case event: DataEvent => @Expect(event.tryGet<String>().getOrThrow(), 'computed')
            case _ => @Expect(false, true)
        }
    }

    /** jit 源码里的模板占位符必须编译期拒绝，而不是留成字面量 */
    @TestCase
    func testJitTemplatePlaceholderRejected(): Unit {
        let plan = FlowPlan('jit-template')
        let step = StepPlan('s1', 'jit')
        step.input = 'let s1_result = "{start.output}"'
        plan.steps.add(step)

        var message = ''
        try{
            let _ = LoomCompiler().compileSteps(plan)
        }catch(e: LoomException){
            message = e.message
        }
        @Expect(message.contains('jit'), true)
        @Expect(message.contains('template'), true)
    }

    @TestCase
    func testCompilesToolStepThroughHostApi(): Unit {
        let step = StepPlan('call', 'tool')
        step.tool = 'echo'
        step.args = '{"q":"hi"}'
        LoomHostApi.bind(FakeHost())
        try{
            let compiled = LoomCompiler().compileStep(step)
            let out = compiled(input())
            @Expect(out.name, 'call')
            match(out){
                case event: DataEvent => @Expect(event.tryGet<String>().getOrThrow(), '{"q":"hi"}')
                case _ => @Expect(false, true)
            }
        }finally{
            LoomHostApi.unbind()
        }
    }

    @TestCase
    func testCompilesAllSteps(): Unit {
        let plan = FlowPlan('p')
        let first = StepPlan('a', 'jit')
        first.input = 'let a_result = "A"'
        let second = StepPlan('b', 'jit')
        second.input = 'let b_result = "B"'
        plan.steps.add(first)
        plan.steps.add(second)

        let compiled = LoomCompiler().compileSteps(plan)
        @Expect(compiled.size, 2)
        @Expect(compiled['a'](input()).name, 'a')
        @Expect(compiled['b'](input()).name, 'b')
    }
    /** JIT 步骤直接调用注册进 f_jit 的宿主函数（LLM 桥） */
    @TestCase
    func testJitStepCallsRegisteredHostLlm(): Unit {
        LoomHostApi.bind(FakeHost())
        try{
            let step = StepPlan('s1', 'jit')
            step.input = 'let s1_result = loomCallLlm("m", "sys", "HELLO")'
            let fn = LoomCompiler().compileStep(step)
            let out = fn(StartEvent(category: 'loom', tag: 't', name: 'start', data: 'go'))
            match(out as DataEvent){
                case Some(event) => @Expect(event.tryGet<String>().getOrThrow(), 'HELLO')
                case None => @Expect(false, true)
            }
        }finally{
            LoomHostApi.unbind()
        }
    }
}

/** 最简宿主：render 原样返回，callTool 回显参数 */
class FakeHost <: LoomHost {
    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        argsJson
    }

    public func callLlm(model: String, system: String, input: String): String {
        input
    }
}
