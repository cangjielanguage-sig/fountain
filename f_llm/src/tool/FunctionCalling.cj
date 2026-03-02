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
package fountain::f_llm.tool

import std.reflect.*
import stdx.encoding.json.*

import fountain::f_data.*

/**
 * 大模型函数定义接口
 * 此接口的实现必须是类且被fountain::f_bean.macros.Bean修饰
 */
public interface FunctionCalling<T> where T <: ObjectData<T> {
    /**
     * JSON SCHEMA形式描述的大模型函数定义
     * 默认实现调用fountain::f_data.json的JsonObject.toJsonSchema<T>()扩展函数获得参数定义，并把本接口的name和description属性与从泛型实参转换来的Json作为大模型函数定义
     */
    prop definition: String {
        get() {
            let function = JsonObject()
            function.put("type", JsonString('function'))
            let function = JsonObject()
            function.put("name", JsonString(name))
            function.put("description", JsonString(description))
            function.put("parameters", JsonObject.toJsonSchema<T>())
            function.toString()            
        }
    }
    /**
     * 函数名称
     */
    prop name: String
    /**
     * 函数描述
     */
    prop description: String 
    /**
     * 函数调用
     * @param params 函数参数
     * @return 函数调用结果
     */
    func call(params: T): FunctionResult
    /**
     * 函数调用，这个函数供agent调用，开发者实现`func call(params: T): FunctionResult`即可
     * @param params 函数参数
     * @return 函数调用结果
     */
    func call(json: JsonValue): FunctionResult {
        DataObject<T>.populate(json.toData()).getOrThrow() |> call
    }
}