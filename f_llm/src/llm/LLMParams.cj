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
        private let model!: String = '',
        private let messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){}
    private let thinking: Thinking = Thinking()
    //不能用驼峰命名法再用@FieldAlias['do_sample']修饰，因为要用这个类的实例转换为JSON，这样命名会产生JSON字段冗余
    private var temperature: Float64 = 1.0
    private var max_tokens: Int64 = 65536
}

@DataAssist[props fields]
public open class LLMToolParams <: LLMParams {
    public init(
        model!: String = '',
        messages!: ArrayList<ChatMessage> = ArrayList<ChatMessage>()
    ){
        super(model: model, messages: messages)
    }
    protected let functions: ArrayList<FunctionCall> = ArrayList<FunctionCall>()
    
    @DataExclude[prop field]
    private let fnNames = HashSet<String>()
    public func addFunctions<I>(functions: I): Unit where I <: Iterable<FunctionCall> {
        for (function in functions where !fnNames.contains(function.function.name)) {
            this.functions.add(function)
            fnNames.add(function.function.name)
        }
    }
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