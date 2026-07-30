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
 *    - 一个智能体可以有若干主要技能和若干辅助技能，也可以没有
 * 2. 把agent.agent+skill.details组成完整的提示词模板
 *    技能包含主技能和辅助技能，组织文化、智能体描述、主技能描述、辅助技能元数据拼在一起作为一个system消息
 *    ```md
 *    组织文化
 *    ===
 *    ${culture}
 *
 *    > **重要提示**：标注 ⚠️ 的内容为特别提醒，需要重点关注，请勿忽略。
 *
 *    智能体描述
 *    ===
 *    ${agent.agent}
 *    ___
 *
 *    技能列表
 *    ===
 *    # 主技能
 *    ## 技能标题：${skill.title}
 *    ${skill.details}
 *    ___
 *
 *    # 辅助技能元数据
 *    ## 技能标题：${skill.title}
 *    ${skill.metadata}
 *    ___
 *    ```
 * 3. 把exec(e: Event)的e.data做以下转换((e.data as ToData)?.toData()).getOrThrow() as SimpleDataObject，
 *    将转换后的实例作为模板参数替换提示词模板中的{{...}}占位符
 * 4. 用agent.llmType agent.llmName查询大模型
 * 5. 用替换后的提示词+函数列表访问大模型
 * 6. 用大模型返回的结果访问函数
 * 7. 用函数返回的结果构造事件作为智能体的返回
 * 8. 控制上下文长度的策略接口和若干实现
 *      #### 上下文策略（fountain::f_llm.llm.ContextPruner的子类型）：
 *      - A：Retain（RetainContext）：保留全部上下文
 *      - B：LastN（LastNContext）：用初始化参数指定N的具体数
 *        - 这个策略的名称是'LastN_${n}'，n是初始化指定的具体数
 *      - B：Summary（ContextSummaryPruner）：对全部上下文总结概要
 *        - 这个策略的名称是'Summary_BY_${llmType}_${model}'，llmType和model都是初始化参数
 *        - llmType是大模型可以做的事情，可取的值: text code image video audio embedding rerank tokenizer。
 *        - model是大模型的名称
 *      - D: Keywords（ContextKeywordsPruner）：对全部上下文提取关键词
 *        - 这个策略的名称是'Keywords_BY_${llmType}_${model}'，llmType是大模型可以做的事情，可取的值: text code image video audio embedding rerank tokenizer。
 *        - model是大模型的名称
 *      - E：DRC（DRCContextPruner）：对system和其他消息执行不同的上下文策略
 *        - 这个策略的名称是'DRC_BY_${systemPruner.name}_${otherPruner.name}'。
 *      - F：饱和上下文（SaturationContextPruner）：
 *        - 这个策略的名称是'Saturation_${pruner.name}'
 *        - 上下文饱和时执行指定策略，
 *        - 饱和token数在大模型配置中指定，
 *        - 可以用agentId查询到智能体使用使用的大模型，进而确定大模型配置的饱和token数
 *          - 不同的大模型饱和token数可能不同，
 *            - 通常支持1M上下文的大模型在上下文达到10%~15%会产生严重幻觉，
 *            - 支持200K上下文的大模型在上下文超过80K时会产生严重幻觉。
 *            - Keywords和Summary两个策略依赖大模型，要注意给执行策略的大模型发送的上下文不要超过它的饱和token数
 */
