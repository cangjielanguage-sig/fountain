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

import fountain::f_data.macros.*

@DataAssist[props fields]
public open class LLMParams {
    private var model: String = ''
    private var messages: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    public let thinking: Thinking = Thinking()
    private var do_sample: Bool = true
    private var temperature: Float64 = 0.0
    private let max_tokens: Int64 = 131072
    private let response_format: String = 'json'
    private let request_id: String = UUID.random().toString()
    private let user_id: String = FCODER_USER
}

@DataAssist[props fields]
public class LLMToolParams <: LLMParams {
    private let tools: ArrayList<FunctionCall> = ArrayList<FunctionCall>()
}

@DataAssist[props fields]
public class Thinking {
    private var `type`: ThinkingSwitch = THINGKING_ENABLED
    private var clear_thinking: Bool = false
}

@DataAssist[props fields]
public class FunctionCall {
    public let `type`: String = 'function'
    public let function: Function = Function()
}

@DataAssist[props fields]
public class Function { 
    private var name: String = ''
    private var description: String = ''
    private var parameters: Parameters = Parameters()
}

@DataAssist[props fields]
public class Parameters { 
    private var `type`: String = 'object'
    private var properties: HashMap<String, Property> = HashMap<String, Property>()
    private var required: ArrayList<String> = ArrayList<String>()

    public func addRequired(name: String) {
        this.required.add(name)
    }
    public func addProperty(name!: String, `type`!: String, description!: String) {
        this.properties.add(name, Property(`type`, description))
    }
    public func addProperty(name: String, property: Property){
        this.properties.add(name, property)
    }
}

@DataAssist[props fields]
public class Property {
    public Property(
        private var `type`: String,
        private var description: String
    ){}
    public init(){
        this('', '')
    }
}