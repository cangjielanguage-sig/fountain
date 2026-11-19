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

import fountain::f_llm.llm.*

/**
 * 零配置装配用的默认 chat 回调：直接走 `LLM.chatByName`。
 *
 * 只在宿主没有自己的 LLM 客户端时使用；`model` 为空则回退到 `plannerModel`，
 * 两者都为空时**调用即报错**（而不是静默用某个模型）。
 */
public class LoomDefaults {
    private init() {
    }

    public static func chat(llmName: String): (String, String, String) -> String {
        { model, system, user =>
            let name = if(model.isEmpty()){ llmName }else{ model }
            if(name.isEmpty()){
                throw LoomException('loom planner model is not configured: pass plannerModel or model')
            }
            let messages = ArrayList<ChatMessage>()
            if(!system.isEmpty()){
                messages.add(SystemMessage(system))
            }
            messages.add(UserMessage(user))
            let params = LLMToolParams(model: name, messages: messages)
            let response = LLM.chatByName(name, params)
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
}
