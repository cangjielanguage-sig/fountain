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

import fountain::f_bean.macros.*

public interface ContextPruner {
    prop name: String
    func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>
}

@Bean
public class RetainContext <: ContextPruner {
    public prop name: String{
        get(){
            CONTEXT_PRUNER_RETAIN
        }
    }
    public func prune(_: Int64, _: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>{
        return messages
    }
}

public class LastNContext <: ContextPruner {
    public LastNContext(
        private let n!: Int64 = 1
    ){}
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_LAST_N}_${n}'
        }
    }
    public func prune(_: Int64, _: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>{
        return if(messages.size > n * 2){
            messages[messages.size - n * 2 ..]
        }else{
            messages
        }
    }
}
public abstract class ContextLLMPruner <: ContextPruner {
    public ContextLLMPruner(
        protected let llmType!: LLMType,
        protected let model!: ModelName,
        private let promptsGenerator!: (ArrayList<ChatMessage>) -> String
    ){}
    public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>{
        let params = LLMParams(
            model: model,
            messages: ArrayList<ChatMessage>([UserMessage(promptsGenerator(messages))])
        )
        let resp = LLMContextMediator.instance.access(agentId, session, llmType, params)
        lookupOption<TokenUsageSaver>()?.saveTokenUsage(resp.usage)
        let msgs = resp.messages
        let msg = msgs[msgs.size - 1]
        msg.role = ROLE_USER
        return msgs
    }
}
public class ContextSummaryPruner <: ContextLLMPruner {
    public init(
        llmType!: LLMType = LLM_TYPE_TEXT,
        model!: ModelName = MODEL_NAME_GLM4_7_FLASH,
        promptsGenerator!: (ArrayList<ChatMessage>) -> String = {messages => '''
- 总结下面的JSON所描述的内容，从中提取内容**要点**、**关键**内容，并以MARKDOWN格式返回。
```json
${(JsonValue.fromData(messages.toData()) as JsonValue).getOrThrow()}
```'''}
    ){
        super(llmType: llmType, model: model, promptsGenerator: promptsGenerator)
    }
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_SUMMARY}_BY_${llmType}_${model}'
        }
    }
}
public class ContextKeywordsPruner <: ContextLLMPruner {
    public init(
        llmType!: LLMType = LLM_TYPE_TEXT,
        model!: ModelName = MODEL_NAME_GLM4_7_FLASH,
        promptsGenerator!: (ArrayList<ChatMessage>) -> String = {messages => '''
- 从下面的JSON所描述的内容中提取**关键词**，关键词之间以逗号分隔。
```json
${(JsonValue.fromData(messages.toData()) as JsonValue).getOrThrow()}
```'''}
    ){
        super(llmType: llmType, model: model, promptsGenerator: promptsGenerator)
    }
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_KEYWORDS}_BY_${llmType}_${model}'
        }
    }
}
public class DRCContextPruner <: ContextPruner {
    public DRCContextPruner(
        private let systemPruner!: ContextPruner,
        private let othersPruner!: ContextPruner
    ){}
    public init(
        exceptSystemPruner!: ContextPruner
    ){
        this(systemPruner: RetainContext(), othersPruner: exceptSystemPruner)
    }
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_DRC}_${systemPruner.name}_${othersPruner.name}'
        }
    }
    public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>{
        let systems = ArrayList<ChatMessage>()
        let others = ArrayList<ChatMessage>()
        for(m in messages){
            if(m.role == ROLE_SYSTEM){
                systems.add(m)
            }else{
                others.add(m)
            }
        }
        let pruned = ArrayList<ChatMessage>()
        pruned.add(all: systemPruner.prune(agentId, session, systems))
        pruned.add(all: othersPruner.prune(agentId, session, others))
        pruned
    }
}
public class SaturationContextPruner <: ContextPruner {
    public SaturationContextPruner(
        private let pruner!: ContextPruner
    ){}
    public prop name: String{
        get(){
            '${CONTEXT_PRUNER_SATURATION}_${pruner.name}'
        }
    }
    public func prune(agentId: Int64, session: String, messages: ArrayList<ChatMessage>): ArrayList<ChatMessage>{
        let agent = lookup<AgentsFinder>().queryAgent(agentId)
        let saturated = LLMContextMediator.instance.saturated(agent.llmType, agent.llmName, messages)
        if(saturated){
            pruner.prune(agentId, session, messages)
        }else{
            messages
        }
    }
}
