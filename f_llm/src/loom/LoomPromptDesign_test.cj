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
import std.env.getVariables
import std.fs.{File, OpenMode, exists}
import std.io.StringReader
import std.unittest.*
import std.unittest.testmacro.*

import fountain::f_egraph.base.*
import fountain::f_llm.llm.*
import fountain::f_llm.model.po.*

/**
 * 用 [LoomAgent] 在运行期生成「深圳中考听说——信息获取-听短文回答问题」的评分提示词。
 *
 * - 拆解与执行都用 DeepSeek 的 `deepseek-flash`（密钥从环境变量 `DS_KEY` 读取，
 *   不写进仓库；未设置时只跑结构用例，不发真实请求）；
 * - 生成的步骤由 `f_jit` 编译成闭包，按计划的边组成 Flow；
 * - `LOOM_PROMPT_BEGIN/END` 之间是最终提示词，便于从测试输出里摘取。
 */
@Test
class LoomPromptDesign_test {
    static let MODEL = 'deepseek-flash'
    static let KEY_ENV = 'DS_KEY'

    static func envOf(name: String): String {
        for(item in getVariables()){
            if(item[0] == name){
                return item[1]
            }
        }
        ''
    }

    /**
     * 密钥解析顺序：环境变量 `DS_KEY` → 仓库外的 `/tmp/dskey`。
     *
     * 两条路径都不会把密钥写进项目；测试进程拿不到父进程环境时用文件兜底。
     */
    static func apiKey(): String {
        let fromEnv = envOf(KEY_ENV)
        if(!fromEnv.isEmpty()){
            return fromEnv
        }
        if(!exists('/tmp/dskey')){
            return ''
        }
        let file = File('/tmp/dskey', OpenMode.Read)
        let text = StringReader(file).readToEnd()
        file.close()
        text.trimAscii()
    }

    /** DeepSeek 通道：模型固定 deepseek-flash，不依赖 f_llm 的元数据配置 */
    static func deepseekChat(model: String, system: String, input: String): String {
        let key = apiKey()
        if(key.isEmpty()){
            throw LoomException('${KEY_ENV} is missing, skip real model calls')
        }
        let conf = LLMConf()
        conf.provider = 'deepseek'
        conf.llmName = 'chat-pro'
        conf.actualLlmName = MODEL
        conf.url = 'https://api.deepseek.com'
        conf.auth = key
        conf.temperature = -1.0f64

        let messages = ArrayList<ChatMessage>()
        if(!system.isEmpty()){
            messages.add(SystemMessage(system))
        }
        messages.add(UserMessage(input))
        let response = LLM.chat(ArrayList<LLMConf>([conf]),
                                LLMParams(model: 'chat-pro', messages: messages))
        var text = ''
        for(item in response.messages){
            match(item as AssistantMessage){
                case Some(message) => text = message.content
                case None => ()
            }
        }
        text
    }

    /** 任务描述：考试说明 + 三条真题样例（足够让模型拆出步骤，又不至于太长） */
    static func description(): String {
        let text = '$' + '{text}'
        let question = '$' + '{question}'
        let answer = '$' + '{answer}'
        '为深圳中考听说「信息获取-听短文回答问题」设计评分提示词。\n\n'
            + '评分任务：考生听一篇短文和一个问题后口头作答，答对 1 分、答错 0 分。\n'
            + '提示词输入：短文 ' + text + '、问题 ' + question + '、考生回答 ' + answer
            + '（语音识别结果）。\n'
            + '提示词输出：JSON {"score":0 或 1,"reason":"不超过 60 字"}。\n'
            + '要求：提示词不得含角色设定；判定以信息是否答到为准，容忍语法小错与识别噪声；'
            + '必须处理是非问句、代词替换、同义表达、与短文冲突等情形。\n\n'
            + '样例 1：短文提到 "a robot cooks breakfast for me"，问题 "Who cooks breakfast '
            + 'for the speaker?"，回答 "A robot cooks breakfast for her."，参考分 1。\n'
            + '样例 2：短文提到 "the car uses wind power"，问题 "Which power does the car use?"，'
            + '回答 "It uses gas."，参考分 0。\n'
            + '样例 3：短文提到 "policemen join the kids to make sure they are safe"，'
            + '问题 "Why do policemen join the kids?"，回答 "To keep them safe."，参考分 1。\n'
    }

    /** 假模型：返回固定的三步计划，用于无密钥环境下验证 API 链路 */
    static func fakePlanner(model: String, system: String, user: String): String {
        if(system.contains('流程编排器') || user.contains('设计')){
            return '{"status":"planned","name":"prompt-design","steps":['
                + '{"id":"criteria","kind":"llm","model":"deepseek-flash",'
                + '"system":"提炼可判定的评分要点","input":"task spec"},'
                + '{"id":"draft","kind":"llm","model":"deepseek-flash",'
                + '"system":"按要点写提示词草稿","input":"{criteria.output}"},'
                + '{"id":"finalize","kind":"llm","model":"deepseek-flash",'
                + '"system":"合并审查意见输出最终提示词","input":"{draft.output}"}],'
                + '"edges":[["criteria","draft"],["draft","finalize"]]}'
        }
        ''
    }

    @TestCase
    func testAgentCompilesDescriptionIntoRunnableProgram(): Unit {
        let agent = LoomAgent(LoomPromptDesign_test.fakePlanner, plannerModel: MODEL)
        let program = agent.compile(description(), name: 'prompt-design')

        @Expect(program.stepCount, 3)
        @Expect(program.flowSource.contains('registerTask'), true)
        @Expect(program.stepSources.size, 3)

        let host = RecordingHost()
        let out = program.run(host, StartEvent(category: 'loom', tag: 'prompt-design',
                                               name: 'start', data: description()))
        @Expect(out.name, 'finalize')
        @Expect(host.calls.size, 3)
        for(model in host.models){
            @Expect(model, MODEL)
        }
    }

    @TestCase
    func testRealDeepseekGeneratesPrompt(): Unit {
        if(apiKey().isEmpty()){
            return    // 没有密钥：不发起真实请求
        }
        let agent = LoomAgent(LoomPromptDesign_test.deepseekChat, plannerModel: MODEL)
        let program = agent.compile(description(), name: 'prompt-design')
        let host = DefaultLoomHost(LoomPromptDesign_test.deepseekChat)
        let out = program.run(host, StartEvent(category: 'loom', tag: 'prompt-design',
                                               name: 'start', data: description()))

        let text = match(out as DataEvent){
            case Some(event) => match(event.data as String){
                case Some(value) => value
                case None => ''
            }
            case None => ''
        }
        @Expect(text.size > 0, true)
        println('LOOM_FLOW_SOURCE_BEGIN')
        println(program.flowSource)
        println('LOOM_FLOW_SOURCE_END')
        println('LOOM_PROMPT_BEGIN')
        println(text)
        println('LOOM_PROMPT_END')
    }
}

/** 记录调用的假宿主 */
class RecordingHost <: LoomHost {
    public var calls: ArrayList<String> = ArrayList<String>()
    public var models: ArrayList<String> = ArrayList<String>()

    public func render(template: String, e: Event): String {
        template
    }

    public func callTool(name: String, argsJson: String): String {
        ''
    }

    public func callLlm(model: String, system: String, input: String): String {
        models.add(model)
        calls.add(input)
        '【${system}】'
    }
}
