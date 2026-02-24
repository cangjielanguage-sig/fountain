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
    private static let log = LoggerFactory.getLogger<GLMContext>()
    public init(conf: LLMConf){
        super(conf)
    }

    public func access(params: LLMParams): LLMResp {
        resource(http(url, conf)){http =>
            try{
                let json = http.post('application/json', params).readJson().asObject()
                let choices = json.get('choices').getOrThrow().asArray()
                let llmResp = LLMResp()
                for(i in 0 .. choices.size()){
                    let message = choices[i].asObject().get('message').getOrThrow{LLMException(json.toString())}.asObject()
                    if(message.containsKey('tool_calls')){
                        llmResp.messages.add(DataObject<ToolCallMessage>.populate(message.toData()).getOrThrow())
                    }else{
                        llmResp.messages.add(DataObject<AssistantMessage>.populate(message.toData()).getOrThrow())
                    }
                }
                let usageJson = json.get('usage').getOrThrow().asObject()
                let usage = llmResp.usage
                usage.llmId = super.id
                DataObject<TokenUsage>.populate(usageJson.toData(), usage)
                usage.cached = usageJson.get('prompt_tokens_details')?.asObject().get('cached_tokens')?.asInt().getValue() ?? 0
                llmResp
            }catch(e: Exception) {
                let requestId = params.request_id
                log.error(e){"GLMContext.access error, requestId: ${requestId}"}
                throw e
            }
        }
    }
}