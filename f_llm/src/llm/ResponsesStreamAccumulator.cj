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
package fountain::f_llm.llm

import fountain::f_data.*

import fountain::f_llm.exception.*

/**
 * Responses API 流式归并。
 *
 * 语义约定（评审 B5）：**以 `response.completed` 里的完整对象为准**——
 * delta 只用于实时展示，累计结果与 completed 不一致时取 completed。
 */
public class ResponsesStreamAccumulator {
    private let text = StringBuilder()
    private var completed: ?LLMResp = None<LLMResp>
    private var failure = ''
    private var done = false

    public prop finished: Bool {
        get() {
            done
        }
    }

    public func isDone(data: String): Bool {
        data.trimAscii() == '[DONE]'
    }

    public func feed(data: String): ?LLMDelta {
        if(isDone(data)){
            done = true
            return None<LLMDelta>
        }
        let json = JsonValue.fromStr(data).asObject()
        match(stringOf(json, 'type')){
            case 'response.output_text.delta' =>
                let delta = stringOf(json, 'delta')
                if(!delta.isEmpty()){
                    text.append(delta)
                    return Some(LLMDelta(LLMDeltaKind.Text, delta))
                }
            case 'response.completed' =>
                if(let Some(rawResponse) <- json.get('response')){
                    completed = Some(ResponsesMapper.parse(rawResponse.asObject()))
                }
                done = true
            case 'response.failed' =>
                failure = stringOf(json, 'message')
                if(failure.isEmpty()){
                    failure = 'response.failed'
                }
                done = true
            case 'error' =>
                failure = stringOf(json, 'message')
                if(failure.isEmpty()){
                    failure = 'stream error'
                }
                done = true
            case _ => ()
        }
        None<LLMDelta>
    }

    public func result(): LLMResp {
        if(!failure.isEmpty()){
            throw LLMException('responses stream failed: ${failure}')
        }
        if(let Some(full) <- completed){
            return full
        }
        let partial = LLMResp()
        partial.messages.add(AssistantMessage(text.toString()))
        let estimated = estimateTokens(text.toString())
        partial.usage.completion = estimated
        partial.usage.total = estimated
        partial.usageEstimated = true
        partial
    }
}
