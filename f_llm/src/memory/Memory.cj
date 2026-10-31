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
package fountain::f_llm.memory

public struct Memory {
    private static let faithful: FaithfulMemory
    private static let timer: Timer

    static init(){
        let makingMemory = LLMConfig.getMakingMemory()
        if(makingMemory){
            faithful = FaithfulMemoryImpl()
            timer = Timer.after(nextSummarisingTime()){
                faithful.summarise(Memory.summarise)
                nextSummarisingTime()
            }
            atExit(timer.cancel)
        }else{
            faithful = DummyMemory()
            timer = ZERO_TIMER
        }
    }

    private static func nextSummarisingTime(){
        DateTime.tomorrow - DateTime.now()
    }
    private static func extractor(): ?(MemoryExtractor, MemorySummaryFinder) {
        match(LLMConfig.getSummarisingActionKind()){
            case 'experience' => (lookup<ExperienceExtractor>(), lookup<ExperienceFinder>())
            case 'individuality' => (lookup<IndividualityExtractor>(), lookup<IndividualityFinder>())
            case '' => None<(MemoryExtractor, MemorySummaryFinder)>
            case x => (lookup<MemoryExtractor>(Prefix(x)), lookup<MemorySummaryFinder>(Prefix(x)))
        }
    }
    private static func summarise(session: String, messages: ArrayList<ChatMessage>): Bool {
        let (extractor, finder) = if(let Some(x) <- Memory.extractor()){
            x
        }else{
            return false
        }
        let prompts = extractor.systemPrompts
        let system = SystemMessage(prompts)
        let content = StringGenerator()
        for(m in messages){
            content.append(generateContent(m))
            content.append('---')
        }
        let user = UserMessage('''
${extractor.userPrompts}
## 上下文
${content}
''')
        let summarising = ArrayList<ChatMessage>()
        summarising.add(system)
        summarising.add(user)
        let params = LLMParams(model: LLMConfig.getSummarisingModel(), messages: summarising)
        let respmsg = LLM.chatByName(LLMConfig.getSummarisingLlmName(), params).messages[0].content
        if(let Some(start) <- respmsg.indexOf('```') && 
           let Some(end) <- respmsg.lastIndexOf('```', start + 3) &&
           let sub <- respmsg[start + 3 .. end].trimAscii()){
            let jsonstr = if(sub.startsWith('json')){
                sub[4 .. ]
            }else{
                sub
            }
            let jsonobj = JsonValue.fromStr(jsonstr).asObject()
            extractor.extract(jsonobj, finder.overwrite)
            // 5.1：摘要同时落一条向量记忆，供检索召回
            remember(session, jsonstr)
        }
        true
    }
    
    private static func generateContent(message: ChatMessage): String {
        match(message){
                case x: ToolCallMessage => 
                    let content = StringGenerator('''
  - role: ${x.role}
  - content: ${x.content}
''')
                    for(call in x.tool_calls){
                        content.append('''
    - id: ${call.id}
    - type: ${call.`type`}
    - function: ${call.function.name}(${call.function.arguments})
''')
                    }
                    content.toString()
                case x: ToolMessage => '''
  - role: ${x.role}
  - tool_call_id: ${x.tool_call_id}
  - content: ${x.content}
'''
                case x => '''
  - role: ${x.role}
  - content: ${x.content}
'''
        }
    }
    /**
     * 5.1：把会话摘要写成一条向量记忆（kind=session）。
     *
     * 流水仍在 `FaithfulMemory`（它适合按时间回放）；这里只把「提炼后的摘要」
     * 交给 `Stores.content().memory`，让检索侧能召回。
     */
    public static func remember(session: String, summary: String): Unit {
        try{
            // 首次使用时接线（幂等）：加载实现包、注册内容族、校验配置
            StoreWiring.wire()
            Stores.content().memory.add(MemoryWrite(LLMConfig.getMemoryUserId(), 'global',
                                                    session, summary, 'session'))
        }catch(e: Exception){
            // 摘要写入失败不影响会话主流程，但必须留下日志，避免静默丢失
            LoggerFactory.getLogger<Memory>().warn('memory summary not stored: ${e.message}')
        }
    }

    protected static func add(session: String, role: Role, content: String): Unit {
        faithful.add(session, role, content)
    }
    protected static func add(session: String, all!: ArrayList<ChatMessage>): Unit {
        spawn{
            for(m in all){
                add(session, m.role, generateContent(m))
            }
        }
    }
}