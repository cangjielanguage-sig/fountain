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

/**
 * 函数调用结果，本模块是f_llm的辅助模块，而f_llm依赖f_egraph定义的事件和流程
 */
public struct FunctionResult {
    /**
     * 函数调用结果
     * @param event 本函数的结果要包装的事件名称
     * @param result 函数调用结果，要么是简单字符串，要么是MARKDOWN格式的文本。是空串时表示函数调用结果不产生新数据
     */
    public FunctionResult(
        public let eventType!: EventType = EventType.Task,
        public let event!: String,
        public let result!: String = ''
    ){
        if(event.isEmpty()){
            throw FunctionCallingException('event name cannot be empty')
        }
    }
}