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

import fountain::f_data.macros.*

public interface GLMSpeciallyParam <: ResponseFormat & DoSample {
    prop request_id: String {
        get(){
            UUID.random().toString()
        }
    }
    prop user_id: String {
        get(){
            FCODER_USER
        }
    }
}

@DataAssist[fields]
public open class GLMParams <: LLMParams & GLMSpeciallyParam {
    public init(
        model!: String = '',
        messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){
        super(model: model, messages: messages)
    }
    public prop response_format: String {
        get(){
            'json_object'
        }
    }
    private var doSample: Bool = true
    public mut prop do_sample: Bool {
        get(){
            doSample
        }
        set(value){
            doSample = value
        }
    }
    public prop request_id: String {
        get(){
            UUID.random().toString()
        }
    }
    public prop user_id: String {
        get(){
            FCODER_USER
        }
    }
}
@DataAssist[props fields]
public open class GLMToolParams <: GLMParams {
    public init(
        model!: String = '',
        messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){
        super(model: model, messages: messages)
    }
    private let tools: ArrayList<FunctionCall> = ArrayList<FunctionCall>()
}

public class GLMContext <: AbstractLLMContext {
    private static let log = LoggerFactory.getLogger<GLMContext>()
    public init(conf: LLMConf){
        super(conf)
    }

    public func access(params: LLMParams): LLMResp {
        http(url, conf){http =>
            let start = MonoTime.now()
            var json = None<JsonValue>
            try{
                json = http.post('application/json', params).readJson()
                let jsonObj = json.getOrThrow().asObject()
                let choices = jsonObj.get('choices').getOrThrow().asArray()
                let llmResp = LLMResp()
                for(i in 0 .. choices.size()){
                    let message = choices[i].asObject().get('message').getOrThrow{LLMException(jsonObj.toString())}.asObject()
                    if(message.containsKey('tool_calls')){
                        llmResp.messages.add(DataObject<ToolCallMessage>.populate(message.toData()).getOrThrow())
                    }else{
                        llmResp.messages.add(DataObject<AssistantMessage>.populate(message.toData()).getOrThrow())
                    }
                }
                let usageJson = jsonObj.get('usage').getOrThrow().asObject()
                let usage = llmResp.usage
                usage.llmId = super.id
                usage.agentId = params.agentId
                DataObject<TokenUsage>.populate(usageJson.toData(), usage)
                usage.cached = usageJson.get('prompt_tokens_details')?.asObject().get('cached_tokens')?.asInt().getValue() ?? 0
                llmResp
            }catch(e: Exception) {
                let resp = json
                let requestId = (params as GLMParams)?.request_id
                log.error(e){"GLMContext.access error, requestId: ${requestId}, resp: ${resp}"}
                throw e
            }finally{
                let resp = json
                log.info{'GLMContext.access end, requestId: ${(params as GLMParams)?.request_id}, agentId: ${params.agentId}, resp: ${resp}, elapsed: ${MonoTime.now() - start}'}
            }
        }
    }
}