public open class AgentTask <: Task {
    private static let log = LoggerFactory.getLogger<AgentTask>()
    private let producingEventJsons: JsonArray
    public AgentTask(private let agent: Agent){
        producingEventJsons = JsonArray(Array<JsonValue>(agent.producingEvents.size){i =>
           let v: JsonValue = JsonString(agent.acceptableEvents[i])
           v
        })
    }
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
    public prop producingEvents: Array<String> {
        get(){
            agent.producingEvents
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
    private var orgFinder_: ?OrganizationFinder = None
    private prop orgFinder: OrganizationFinder {
        get(){
            if(let Some(f) <- orgFinder_){
                f
            }else{
                let f = lookup<OrganizationFinder>()
                orgFinder_ = f
                f
            }
        }
    }
    private var tokenUsageSaver_: TokenUsageSaver = DummyTokenUsageSaver.instance
    private var tokenUsageSaverLookuped = false
    private prop tokenUsageSaver: TokenUsageSaver {
        get(){
            if(tokenUsageSaverLookuped){
                tokenUsageSaver_
            }else{
                tokenUsageSaver_ = lookupOption<TokenUsageSaver>() ?? DummyTokenUsageSaver.instance
                tokenUsageSaverLookuped = true
                tokenUsageSaver_
            }
        }
    }
    private func genSkillDetails(skill: Skill, e: Event){
        func genref(){
            if(let de: DataEvent <- e && let agentData: AgentEventData <- de.data){
                let sg = StringGenerator()
                assembleSkillReference(skill.title, agentData, sg)
                sg.toString()
            }else{
                ''
            }
        }
        if(let de: DataEvent <- e && let agentData: AgentEventData <- de.data && 
           let Some(any: ToData) <- agentData.data && let data: SimpleDataObject <- any.toData()){
'''
## 技能标题：${populatePromptsParams(skill.title, data)}

### 技能描述
${populatePromptsParams(skill.details, data)}
${genref()}
___

'''
        }else{
'''
## 技能标题：${skill.title}

### 技能描述
${skill.details}
${genref()}
___

'''
        }
    }
    private func genAuxiliarySkill(skill: Skill){
'''
## 技能标题：${skill.title}

### 技能元数据
${skill.metadata}
___

'''
    }
    private func doGenCulture(culture: String){
'''
组织文化
===
${culture}
___

'''
    }
    private func doGenCulture(){
        if(let culture <- orgFinder.queryOrgCulture(agent.id) && culture.size > 0){
            doGenCulture(culture)
        }else{
            ''
        }
    }
    private func genPromptsTemplate(e: Event, primarySkills: StringGenerator, auxiliaryMetadatas: StringGenerator){
'''
${doGenCulture()}
> **重要提示**：标注 ⚠️ 的内容为特别提醒，需要重点关注，请勿忽略。
> ⚠️ 注意：如果需要直接输出回复，而不再依赖其它函数或工具的结果，务必使用answer函数传递回复
> 如果当前上下文不足以完成任务，请按照各函数描述，调用正确的函数获取相应数据。

智能体描述
===
${agent.agent}
___

技能列表
===
# 主技能
此处包含主技能的全部描述。
${primarySkills}
___

# 辅助技能元数据
辅助技能只预加载元数据，需要时调用技能加载函数（loadSkill）加载相应技能的详细描述。
务必使用以下参数调用loadSkill函数。
⚠️ 注意：此处loadSkill函数的event参数固定为"${e.name}"，请勿修改。
```json
{
    "event": "${e.name}",
    "title": "试图使用的技能的标题"
}
```
${auxiliaryMetadatas}
'''
    }
    private func populatePromptsParams(promptsTemplate: String, data: SimpleDataObject){
        if(promptsTemplate.contains('{{')){
            TextTemplate.compile(promptsTemplate, prefix: '{{', suffix: '}}').format(data)
        }else{
            promptsTemplate
        }
    }
    private func populatePromptsParams(messages: ArrayList<ChatMessage>, promptsTemplate: String, data: SimpleDataObject){
        let msg = populatePromptsParams(promptsTemplate, data)
        messages.add(SystemMessage(msg))
    }
    private func assembleSkillReference(title: String, agentData: AgentEventData, generator: StringGenerator){
        let references = agentData.getSkillReferences(title)
        if(references.size > 0){
            for(reference in references){
                generator.append('''
##### ${reference.title}
${reference.content}
''')
            }
        }
    }
    private func assembleAuxiliarySkills(agentData: AgentEventData){
        if(agentData.skillDetails.size > 0){
            let auxiliarySkills = StringGenerator('## 辅助技能列表\n')
            for((title, skill) in agentData.skillDetails){
                auxiliarySkills.append(skill)
                auxiliarySkills.append('\n')
                assembleSkillReference(title, agentData, auxiliarySkills.append('#### 技能引用列表\n'))
                auxiliarySkills.append('---\n\n')
            }
            auxiliarySkills.toString()
        }else{
            ''
        }
    }
    private func assembleMemories(messages: ArrayList<ChatMessage>, agentData: AgentEventData){
        let memories = agentData.memorySummaries
        if(memories.size > 0){
            messages.add(SystemMessage('''
## 过往记忆
${memories.iterator().map{m => '''
### 记忆类型
${m.kind}
### 内容
${m.content}
___
'''}.fold(StringGenerator()){g, s => g.append(s)}}
'''))
        }
    }
    private func assembleNoParamPrompts(messages: ArrayList<ChatMessage>, agentPrompts: String, agentData: AgentEventData){
        messages.add(SystemMessage(agentPrompts))
        let auxiliarySkills = assembleAuxiliarySkills(agentData)
        if(auxiliarySkills.size > 0){
            messages.add(SystemMessage(auxiliarySkills))
        }
    }
    private func generateNextEvents(ne: JsonObject){
        let description = if(let Some(desc: JsonString) <- ne.get('description')){
            if(let Some(idx) <- desc.getValue().indexOf('## 事件列表')){
                desc.getValue()[0 .. idx]
            }else{
                desc.getValue()
            }
        }else{
            ''
        }
        let eventFinder = lookup<EventFinder>()
        if(let Some(events: JsonArray) <- ne.get('enum') && let items <- events.getItems() && items.size > 0){
            let eventDesc = StringGenerator('## 事件列表')
            for(ens in items){
                let en = ens.asString().getValue()
                let desc = eventFinder.find(en)
                eventDesc.append('''

### 事件名：${en}
${desc}

''')
            }
            ne.add('description', JsonString('''
${description}

${eventDesc}
'''))
        }
    }
    public open func exec(e: Event): Event {
        if(!(e is AgentEvent)){
            throw LLMException("param must be AgentEvent")
        }
        let skills = skillsFinder.querySkills(agent.id, e.name)
        var auxiliaryMetadatas  = StringGenerator()
        var primarySkills = StringGenerator()
        let functionNames = ArrayList<String>()
        for(skill in skills){
            if(skill.skillType == SKILL_TYPE_PRIMARY){
                for(n in skill.functionNames){
                    functionNames.add(n)
                }
                primarySkills.append(genSkillDetails(skill, e))
            }else{
                auxiliaryMetadatas.append(genAuxiliarySkill(skill))
            }
        }
        let promptsTemplate = genPromptsTemplate(e, primarySkills, auxiliaryMetadatas)
        var messages = ArrayList<ChatMessage>()
        var eData = None<Any>
        var functions = HashSet<FunctionCall>()
        if (let e: DataEvent <- e && let msg: String <- e.data){
            messages.add(SystemMessage(promptsTemplate))
            messages.add(UserMessage(msg))
        }else if (let e: DataEvent <- e && let msg: ChatMessage <- e.data){
            messages.add(SystemMessage(promptsTemplate))
            messages.add(msg)
        }else if (let e: DataEvent <- e && let msgs: ArrayList<ChatMessage> <- e.data){
            messages.add(SystemMessage(promptsTemplate))
            messages.add(all: msgs)
        }else if(let e: DataEvent <- e && let any: ToData <- e.data && let data: SimpleDataObject <- any.toData()){
            eData = any
            populatePromptsParams(messages, promptsTemplate, data)
        }else if (let e: DataEvent <- e && let agentData: AgentEventData <- e.data) {
            assembleMemories(messages, agentData)
            if(let Some(any: ToData) <- agentData.data && let data: SimpleDataObject <- any.toData()){
                populatePromptsParams(messages, promptsTemplate, data)
                let auxiliarySkills = assembleAuxiliarySkills(agentData)
                if(auxiliarySkills.size > 0){
                    populatePromptsParams(messages, auxiliarySkills, data)
                }
                let msgs = agentData.messages
                let startMsgIdx = if(msgs.size > 0 && let msg <- msgs[0] && msg.role == ROLE_SYSTEM){
                    1
                }else{
                    0
                }
                for(msg in msgs[startMsgIdx .. msgs.size]){
                    if(msg.role == ROLE_SYSTEM){
                        for(skill in skills where skill.skillType != SKILL_TYPE_PRIMARY){
                            let idx = msg.content.indexOf('## 技能标题：') ?? -1
                            if(idx >= 0 && (msg.content.indexOf(skill.title, idx) ?? -1) == idx + '## 技能标题：'.size){
                                messages.add(msg)
                                break
                            }
                        }
                    }else{
                        messages.add(msg)
                    }
                }
                eData = agentData
                if(let content <- agentData.message && content.size > 0) {
                    messages.add(UserMessage(content))
                }
            }else{
                assembleNoParamPrompts(messages, promptsTemplate, agentData)
            }
            functions = agentData.functions
        }else{
            messages.add(UserMessage(promptsTemplate))
        }
        let params = LLMToolParams(model: agent.llmName, messages: messages)
        func addFunctions<I>(functions: I): Unit where I <: Iterable<FunctionCall>{
            for(call in functions){
                let props = call.function.parameters.properties.asObject()
                if(let Some(ne: JsonObject) <- props.get('nextEvent')){
                    if(!ne.containsKey('enum')){
                        ne.add('enum', producingEventJsons)
                    }
                    generateNextEvents(ne)
                }
                func putEnum(propName: String, value: String){
                    if(let Some(ne: JsonObject) <- props.get(propName)){
                        ne.add('enum', JsonArray([JsonString(value)]))
                    }    
                }
                putEnum('event', e.name)
                putEnum('session', e.session)
                params.addFunction(call)
            }
        }
        addFunctions(functions)
        addFunctions(FunctionMediator.getDefinitions(functionNames))
        params.messages = ContextPrunerMediator.instance.prune(agent.pruner, agentId: agent.id, session: e.session, messages: params.messages)
        messages = params.messages
        func accessLLM(){
            let maxCount = LLMConfig.getLLMAccessTryingCount()
            let maxElapsed = LLMConfig.getLLMAccessTryingElapsed()
            let start = MonoTime.now()
            var count = 0
            var elapsed = Duration.Zero
            try{
                var a = 0
                var b = 1
                var resp: LLMResp = unsafeZeroValue<LLMResp>()
                while(count < maxCount && elapsed < maxElapsed){
                    try{
                        resp = LLMContextMediator.instance.access(agent.id, e.session, agent.llmType, params)
                        break
                    }catch(ex: Exception){
                        elapsed = MonoTime.now() - start
                        count++
                        let sleepDuration = Duration.second * b
                        log.warn{'''
LLM agent: agent: ${agent.id}, session: ${e.session}, llmType: ${agent.llmType}
exception occurred ${ex}, to retry after ${sleepDuration}'''}
                        log.debug(ex){'LLM agent: agent: ${agent.id}, session: ${e.session}, llmType: ${agent.llmType}'}
                        sleep(sleepDuration)
                        let n = a + b
                        a = b
                        b = n
                    }
                }
                if(count >= maxCount){
                    throw LLMException('LLM access count exceeded ${count}, max: ${maxCount}')
                }else if(elapsed >= maxElapsed){
                    throw LLMException('LLM access elapsing exceeded ${elapsed}, max: ${maxElapsed}')
                }else{
                    return resp
                }
            }finally{
                let c = count + 1
                log.info{'LLM agent: agent: ${agent.id}, session: ${e.session}, llmType: ${agent.llmType}, tried: ${c}, elapsed: ${MonoTime.now() - start}'}
            }
        }
        let resp = accessLLM()
        let usage = resp.usage
        tokenUsageSaver.saveTokenUsage(usage)
        let eventData = AgentEventData(data: eData, messages: params.messages, functions: params.functions)
        var eventName = ''
        var eventType = EventType.Task
        for(msg in resp.messages){
            if(let m: ToolCallMessage <- msg){
                messages.add(m)
                for(tool in m.tool_calls){
                    func addToolMsg(content: String){
                        let toolmsg = ToolMessage()
                        toolmsg.tool_call_id = tool.id
                        toolmsg.content = content
                        messages.add(toolmsg)
                    }
                    let function = tool.function
                    let name = function.name
                    let arguments = function.arguments
                    let json = JsonValue.fromStr(arguments).asObject()
                    json.add('session', JsonString(e.session))
                    json.add('event', JsonString(e.name))
                    try{
                        let fnResult = FunctionMediator.call(name, json)
                        eventName = fnResult.event
                        eventType = fnResult.eventType
                        match(fnResult.resultType){
                            case ResultType.Text => 
                                addToolMsg((fnResult.result as String).getOrThrow())
                            case ResultType.Skill => 
                                let skills = (fnResult.result as ArrayList<Skill>).getOrThrow()
                                for(skill in skills){
                                    eventData.skillDetails.add((skill.title, genSkillDetails(skill, e)))
                                    let functions = FunctionMediator.getDefinitions(skill.functionNames)
                                    eventData.addFunctions(functions)
                                }
                                addToolMsg('[技能已加载]')
                            case ResultType.SkillReference =>
                                let references = (fnResult.result as ArrayList<SkillReference>).getOrThrow()
                                eventData.addSkillReferences(references)
                                addToolMsg('[技能参考已加载]')
                            case ResultType.MemorySummary => 
                                let summaries = (fnResult.result as ArrayList<MemorySummary>).getOrThrow()
                                eventData.addMemorySummaries(summaries)
                                addToolMsg('[记忆已加载]')
                        }
                    }catch(e: Exception){
                        log.warn(e){'function call ${name}(${arguments})'}
                        addToolMsg('调用函数时发生了异常： ${e}')
                    }
                }
            }else if(let m: AssistantMessage <- msg){
                messages.add(m)
            }
        }
        Memory.add(e.session, all: messages)
        DataEvent(eventType: eventType, name: eventName, data: eventData, category: e.category, tag: e.tag, session: e.session)
    }
}
