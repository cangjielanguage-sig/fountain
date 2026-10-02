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

public class LLMContextMediator {
    private static let contextCreators = HashMap<String, (LLMConf) -> AbstractLLMContext>()
    
    static init(){
        let closure = {conf: LLMConf => GLMContext(conf)}
        register(LLM_TYPE_TEXT, 'glm-4.7-flash', closure)
        register(LLM_TYPE_TEXT, 'glm-5', closure)
        register(LLM_TYPE_CODE, 'glm-5.1', closure)
    }
    public static func register(llmType: LLMType, model: String, creator: (LLMConf) -> AbstractLLMContext){
        contextCreators['${model}+${llmType}'] = creator
    }
    private let contexts = ConcurrentHashMap<String, AbstractLLMContext>()
    private init(){}

    private static let instance_ = LLMContextMediator()
    public static prop instance: LLMContextMediator {
        get(){
            instance_
        }
    }
    private let mutex = Mutex()
    private func load(key: String){
        if(let Some(x) <- contexts.get(key)){
            return x
        }
        synchronized(mutex){
            if(let Some(x) <- contexts.get(key)){
                return x
            }
            for(conf in lookup<LLMFinder>().listConfs([LLM_TYPE_TEXT, LLM_TYPE_CODE])){
                let key = '${conf.name}+${conf.llmType}'
                if(let Some(newer) <- contextCreators.get(key)){
                    contexts[key] = newer(conf)
                }
            }
            return contexts[key]
        }
    }
    public func access(agentId: Int64, session: String, llmType: LLMType, params: LLMParams): LLMResp {
        let key = '${params.model}+${llmType}'
        load(key).access(agentId, session, params)
    }
    public func getTokenThreshold(llmType: LLMType, model: String): Int64 {
        let key = '${model}+${llmType}'
        load(key).threshold
    }
    public func tokenize(llmType: LLMType, model: String, messages: ArrayList<ChatMessage>): Int64 {
        let key = '${model}+${llmType}'
        load(key).tokenize(model, messages)
    }
    public func saturated(llmType: LLMType, model: String, messages: ArrayList<ChatMessage>): Bool {
        tokenize(llmType, model, messages) >= getTokenThreshold(llmType, model)
    }
}