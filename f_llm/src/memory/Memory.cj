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
            faithful = DummyMemory.instance
            timer = ZERO_TIMER
        }
    }

    private static func nextSummarisingTime(){
        DateTime.tomorrow - DateTime.now()
    }
    private static func summarise(session: String, messages: ArrayList<ChatMessage>): Bool {
        let finder = if(let Some(f) <- lookupOption<ExperiencesFinder>()){
            f
        }else{
            return false
        }
        let prompts = '''
从用户提供的上下文内容总结成功经验和失败的教训
- 如果上下文内容存在曾经失败的操作、曾经发生过错误的执行结果，同时又包含成功的执行过程，则总结为失败的教训，教训需要包含以下要点：
  1. 陈述目的
  2. 错误原因
  3. 错误行为
  4. 错误结果
  5. 成功的解决方案及完整执行过程
     - 解决方案的详细描述
     - 完整执行过程的执行步骤
- 如果上下文内容存在被用户认可的操作，则为成功的经验，经验要包含以下要点：
  1. 陈述目的
  2. 描述成功行为
  3. 描述成功结果
  4. 描述成功解决方案及完整执行过程
- **注意**：严格按照以下JSON格式返回
lessons是失败的教训，experiences是成功的经验
```json
{
    "lessons": [{
        "purpose": "目的陈述",
        "reason": "错误原因",
        "behavior": "错误行为",
        "result": "错误结果",
        "solution": "成功解决方案的详细描述",
        "steps": [
            "完整执行过程的执行步骤"
        ]
    }],
    "experiences": [{
        "purpose": "目的陈述",
        "behavior": "描述成功行为",
        "result": "描述成功结果",
        "solution": "成功解决方案的详细描述",
        "steps": [
            "完整执行过程的执行步骤"
        ]
    }]
}
```
'''
        let system = SystemMessage(prompts)
        let content = StringGenerator()
        for(m in messages){
            content.append(generateContent(m))
            content.append('---')
        }
        let user = UserMessage('''
从以下内容总结成功的经验和失败的教训
## 上下文
${content}
''')
        let summarising = ArrayList<ChatMessage>()
        summarising.add(system)
        summarising.add(user)
        let params = LLMParams(model: LLMConfig.getSummarisingModel(), messages: summarising)
        let respmsg = LLMContextMediator.instance.access(SummarisingAgentId, session, LLM_TYPE_TEXT, params).messages[0].content
        if(let Some(start) <- respmsg.indexOf('```') && 
           let Some(end) <- respmsg.lastIndexOf('```', start + 3) &&
           let sub <- respmsg[start + 3 .. end].trimAscii()){
            let jsonstr = if(sub.startsWith('json')){
                sub[4 .. ]
            }else{
                sub
            }
            let jsonobj = JsonValue.fromStr(jsonstr).asObject()
            func extract(key: String){
                if(let Some(jsonarr: JsonArray) <- jsonobj.get(key)){
                    for(json in jsonarr.getItems()){
                        let jsonobj = json.asObject()
                        func extractString(key: String){
                            jsonobj.get(key)?.asString().getValue() ?? ''
                        }
                        func extractArray(key: String){
                            jsonobj.get('steps')?.asArray()
                                   .getItems()
                                   .iterator()
                                   .map{x => x.asString().getValue()}
                                   .intersperse('\n  - ')
                                   .fold(StringGenerator()){g, s => g.append(s)}
                                   .toString() ?? ''
                        }
                        let content = match(key){
                            case 'lessons' => '''
- **目的**：${extractString('purpose')}
- **错误原因**：${extractString('reason')}
- **错误行为**：${extractString('behavior')}
- **错误结果*：${extractString('result')}
- **解决方案*：${extractString('solution')}
- **完整执行过程**：
  - ${extractArray('steps')}
'''
                            case 'experiences' => '''
- **目的**：${extractString('purpose')}
- **成功行为**：${extractString('behavior')}
- **成功结果**：${extractString('result')}
- **成功解决方案**：${extractString('solution')}
- **完整执行过程**：
  - ${extractArray('steps')}
'''
                            case _ => continue
                        }
                        let kind = key[0 .. key.size - 1]
                        finder.overwrite(kind, content)
                    }
                }
            }
            extract('lessons')
            extract('experiences')
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