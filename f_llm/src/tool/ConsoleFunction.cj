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

import std.env.{ConsoleWriter, ConsoleReader, getStdIn, getStdOut}
import fountain::f_bean.macros.*
import fountain::f_data.macros.*

@DataAssist[props fields]
public class ConsoleOutput {
    @JsonStringSchema[description:'流程下一步的事件名称']
    private var nextEvent: String = ''
    @JsonStringSchema[description:'大模型输出到控制台的内容']
    private var content: String = ''
}

@Bean
public class ConsoleFunction <: FunctionCalling<ConsoleOutput> {
    private let writer = getStdOut()
    private let reader = getStdIn()
    /**
     * 函数名称
     */
    public prop name: String {
        get(){
            'console'
        }
    }
    /**
     * 函数描述
     */
    public prop description: String {
        get(){
            '控制台读写，大模型向控制台输出一段内容，用户通过控制台向大模型指示下一步行动'
        }
    }
    /**
     * 控制台读写，向控制台输出大模型需要用户看到的内容，等待用户回复或确认下一步行动。
     */
    public func call(params: ConsoleOutput): FunctionResult {
        writer.writeln(params.content)
        writer.writeln('> 请输入你的回复： ')
        writer.write('$ ')
        writer.flush()
        let answer = reader.readToEnd() ?? ''
        FunctionResult(event: params.nextEvent, result: answer)
    }
}