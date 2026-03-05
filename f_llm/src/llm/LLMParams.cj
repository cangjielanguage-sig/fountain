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
public open class LLMParams {
    public LLMParams(
        private var model!: String = '',
        private var messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){}
    private let thinking: Thinking = Thinking()
    //不能用驼峰命名法再用@FieldAlias['do_sample']修饰，因为要用这个类的实例转换为JSON，这样命名会产生JSON字段冗余
    private let temperature: Float64 = 0.0
    private let max_tokens: Int64 = 131072
    private let response_format: String = 'json_object'
    private let frequency_penalty: Float64 = 0.5//抑制重复用词，有些模型支持
    private let thinking_budget: Int64 = 1024//最大思维链长度，有些模型支持
    private var do_sample: Bool = true//智谱专用
    private let request_id: String = UUID.random().toString()//智谱专用
    private let user_id: String = FCODER_USER//智谱专用
}

@DataAssist[props fields]
public class LLMToolParams <: LLMParams {
    public init(
        model!: String = '',
        messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){
        super(model: model, messages: messages)
    }
    private let tools: ArrayList<FunctionCall> = ArrayList<FunctionCall>()
}

@DataAssist[props fields]
public class Thinking {
    public Thinking(
        private var `type`!: ThinkingSwitch = THINGKING_ENABLED,
        private var clear_thinking!: Bool = false
    ){}
}

@DataAssist[props fields]
public class FunctionCall {
    public let `type`: String = 'function'
    public let function: Function = Function()
}

@DataAssist[props fields]
public class Function {
    public Function(
        private var name!: String = '',
        private var description!: String = '',
        private var parameters!: Parameters = Parameters(),
    ){}
}

@DataAssist[props fields]
public class Parameters { 
    public Parameters(
        private var `type`!: String = 'object'
    ){}
    private var properties: HashMap<String, Property> = HashMap<String, Property>()
    private var required: ArrayList<String> = ArrayList<String>()

    public func addRequired(name: String) {
        this.required.add(name)
    }
    public func addProperty(name!: String, `type`!: String, description!: String) {
        this.properties.add(name, Property(`type`: `type`, description: description))
    }
    public func addProperty(name: String, property: Property){
        this.properties.add(name, property)
    }
}

@DataAssist[props fields]
public class Property {
    public Property(
        private var `type`!: String = '',
        private var description!: String = ''
    ){}
}