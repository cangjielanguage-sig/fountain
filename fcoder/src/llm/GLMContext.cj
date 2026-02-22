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
package fountain::fcoder.llm

public class GLMContext <: AbstractLLMContext {
    public init(conf: LLMConf){
        super(conf)
    }

    public func access(params: LLMParams): LLMResp {
        resource(HttpClient(url)){http =>
            http.header('Authorization', 'Bearer ${conf}')
            let input = http.post('application/json', params).body
            let bytes = ArrayList<Byte>()
            let buf = Array<Byte>(1024, repeat: 0)
            while(let s <- input.read(buf) && s > 0){
                bytes.add(all: buf[0 .. s])
            }
            let allBytes = bytes.unsafeData()
            let respJson = String.fromUtf8(allBytes)
            let json = JsonValue.fromStr(respJson).asObject()
            let choices = json.get('choices').getOrThrow().asArray()
            let llmResp = LLMResp()
            for(i in 0 .. choices.size()){
                let message = choices[i].asObject().get('message').getOrThrow{LLMException(respJson)}.asObject()
                if(message.containsKey('tool_calls')){
                    llmResp.messages.add(DataObject<ToolCallMessage>.populate(message.toData()).getOrThrow())
                }else{
                    llmResp.messages.add(DataObject<AssistantMessage>.populate(message.toData()).getOrThrow())
                }
            }
            let usageJson = json.get('usage').getOrThrow().asObject()
            let usage = llmResp.usage
            DataObject<TokenUsage>.populate(usageJson.toData(), usage)
            usage.cached = usageJson.get('prompt_tokens_details')?.asObject().get('cached_tokens')?.asInt().getValue() ?? 0
            llmResp
        }
    }
}