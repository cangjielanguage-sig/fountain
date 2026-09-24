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

import fountain::f_bean.macros.*
import fountain::f_data.macros.*

@DataAssist[props fields]
public class Answer {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'你的回复，将作为流程下一步事件的数据']
    private var answer: String = ''
}

@Bean
public class AnswerFunction <: FunctionCalling<Answer> {
    /**
     * 函数名称
     */
    public prop name: String {
        get(){
            'answer'
        }
    }
    /**
     * 函数描述
     */
    public prop description: String {
        get(){
            '⚠️ 注意：如果需要直接输出回复，而不再依赖其它函数或工具的结果，务必使用此函数传递回复'
        }
    }
    /**
     * 用来解析大模型的返回
     * @param params 函数参数
     * @return 函数调用结果
     */
    public func call(params: Answer): FunctionResult {
        FunctionResult(event: params.nextEvent, result: params.answer)
    }
}