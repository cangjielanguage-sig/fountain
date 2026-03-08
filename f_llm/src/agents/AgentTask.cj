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
package fountain::f_llm.agents

/**
 * 1. 使用事件名+agent.id查询skill
 * 2. 把agent.agent+skill.details组成完整的提示词模板
 *    skill.details包含skill.title + skill.metadata
 *    ```md
 *    ${agent.agent}
 *
 *    ${skill.details}
 *    ```
 * 3. 把exec(e: Event)的e.data做以下转换((e.data as ToData)?.toData()).getOrThrow() as SimpleDataObject，
 *    将转换后的实例作为模板参数替换提示词模板中的{{...}}占位符
 * 4. 用agent.llmType agent.llmName查询大模型
 * 5. 用替换后的提示词+函数列表访问大模型
 * 6. 用大模型返回的结果访问函数
 * 7. 用函数返回的结果构造事件作为智能体的返回
 */
public class AgentTask <: Task {
    public AgentTask(private let agent: Agent){}
    public prop name: String{
        get(){
            agent.agent
        }
    }
    public prop acceptableEvents: Array<String> {
        get(){
            agent.acceptableEvents
        }
    }
    private var skillsFinder_: ?SkillsFinder = None
    private prop skillsFinder: SkillsFinder {
        get(){
            if(let Some(f) <- skillsFinder_){
                f
            }else{
                let f = lookup<SkillsFinder>()
                skillsFinder_ = f
                f
            }
        }
    }
    public func exec(e: Event): Event {
        let skill = skillsFinder.querySkill(agent.id, e.name) ?? throw SkillNotFoundException('agent: ${agent.id}, event: ${e.name}')
        let promptsTemplate = '''
${agent.agent}

${skill.details}'''
        let functionNames = skill.functionNames
        let skillId = skill.id
        let messages = ArrayList<ChatMessage>()
        var content = ''
        var eData = None<Any>
        let prompts = if(let e: DataEvent <- e && let any: ToData <- e.data && let data: SimpleDataObject <- any.toData()){
            eData = any
            TextTemplate.compile(promptsTemplate, prefix: '{{', suffix: '}}').format(data)
        }else if (let e: DataEvent <- e && let agentData: AgentEventData <- e.data && let Some(any: ToData) <- agentData.data && let data: SimpleDataObject <- any.toData()) {
            let msgs = agentData.messages
            messages.add(all: if(msgs.size > 0 && let msg <- msgs[0] && msg.role == ROLE_SYSTEM){
                msgs[1 ..]
            }else{
                msgs
            })
            eData = agentData
            content = agentData.message
            TextTemplate.compile(promptsTemplate, prefix: '{{', suffix: '}}').format(data)
        }else{
            promptsTemplate
        }
        let system = SystemMessage(prompts)
        messages.add(system, at: 0)
        if(content.size > 0){
            messages.add(UserMessage(content))
        }
        let functions = FunctionMediator.getDefinitions(functionNames)
        let params = LLMToolParams(model: agent.llmName, messages: messages)
        params.addTools(functions)
        params.agentId = agent.id
        params.skillId = skillId
        let resp = LLMContextMediator.instance.access(agent.llmType, params)
        let eventData = AgentEventData(data: eData, messages: messages)
        var eventName = ''
        var eventType = EventType.Task
        for(msg in resp.messages){
            if(let m: ToolCallMessage <- msg){
                messages.add(m)
                for(tool in m.toolCalls){
                    let function = tool.function
                    let name = function.name
                    let arguments = function.arguments
                    let json = JsonValue.fromStr(arguments).asObject()
                    let fnResult = FunctionMediator.call(name, json)
                    eventName = fnResult.event
                    eventType = fnResult.eventType
                    let toolmsg = ToolMessage()
                    toolmsg.tool_call_id = tool.id
                    toolmsg.content = fnResult.result
                    messages.add(toolmsg)
                }
            }else if(let m: AssistantMessage <- msg){
                messages.add(m)
            }
        }
        DataEvent(eventType: eventType, name: eventName, data: eventData, category: e.category, tag: e.tag)
    }
}
