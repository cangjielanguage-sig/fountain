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
import std.env.getVariable
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_egraph.base.*

import fountain::f_llm.llm.*

/**
 * 用例：用 loom 设计「深圳中考听说——信息获取-听短文回答问题」的评分提示词。
 *
 * 流程（5 个 llm 步骤，模型统一 `deepseek-flash`）：
 *
 * ```
 * criteria → draft → review → finalize → validate
 * ```
 *
 * - 每个步骤的 system 指令都是**纯任务描述**，不含角色设定/称呼/语气修饰；
 * - 步骤之间用 `{上一步 id.output}` 模板串联（由 `LoomHostApi` 在运行期替换）；
 * - 真实模型调用只在设置 `LOOM_REAL_LLM=1` 时执行，密钥由 f_llm 的模型配置提供，
 *   本文件不含任何鉴权信息；
 * - 默认用注入的假宿主跑通链路，保证 CI 不需要网络与密钥。
 */
@Test
class LoomPromptDesign_test {
    static let MODEL = 'deepseek-flash'
    /** 真实调用的开关：未设置时只验证链路结构 */
    static let REAL_FLAG = 'LOOM_REAL_LLM'

    /** 考试任务说明（与题面一致，占位符用拼接避免被当成插值） */
    static func taskSpec(): String {
        let text = '$' + '{text}'
        let question = '$' + '{question}'
        let answer = '$' + '{answer}'
        '## 任务\n考生将听到一篇短文和一个问题，考生说出自己认为正确的答案。\n'
            + '答对得 1 分，答错 0 分。\n\n'
            + '## 短文\n' + text + '\n\n'
            + '## 问题\n' + question + '\n\n'
            + '## 回答（语音识别结果）\n' + answer + '\n'
    }

    /** 真题样例：覆盖不同问句类型，并含一条错误答案用于校准 */
    static func samples(): String {
        '【样例 1】\n'
            + '文本：One night, I had a dream. It was about a future working day. '
            + 'In the dream, I become a manager. At 7:00 am, a robot cooks breakfast for me. '
            + 'Then I go to work by car. The car drives by itself.\n'
            + '问题：8. Who cooks breakfast for the speaker?\n'
            + '考生回答：A robot cooks breakfast for her.\n参考分：1\n\n'
            + '【样例 2】\n'
            + '文本：Have you heard of bike bus? It is a program started by some children in Italy. '
            + 'Every Friday morning you can see a large group of kids riding bikes to school together. '
            + 'Policemen also join the kids to make sure they are safe.\n'
            + '问题：7. Who started the "bike bus" programme?\n'
            + '考生回答：Children in Italy.\n参考分：1\n\n'
            + '【样例 3】\n'
            + '文本：We may see a new kind of little car in the streets in the future. '
            + 'The car is as small as a bike and it can carry four people. '
            + 'Instead of using gas, the car uses wind power.\n'
            + '问题：8. Which power does the car use?\n'
            + '考生回答：It uses gas.\n参考分：0\n'
    }

    /** 步骤 1：从考试说明里提炼可判定的评分要点 */
    static func criteriaSystem(): String {
        '分析以下英语听说评分任务，输出可判定的评分要点清单。\n'
            + '每条要点必须包含：判定条件、可接受的变体、典型反例。\n'
            + '不要添加角色设定、称呼或语气修饰，只输出分析内容。'
    }

    /** 步骤 2：写提示词草稿（保留占位符与 JSON 契约） */
    static func draftSystem(): String {
        let text = '$' + '{text}'
        let question = '$' + '{question}'
        let answer = '$' + '{answer}'
        '依据评分要点撰写自动评分提示词草稿。要求：\n'
            + '1. 保留 ' + text + '、' + question + '、' + answer + ' 三个占位符，不得改写；\n'
            + '2. 输出契约为单个 JSON 对象：{"score":0 或 1,"reason":"不超过 60 字"}；\n'
            + '3. 只依据短文与问题判定，不引入短文之外的事实；\n'
            + '4. 不含角色设定、称呼或情绪化措辞。'
    }

    /** 步骤 3：对抗式审查，只列问题与建议，不重写 */
    static func reviewSystem(): String {
        '审查提示词草稿，找出会导致误判的输入情形，至少覆盖：\n'
            + '- 语音识别噪声：同音词、漏词、重复、断句错误；\n'
            + '- 代词不一致：he/she、speaker/the speaker；\n'
            + '- 是非问句只回答 Yes/No；\n'
            + '- 同义或近义表达、语序不同；\n'
            + '- 部分正确（关键信息缺失）、时态/单复数错误但语义等价；\n'
            + '- 与短文冲突或答非所问。\n'
            + '逐条给出：问题、触发样例、可直接落地的修改建议。不要重写全文。'
    }

    /** 步骤 4：把审查意见合并成最终提示词 */
    static func finalizeSystem(): String {
        '把审查意见合并进草稿，输出最终提示词（Markdown）。\n'
            + '必须保留三个占位符与 JSON 输出契约；\n'
            + '不得出现角色设定、称呼或情绪化措辞；不得引用审查意见原文。'
    }

