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

@DataAssist[props fields]
public open class ChatMessage {
    public ChatMessage(
        private var role: Role,
        private var content: String) {}
    public init(){
        this('', '')
    }
}

@DataAssist[props fields]
public class SystemMessage <: ChatMessage {
    public init(){
        super(ROLE_SYSTEM, '')
    }
    public init(content: String){
        super(ROLE_SYSTEM, content)
    }
}

@DataAssist[props fields]
public open class AssistantMessage <: ChatMessage {
    @FieldAlias['reasoning_content']
    private var reasoningContent: String = ""
    public init(){
        super(ROLE_ASSISTANT, '')
    }
    public init(content: String){
        super(ROLE_ASSISTANT, content)
    }
}

@DataAssist[props fields]
public class UserMessage <: ChatMessage {
    public init(){
        super(ROLE_USER, '')
    }
    public init(content: String){
        super(ROLE_USER, content)
    }
}

@DataAssist[props fields]
public class ToolCallFunction {
    public ToolCallFunction(
        private var name: String,
        private var arguments: String
    ){}
    public init(){
        this("", "")
    }
}

@DataAssist[props fields]
public class ToolCallMessage <: AssistantMessage {
    @FieldAlias['tool_calls']
    private let toolCalls: ArrayList<ToolCall> = ArrayList<ToolCall>()

    public func addToolCall(call: ToolCall){
        toolCalls.add(call)
    }
    public func addFunctionCall(id!: String, toolType!: ToolType, name!: String, arguments!: String){
        addToolCall(ToolCall(id, toolType, ToolCallFunction(name, arguments)))
    }
}

@DataAssist[props fields]
public class ToolCall {
    public ToolCall(
        private var id: String,
        @FieldAlias['type']
        private var toolType: ToolType,
        private var function: ToolCallFunction
    ){}

    public init(){
        this('', '', ToolCallFunction())
    }
}

@DataAssist[props fields]
public class ToolMessage <: ChatMessage {
    private var tool_call_id: String = ""
    public init(){
        super(ROLE_TOOL, '')
    }
}