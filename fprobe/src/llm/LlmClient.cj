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
package fountain::fprobe.llm

import std.collection.ArrayList
import fountain::f_llm.llm.*

/** LLM 调用端口；用例注入假实现，生产走 `f_llm`。 */
public interface LlmClient {
    func chat(prompt: String): String
}

/** 生产实现：`LLM.chatByName` + 单条用户消息。 */
public class FLlmClient <: LlmClient {
    private let model: String

    public init(model: String) {
        this.model = model
    }

    public func chat(prompt: String): String {
        let messages = ArrayList<ChatMessage>([UserMessage(prompt)])
        let params = LLMParams(model: model, messages: messages)
        let response = LLM.chatByName(model, params)
        if (response.messages.isEmpty()) {
            return ""
        }
        response.messages[0].content
    }
}
