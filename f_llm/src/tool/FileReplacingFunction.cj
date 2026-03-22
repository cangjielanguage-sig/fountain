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
public class FileReplacingParams {
    @JsonStringSchema[description:'流程下一步事件的名称']
    private var event: String = ''
    @JsonStringSchema[description:'''
UNIX风格的文件路径。
这个函数是一个应用程序的一部分，本路径会作为配置的可用路径的相对路径，即使大模型返回的参数使用了绝对路径也不会访问整个操作系统的文件系统。''']
    private var path: String = ''
    @JsonStringSchema[description:'待替换的内容']
    private var replacement: String = ''
    @JsonStringSchema[description: '符合这个正则表达式的文本行才会替换，如果是空串会返回错误']
    private var regex: String = ''
}

@Bean
public class FileReplacngFunction <: AbstractFileFunction<FileReplacingParams> {
    /**
     * 函数名称
     */
    public prop name: String {
        get(){
            'replaceFile'
        }
    }
    /**
     * 函数描述
     */
    public prop description: String {
        get(){
            '逐行替换文件内容，替换成功返回OK，否则返回错误原因，如果文件不存在会立即返回"文件不存在"'
        }
    }
    /**
     * 写文件的操作
     * @param params 函数参数
     * @return 函数调用结果
     */
    public func call(params: FileReplacingParams): FunctionResult {
        if(params.regex.isEmpty()){
            return FunctionResult(
                eventType: EventType.Task,
                event: params.event,
                result: '替换用的正则表达式不能是空串',
                resultType: ResultType.Text
            )
        }
        var path = genPath(params.path)
        if(!exists(path)){
            return FunctionResult(
                eventType: EventType.Task,
                event: params.event,
                result: '文件不存在',
                resultType: ResultType.Text
            )
        }
        let p = path
        let result = ResourceManager<File>{File(p, ReadWrite)}.call{file: File =>
            let content = StringReader(file).readToEnd()
            file.seek(Begin(0))
            file.setLength(0)
            Regex(params.regex).replaceAll(content, params.replacement).unsafeBytes() |> file.write
            'OK'
        }
        FunctionResult(
            eventType: EventType.Task,
            event: params.event,
            result: result,
            resultType: ResultType.Text
        )
    }
}