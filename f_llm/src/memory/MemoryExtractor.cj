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

import fountain::f_bean.macros.*

public abstract class MemoryExtractor {
    public func extract(json: JsonObject, overwriter: (String, String) -> Unit): Unit
    public func extract(json: JsonObject, key: String): String
    public prop systemPrompts: String
    public prop userPrompts: String
    protected func extract(key: String, jsonobj: JsonObject, overwriter: (String, String) -> Unit): Unit {
        if(let Some(jsonarr: JsonArray) <- jsonobj.get(key)){
            for(json in jsonarr.getItems()){
                let jsonobj = json.asObject()
                let content = this.extract(jsonobj, key)
                if(content.size > 0){
                    let kind = key[0 .. key.size - 1]
                    overwriter(kind, content)
                }
            }
        }
    }
    protected func extractString(jsonobj: JsonObject, key: String): String {
        jsonobj.get(key)?.asString().getValue() ?? ''
    }
    protected func extractArray(jsonobj: JsonObject, key: String): String {
        jsonobj.get(key)?.asArray()
                .getItems()
                .iterator()
                .map{x => x.asString().getValue()}
                .intersperse('\n  - ')
                .fold(StringGenerator()){g, s => g.append(s)}
                .toString() ?? ''
    }
}
@Bean
public class ExperienceExtractor <: MemoryExtractor {
    public func extract(jsonobj: JsonObject, overwriter: (String, String) -> Unit): Unit{
        extract('lessons', jsonobj, overwriter)
        extract('experiences', jsonobj, overwriter)
    }
    public func extract(jsonobj: JsonObject, key: String): String {
        match(key){
            case 'lessons' => '''
- **目的**：${extractString(jsonobj, 'purpose')}
- **错误原因**：${extractString(jsonobj, 'reason')}
- **错误行为**：${extractString(jsonobj, 'behavior')}
- **错误结果*：${extractString(jsonobj, 'result')}
- **解决方案*：${extractString(jsonobj, 'solution')}
- **完整执行过程**：
  - ${extractArray(jsonobj, 'steps')}
'''
                            case 'experiences' => '''
- **目的**：${extractString(jsonobj, 'purpose')}
- **成功行为**：${extractString(jsonobj, 'behavior')}
- **成功结果**：${extractString(jsonobj, 'result')}
- **成功解决方案**：${extractString(jsonobj, 'solution')}
- **完整执行过程**：
  - ${extractArray(jsonobj, 'steps')}
'''
            case _ => ''
        }
    }
    public prop systemPrompts: String {
        get(){
'''
从用户提供的上下文内容总结成功经验和失败的教训
- 如果上下文内容存在曾经失败的操作、曾经发生过错误的执行结果，同时又包含成功的执行过程，则总结为失败的教训
- 尤其是用户明确指出的错误要着重总结
- 教训需要包含以下要点：
  1. 陈述目的
  2. 错误原因
  3. 错误行为
  4. 错误结果
  5. 成功的解决方案及完整执行过程
     - 解决方案的详细描述
     - 完整执行过程的执行步骤
- 如果上下文内容存在被用户认可的操作或者一次成功的操作，则为成功的经验
- 尤其是用户明确要求记忆的部分要着重总结
- 经验要包含以下要点：
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
        }
    }
    public prop userPrompts: String {
        get(){
            '请总结用户提供的上下文内容中的成功经验和失败的教训，并以JSON格式返回。'
        }
    }
}
@Bean
public class IndividualityExtractor <: MemoryExtractor {
    public func extract(jsonobj: JsonObject, overwriter: (String, String) -> Unit){
        extract('individualities', jsonobj, overwriter)
    }
    public func extract(jsonobj: JsonObject, key: String): String {
        match(key){
            case 'individualities' => '''
- **偏好**：${extractString(jsonobj, 'preference')}
- **习惯**：${extractString(jsonobj, 'habit')}
'''
            case _ => ''
        }
    }
    public prop systemPrompts: String {
        get(){
'''
从用户提供的上下文内容总结用户的个性，包含用户对某些事物或事情的偏好以及做事、措辞的习惯
尤其是用户明确要求记忆的部分，要着重总结。
- **注意**：严格按照以下JSON格式返回
```json
{
    "individualities": [{
        "preference": "用户对某些事物或事情的偏好",
        "habit": "用户做事、措辞的习惯"
    }]
}
```
'''
        }
    }
    public prop userPrompts: String {
        get(){
            '根据用户提供的上下文内容，提取用户对某些事物或事情的偏好以及做事、措辞的习惯，并以JSON格式返回。'
        }
    }
}