    /** 步骤 5：用最终提示词给样例打分并比对参考标签 */
    static func validateSystem(): String {
        '使用给定提示词对样例逐条评分，与参考标签比对，输出 Markdown 报告。\n'
            + '报告包含：表格（题号 / 参考分 / 预测分 / 是否一致 / 判定理由），'
            + '以及不一致项的可能原因。不要修改提示词本身。'
    }

    static func step(id: String, system: String, input: String): StepPlan {
        let item = StepPlan(id, 'llm')
        item.model = MODEL
        item.system = system
        item.input = input
        // 模型调用属于外部副作用步骤
        item.async = 'false'
        item.external = true
        item
    }

    /** 5 步线性流程；`persona` 留空，不引入任何人格 */
    static func promptDesignPlan(): FlowPlan {
        let plan = FlowPlan('shenzhen-listening-prompt')
        plan.persona = ''
        plan.notes = '为深圳中考听说「信息获取-听短文回答问题」生成评分提示词'

        plan.steps.add(step('criteria', criteriaSystem(), taskSpec()))
        plan.steps.add(step('draft', draftSystem(), '{criteria.output}'))
        plan.steps.add(step('review', reviewSystem(), '{draft.output}'))
        plan.steps.add(step('finalize', finalizeSystem(),
            '{draft.output}\n\n审查意见：\n{review.output}'))
        plan.steps.add(step('validate', validateSystem(),
            '{finalize.output}\n\n样例与参考标签：\n' + samples()))

        plan.edges.add(EdgePlan('criteria', 'draft'))
        plan.edges.add(EdgePlan('draft', 'review'))
        plan.edges.add(EdgePlan('review', 'finalize'))
        plan.edges.add(EdgePlan('finalize', 'validate'))
        plan
    }

    @TestCase
    func testPlanUsesDeepseekFlashAndHasNoPersona(): Unit {
        let plan = promptDesignPlan()
        plan.validate()
        @Expect(plan.steps.size, 5)
        @Expect(plan.persona, '')
        for(item in plan.steps){
            @Expect(item.model, MODEL)
        }
        // system 指令不得出现角色设定类措辞
        for(item in plan.steps){
            @Expect(item.system.contains('你是'), false)
            @Expect(item.system.contains('扮演'), false)
            @Expect(item.system.contains('作为一名'), false)
        }
    }

    @TestCase
    func testFlowChainsFiveStepsWithInjectedHost(): Unit {
        let plan = promptDesignPlan()
        let host = PromptDesignProbe()
        let start = StartEvent(category: 'loom', tag: 'prompt-design', name: 'start',
                               data: taskSpec())
        let out = LoomRunner().run(plan, host, start)

        @Expect(out.name, 'validate')
        @Expect(host.models.size, 5)
        for(model in host.models){
            @Expect(model, MODEL)
        }
        // 模板确实按链路上传：第 2 步收到了第 1 步的输出
        @Expect(host.inputs.size, 5)
        @Expect(host.inputs[1].contains('评分要点'), true)
        // 最后一步的输入包含最终提示词与样例
        @Expect(host.inputs[4].contains('样例与参考标签'), true)
    }

    @TestCase
    func testRealDeepseekRunWhenEnabled(): Unit {
        let enabled = match(getVariable(REAL_FLAG)){
            case Some(value) => value.trimAscii() == '1'
            case None => false
        }
        if(!enabled){
            // 未开启：只验证链路（见上一条用例），不发起真实调用
            return
        }
        let host = DefaultLoomHost(LoomPromptDesign_test.chatViaConfiguredLlm)
        let start = StartEvent(category: 'loom', tag: 'prompt-design', name: 'start',
                               data: taskSpec())
        let out = LoomRunner().run(promptDesignPlan(), host, start)
        @Expect(out.name, 'validate')
    }

    /** 真实调用：走 f_llm 已配置的模型（密钥由配置提供，不写进代码） */
    static func chatViaConfiguredLlm(model: String, system: String, input: String): String {
        let messages = ArrayList<ChatMessage>()
        if(!system.isEmpty()){
            messages.add(SystemMessage(system))
        }
        messages.add(UserMessage(input))
        let params = LLMToolParams(model: model, messages: messages)
        let response = LLM.chatByName(model, params)
        var text = ''
        for(item in response.messages){
            match(item as AssistantMessage){
                case Some(message) => text = message.content
                case None => ()
            }
        }
        text
    }
}

/** 记录每次模型调用的入参，返回带标记的文本，便于断言链路 */
class PromptDesignProbe <: LoomHost {
    public var models: ArrayList<String> = ArrayList<String>()
    public var inputs: ArrayList<String> = ArrayList<String>()

    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        ''
    }

    public func callLlm(model: String, system: String, input: String): String {
        models.add(model)
        inputs.add(input)
        '[${model}] ${system}\n${input}'
    }
}
